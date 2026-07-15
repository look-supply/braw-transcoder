#include "bridge/braw_api.h"
#include "core/Types.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#include <atomic>
#include <dispatch/dispatch.h>
#include <unistd.h>

static std::atomic<bool> g_running{false};
static std::atomic<bool> g_cancel{false};

// Callback for CVPixelBufferCreateWithBytes — frees the malloc'd pixel data
static void pixelBufferReleaseCallback(void* ref, const void* data) {
    braw_clip_free_frame((uint8_t*)data);
}

// GPU decode for speed (18fps vs 2fps CPU). No decoder resets — one lifecycle
// per clip. Subprocess isolation reclaims SDK memory on exit. No segmentation.

// Find ffmpeg binary: bundled in app Resources, relative to executable, system
static NSString* findFFmpeg(void) {
    // 1. App bundle Resources/ffmpeg (production bundle)
    NSString* bundled = [[NSBundle mainBundle] pathForResource:@"ffmpeg" ofType:nil];
    if (bundled && [[NSFileManager defaultManager] isExecutableFileAtPath:bundled])
        return bundled;
    // 2. Relative to executable (dev builds: build/BrawTranscoder.app/Contents/Resources/ffmpeg)
    NSString* execPath = [[NSBundle mainBundle] executablePath];
    if (execPath) {
        NSString* rel = [[[execPath stringByDeletingLastPathComponent]
                            stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:@"Resources/ffmpeg"];
        if (rel && [[NSFileManager defaultManager] isExecutableFileAtPath:rel])
            return rel;
    }
    // 3. System Homebrew installs
    NSString* sysPaths[] = {
        @"/opt/homebrew/bin/ffmpeg",
        @"/usr/local/bin/ffmpeg",
        @"/usr/bin/ffmpeg",
    };
    for (int i = 0; i < sizeof(sysPaths)/sizeof(sysPaths[0]); i++) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:sysPaths[i]])
            return sysPaths[i];
    }
    return nil;
}

static bool exportMOV(BrawClipHandle* clip, int outW, int outH, float fps,
                       uint64_t frameCount, int codec, int bitrate,
                       const std::string& outPath,
                       ExportProgressFn pf, void* pctx, int ci, int tc) {
    @autoreleasepool {
        uint32_t srcW = braw_clip_get_width(clip);
        uint32_t srcH = braw_clip_get_height(clip);

        // ---- Extract audio with channel pruning ----
        uint32_t audioRate = 0, audioChannels = 0;
        uint64_t audioSamples = 0;
        float* audioData = braw_clip_extract_audio(clip, &audioRate, &audioChannels, &audioSamples);
        if (audioData && audioRate > 0 && audioSamples > 0) {
            bool* channelActive = (bool*)calloc(audioChannels, sizeof(bool));
            if (channelActive) {
                for (uint64_t i = 0; i < audioSamples && audioChannels > 0; i++)
                    for (uint32_t ch = 0; ch < audioChannels; ch++)
                        if (!channelActive[ch] && fabs(audioData[i * audioChannels + ch]) > 0.001f)
                            channelActive[ch] = true;
                uint32_t activeCount = 0;
                for (uint32_t ch = 0; ch < audioChannels; ch++)
                    if (channelActive[ch]) activeCount++;
                if (activeCount == 0) activeCount = (audioChannels >= 2) ? 2 : audioChannels;
                if (activeCount < audioChannels) {
                    uint32_t* remap = (uint32_t*)malloc(audioChannels * sizeof(uint32_t));
                    uint32_t newCh = 0;
                    for (uint32_t ch = 0; ch < audioChannels; ch++) {
                        if (channelActive[ch]) remap[ch] = newCh++;
                        else remap[ch] = UINT32_MAX;
                    }
                    if (newCh < 2 && audioChannels >= 2) {
                        for (uint32_t ch = 0; ch < audioChannels && newCh < 2; ch++)
                            if (remap[ch] == UINT32_MAX) { remap[ch] = newCh++; activeCount = 2; }
                    }
                    float* pruned = (float*)malloc(audioSamples * activeCount * sizeof(float));
                    for (uint64_t i = 0; i < audioSamples; i++)
                        for (uint32_t ch = 0; ch < audioChannels; ch++)
                            if (remap[ch] != UINT32_MAX)
                                pruned[i * activeCount + remap[ch]] = audioData[i * audioChannels + ch];
                    free(audioData);
                    audioData = pruned;
                    audioChannels = activeCount;
                    free(remap);
                }
                free(channelActive);
            }
        }

        // ---- Video only via AVAssetWriter (audio muxed by ffmpeg) ----
        NSDictionary* poolAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(srcW),
            (id)kCVPixelBufferHeightKey: @(srcH),
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolRef pxPool = NULL;
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)poolAttrs, &pxPool);

        // Write video to a temp path, then mux with audio via ffmpeg to final
        NSString* tmpVidPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        tmpVidPath = [tmpVidPath stringByAppendingPathExtension:@"mov"];

        [[NSFileManager defaultManager] removeItemAtPath:tmpVidPath error:nil];
        NSURL* url = [NSURL fileURLWithPath:tmpVidPath];
        NSError* err = nil;
        AVAssetWriter* writer = [[AVAssetWriter alloc] initWithURL:url
                                                           fileType:AVFileTypeQuickTimeMovie
                                                              error:&err];
        if (!writer) {
            fprintf(stderr, "AVAssetWriter create failed: %s\n", [[err description] UTF8String]);
            if (audioData) free(audioData);
            if (pxPool) CVPixelBufferPoolRelease(pxPool);
            return false;
        }

        NSDictionary* vidSettings = @{
            AVVideoCodecKey: (codec == 0) ? AVVideoCodecTypeH264 : AVVideoCodecTypeHEVC,
            AVVideoWidthKey: @(outW),
            AVVideoHeightKey: @(outH),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @(bitrate),
                AVVideoMaxKeyFrameIntervalKey: @((int)(fps * 2)),
                AVVideoProfileLevelKey: (codec == 0) ? AVVideoProfileLevelH264HighAutoLevel
                                                       : @"HEVC_Main10_AutoLevel",
                AVVideoAllowFrameReorderingKey: @NO,
                AVVideoExpectedSourceFrameRateKey: @((int)fps),
            },
        };
        AVAssetWriterInput* videoInput = [[AVAssetWriterInput alloc]
            initWithMediaType:AVMediaTypeVideo outputSettings:vidSettings];
        videoInput.expectsMediaDataInRealTime = NO;

        AVAssetWriterInputPixelBufferAdaptor* adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc]
            initWithAssetWriterInput:videoInput
            sourcePixelBufferAttributes:@{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferWidthKey: @(srcW),
                (id)kCVPixelBufferHeightKey: @(srcH),
            }];
        [writer addInput:videoInput];

        [writer startWriting];
        [writer startSessionAtSourceTime:kCMTimeZero];

        __block bool videoDone = false;
        __block bool inputFinished = false;
        __block uint64_t frameIdx = 0;

        [videoInput requestMediaDataWhenReadyOnQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                                          usingBlock:^{
            @autoreleasepool {
                bool origPreviewLUT = braw_clip_get_preview_lut(clip);
                braw_clip_set_preview_lut(clip, false);

                while (frameIdx < frameCount && !g_cancel && !inputFinished) {
                    int fw = 0, fh = 0;
                    void* mtlBuf = braw_clip_decode_frame_gpu(clip, frameIdx, &fw, &fh);
                    if (!mtlBuf) { frameIdx++; continue; }

                    if (!videoInput.readyForMoreMediaData) {
                        braw_clip_free_frame_gpu(mtlBuf);
                        break;
                    }

                    CVPixelBufferRef pxBuf = NULL;
                    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pxPool, &pxBuf) == kCVReturnSuccess) {
                        CVPixelBufferLockBaseAddress(pxBuf, 0);
                        uint8_t* dst = (uint8_t*)CVPixelBufferGetBaseAddress(pxBuf);
                        size_t dstBPR = CVPixelBufferGetBytesPerRow(pxBuf);
                        uint8_t* src = (uint8_t*)[(__bridge id<MTLBuffer>)mtlBuf contents];
                        for (int y = 0; y < fh; y++)
                            memcpy(dst + y * dstBPR, src + y * fw * 4, fw * 4);
                        CVPixelBufferUnlockBaseAddress(pxBuf, 0);
                        CMTime pts = CMTimeMake((int64_t)frameIdx, (int32_t)fps);
                        @try {
                            [adaptor appendPixelBuffer:pxBuf withPresentationTime:pts];
                        } @catch (NSException* e) {
                            fprintf(stderr, "appendPixelBuffer exception at frame %lld: %s\n",
                                    (long long)frameIdx, [[e description] UTF8String]);
                            CVPixelBufferRelease(pxBuf);
                            braw_clip_free_frame_gpu(mtlBuf);
                            break;
                        }
                        CVPixelBufferRelease(pxBuf);
                    }
                    braw_clip_free_frame_gpu(mtlBuf);
                    if (pf) pf(ci, tc, (int)frameIdx, (int)frameCount, pctx);
                    frameIdx++;
                }
                braw_clip_set_preview_lut(clip, origPreviewLUT);
                if (frameIdx >= frameCount || g_cancel) {
                    if (!inputFinished) {
                        [videoInput markAsFinished];
                        inputFinished = true;
                    }
                    videoDone = true;
                }
            }
        }];

        while (!videoDone) {
            if (g_cancel) { [writer cancelWriting]; break; }
            usleep(50000);
        }

        if (!g_cancel) {
            [writer finishWritingWithCompletionHandler:^{}];
            while (writer.status == AVAssetWriterStatusWriting) usleep(50000);
        }

        bool videoOK = (writer.status == AVAssetWriterStatusCompleted);
        if (pxPool) CVPixelBufferPoolRelease(pxPool);

        // ---- Mux audio via ffmpeg ----
        bool finalMuxed = false;
        if (videoOK && audioData && audioRate > 0 && audioSamples > 0 && !g_cancel) {
            NSString* ffmpeg = findFFmpeg();
            if (ffmpeg) {
                NSString* tmpAudioPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                tmpAudioPath = [tmpAudioPath stringByAppendingPathExtension:@"raw"];
                uint64_t totalBytes = audioSamples * audioChannels * sizeof(float);
                NSData* audioRaw = [NSData dataWithBytesNoCopy:audioData
                                                        length:(NSUInteger)totalBytes
                                                  freeWhenDone:NO];
                if ([audioRaw writeToFile:tmpAudioPath atomically:NO]) {
                    NSString* finalPath = @(outPath.c_str());
                    [[NSFileManager defaultManager] removeItemAtPath:finalPath error:nil];

                    NSTask* task = [[NSTask alloc] init];
                    task.executableURL = [NSURL fileURLWithPath:ffmpeg];
                    task.arguments = @[
                        @"-y",
                        @"-i", tmpVidPath,
                        @"-f", @"f32le",
                        @"-ar", [NSString stringWithFormat:@"%u", audioRate],
                        @"-ac", [NSString stringWithFormat:@"%u", audioChannels],
                        @"-i", tmpAudioPath,
                        @"-c:v", @"copy",
                        @"-c:a", @"pcm_s24le",
                        @"-map", @"0:v:0",
                        @"-map", @"1:a:0",
                        @"-movflags", @"+faststart",
                        finalPath,
                    ];
                    task.standardError = [NSPipe pipe];
                    NSError* launchErr = nil;
                    [task launchAndReturnError:&launchErr];
                    if (launchErr) {
                        fprintf(stderr, "ffmpeg launch failed: %s\n", [[launchErr description] UTF8String]);
                    } else {
                        [task waitUntilExit];
                        if (task.terminationStatus == 0) {
                            finalMuxed = true;
                        } else {
                            NSData* errData = [[(NSPipe*)task.standardError fileHandleForReading] readDataToEndOfFile];
                            fprintf(stderr, "ffmpeg exited %d: %s\n",
                                    task.terminationStatus,
                                    [[[NSString alloc] initWithData:errData
                                                          encoding:NSUTF8StringEncoding] UTF8String]);
                        }
                    }
                    [[NSFileManager defaultManager] removeItemAtPath:tmpAudioPath error:nil];
                }
            } else {
                fprintf(stderr, "ffmpeg not found — video exported without audio\n");
            }
        }

        if (!finalMuxed && videoOK) {
            [[NSFileManager defaultManager] removeItemAtPath:@(outPath.c_str()) error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:tmpVidPath toPath:@(outPath.c_str()) error:nil];
        }

        free(audioData);

        [[NSFileManager defaultManager] removeItemAtPath:tmpVidPath error:nil];
        return [[NSFileManager defaultManager] fileExistsAtPath:@(outPath.c_str())];
    }
}

extern "C" {

static NSString* helperPath(void) {
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString* bp = [bundlePath stringByDeletingLastPathComponent];
    NSString* s = [bp stringByAppendingPathComponent:@"export_helper"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:s]) return s;
    NSString* ep = [[NSBundle mainBundle] executablePath];
    if (ep) {
        s = [[ep stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"export_helper"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:s]) return s;
    }
    s = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"build/export_helper"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:s]) return s;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"export_helper"]) return @"export_helper";
    return nil;
}

int braw_export_start_inprocess(BrawProjectHandle* proj, const int* indices, int count,
                                 int codec, int proResProfile, int resolutionMode, int dataRateMbps,
                                 const char* outputDir, ExportProgressFn pf, void* ctx) {
    if (g_running || !proj || !indices || count<=0) return -1;
    auto* clip = braw_project_get_clip(proj, indices[0]);
    if (!clip) return -1;
    uint32_t sw=braw_clip_get_width(clip), sh=braw_clip_get_height(clip);
    float fps=braw_clip_get_frame_rate(clip);
    uint64_t fc=braw_clip_get_frame_count(clip);
    int ow=sw, oh=sh;
    int hs[]={0,2160,2160,1080,1080};
    if (resolutionMode>0 && resolutionMode<5 && hs[resolutionMode]>0)
        { oh=hs[resolutionMode]; ow=(int)((float)oh*sw/sh); ow=(ow+1)&~1; }

    std::string cp = braw_clip_get_filepath(clip);
    std::string cd = "/tmp";
    size_t ls = cp.rfind('/');
    if (ls != std::string::npos) cd = cp.substr(0, ls);
    const char* od = (outputDir && outputDir[0]) ? outputDir : cd.c_str();
    std::string ods = od;
    std::string outPath;
    if (ods.size()>4 && ods.substr(ods.size()-4)==".mov") outPath = ods;
    else {
        std::string nm = braw_clip_get_filename(clip);
        size_t d = nm.rfind('.');
        if (d != std::string::npos) nm = nm.substr(0, d);
        outPath = ods + "/" + nm + "_export.mov";
    }

    g_running=true; g_cancel=false;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        for (int ci=0; ci<count && !g_cancel; ci++) {
            auto* c = braw_project_get_clip(proj, indices[ci]);
            if (!c) continue;
            exportMOV(c, ow, oh, fps, fc, codec, dataRateMbps*1000000, outPath, pf, ctx, ci, count);
        }
        g_running=false;
        if (pf) pf(0,0,-1,-1,ctx);
    });
    return 0;
}

int braw_export_start(BrawProjectHandle* proj, const int* indices, int count,
                       int codec, int proResProfile, int resolutionMode, int dataRateMbps,
                       const char* outputDir, ExportProgressFn pf, void* ctx) {
    if (g_running || !proj || !indices || count<=0) return -1;
    NSString* helper = helperPath();
    if (!helper) { fprintf(stderr, "export_helper binary not found\n"); return -1; }

    // Copy indices to local storage — the Swift caller's array may be deallocated
    // by the time the async block runs. We can't capture the raw pointer.
    std::vector<int> indicesCopy(indices, indices + count);

    g_running=true; g_cancel=false;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            const auto& idxVec = indicesCopy;
            for (int i=0; i<(int)idxVec.size() && !g_cancel; i++) {
                int projectIdx = idxVec[i];
                auto* clip = braw_project_get_clip(proj, projectIdx);
                if (!clip) { fprintf(stderr, "clip null at project index %d\n", projectIdx); continue; }

                char fpBuf[1024];
                snprintf(fpBuf, sizeof(fpBuf), "%s", braw_clip_get_filepath(clip));

                NSString* nb = [NSString stringWithUTF8String:fpBuf];
                if (!nb) { fprintf(stderr, "Skipping project index %d: invalid UTF-8\n", projectIdx); continue; }

                char fnBuf[256];
                const char* lastSlash = strrchr(fpBuf, '/');
                snprintf(fnBuf, sizeof(fnBuf), "%s", lastSlash ? lastSlash + 1 : fpBuf);
                NSString* bn = [[NSString stringWithUTF8String:fnBuf] stringByDeletingPathExtension];
                if (!bn) { fprintf(stderr, "Skipping project index %d: bad filename\n", projectIdx); continue; }

                // Always use source file's directory for output (ignore Swift's outputDir
                // which may be corrupted by dangling C string pointers)
                NSString* outDir = [[NSString stringWithUTF8String:fpBuf] stringByDeletingLastPathComponent];
                NSString* outPath = [outDir stringByAppendingPathComponent:[bn stringByAppendingString:@"_export.mov"]];
                if (!outPath) { fprintf(stderr, "Skipping project index %d: path construction failed\n", projectIdx); continue; }

                NSTask* task = [[NSTask alloc] init];
                task.executableURL = [NSURL fileURLWithPath:helper];
                task.arguments = @[nb, outPath,
                    [NSString stringWithFormat:@"%d", codec],
                    [NSString stringWithFormat:@"%d", proResProfile],
                    [NSString stringWithFormat:@"%d", resolutionMode],
                    [NSString stringWithFormat:@"%d", dataRateMbps]];
                NSPipe* op = [NSPipe pipe];
                NSPipe* ep = [NSPipe pipe];
                task.standardOutput = op;
                task.standardError = ep;
                NSFileHandle* rh = [op fileHandleForReading];
                NSFileHandle* eh = [(NSPipe*)task.standardError fileHandleForReading];

                NSError* err = nil;
                [task launchAndReturnError:&err];
                if (err) { fprintf(stderr, "Launch failed: %s\n", [[err description] UTF8String]); continue; }

                uint64_t totalFrames = braw_clip_get_frame_count(clip);
                NSMutableData* buf = [[NSMutableData alloc] init];
                while ([task isRunning] && !g_cancel) {
                    NSData* chunk = [rh availableData];
                    if (chunk.length == 0) break;
                    [buf appendData:chunk];
                    NSString* text = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
                    for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
                        if ([line hasPrefix:@"PROGRESS"]) {
                            int fi = 0;
                            sscanf([line UTF8String], "PROGRESS %d", &fi);
                            if (pf) pf(i, count, fi, (int)totalFrames, ctx);
                        }
                    }
                    NSString* last = [[text componentsSeparatedByString:@"\n"] lastObject];
                    buf = (last.length > 0)
                        ? [[last dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]
                        : [[NSMutableData alloc] init];
                }
                if (g_cancel && [task isRunning]) [task terminate];
                [task waitUntilExit];
                NSData* ed = [eh readDataToEndOfFile];
                if (ed.length > 0) fprintf(stderr, "helper: %s\n", [[[NSString alloc] initWithData:ed encoding:NSUTF8StringEncoding] UTF8String]);
                if ([task terminationStatus] == 0)
                    fprintf(stderr, "Export OK: %s\n", [outPath UTF8String]);
                else
                    fprintf(stderr, "Export FAILED: %s\n", [outPath UTF8String]);
            }
            g_running=false;
            if (pf) pf(count-1, count, -1, -1, ctx);
        }
    });
    return 0;
}

void braw_export_cancel(void) { g_cancel=true; }
int  braw_export_is_running(void) { return g_running?1:0; }

} // extern "C"
