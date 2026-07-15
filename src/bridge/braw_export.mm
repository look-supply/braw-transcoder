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

// Track current export subprocess so cancel can terminate it
static NSTask* g_exportTask = nil;

// Callback for CVPixelBufferCreateWithBytes — frees the malloc'd pixel data
static void pixelBufferReleaseCallback(void* ref, const void* data) {
    braw_clip_free_frame((uint8_t*)data);
}

// GPU decode for speed (18fps vs 2fps CPU). Decoder is torn down and
// recreated every CHUNK_SIZE frames to clear persistent GPU memory leaks
// in the BRAW SDK. AVAssetWriter stays open across resets — single output.

// Find ffmpeg binary: bundled in app Resources, relative to executable, system
static NSString* findFFmpeg(void) {
    // 1. Inside MacOS/ alongside main executable (bundled by build.sh)
    NSString* execPath = [[NSBundle mainBundle] executablePath];
    if (execPath) {
        NSString* s = [[execPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"ffmpeg"];
        if (s && [[NSFileManager defaultManager] isExecutableFileAtPath:s])
            return s;
    }
    // 2. App bundle Resources/ffmpeg (legacy)
    NSString* bundled = [[NSBundle mainBundle] pathForResource:@"ffmpeg" ofType:nil];
    if (bundled && [[NSFileManager defaultManager] isExecutableFileAtPath:bundled])
        return bundled;
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
        // Signal start — pf prints PROGRESS 0 to stdout, read live by parent
        if (pf) pf(ci, tc, 0, (int)frameCount, pctx);
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

        // ---- Video + Audio via AVAssetWriter (direct to outPath) ----
        NSDictionary* poolAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(srcW),
            (id)kCVPixelBufferHeightKey: @(srcH),
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        NSDictionary* poolOpts = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @(8),
        };
        CVPixelBufferPoolRef pxPool = NULL;
        CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolOpts, (__bridge CFDictionaryRef)poolAttrs, &pxPool);

        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:outPath.c_str()] error:nil];
        NSURL* url = [NSURL fileURLWithPath:@(outPath.c_str())];
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

        // Video input
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

        // Audio input — 24-bit big-endian PCM (pcm_s24be, matches reference MOV)
        AVAssetWriterInput* audioInput = nil;
        if (audioData && audioRate > 0 && audioSamples > 0) {
            NSDictionary* audioSettings = @{
                AVFormatIDKey: @(kAudioFormatLinearPCM),
                AVSampleRateKey: @(audioRate),
                AVNumberOfChannelsKey: @(audioChannels),
                AVLinearPCMBitDepthKey: @(24),
                AVLinearPCMIsFloatKey: @NO,
                AVLinearPCMIsNonInterleaved: @NO,
                AVLinearPCMIsBigEndianKey: @YES,
            };
            audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                        outputSettings:audioSettings];
            audioInput.expectsMediaDataInRealTime = NO;
            [writer addInput:audioInput];
        }

        [writer startWriting];
        [writer startSessionAtSourceTime:kCMTimeZero];

        __block bool videoDone = false;
        __block bool audioDone = (audioInput == nil);
        __block bool inputFinished = false;
        __block uint64_t frameIdx = 0;
        static const int64_t CHUNK_SIZE = 200;

        [videoInput requestMediaDataWhenReadyOnQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                                          usingBlock:^{
            @autoreleasepool {
                bool origPreviewLUT = braw_clip_get_preview_lut(clip);
                braw_clip_set_preview_lut(clip, false);

                while (frameIdx < frameCount && !g_cancel && !inputFinished) {
                    // Release and recreate decoder at chunk boundaries to clear
                    // persistent GPU memory leaks in the BRAW SDK.
                    if (frameIdx % CHUNK_SIZE == 0 && frameIdx > 0) {
                        braw_clip_release_decoder(clip);
                    }

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
                    braw_clip_release_decoder(clip);
                }
            }
        }];

        // Audio — float to s24be (24-bit big-endian PCM)
        if (audioInput && audioData) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                @autoreleasepool {
                    AudioStreamBasicDescription asbd = {};
                    asbd.mSampleRate = audioRate;
                    asbd.mFormatID = kAudioFormatLinearPCM;
                    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian;
                    asbd.mBitsPerChannel = 24;
                    asbd.mChannelsPerFrame = audioChannels;
                    asbd.mBytesPerFrame = 3 * audioChannels;
                    asbd.mBytesPerPacket = 3 * audioChannels;
                    asbd.mFramesPerPacket = 1;

                    CMFormatDescriptionRef audioFmtDesc = NULL;
                    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &audioFmtDesc);

                    if (audioFmtDesc) {
                        uint64_t samplesPerChunk = audioRate / (int)fps;
                        if (samplesPerChunk == 0) samplesPerChunk = 1024;

                        for (uint64_t pos = 0; pos < audioSamples && !g_cancel; pos += samplesPerChunk) {
                            if (!audioInput.readyForMoreMediaData) { usleep(1000); continue; }
                            uint64_t chunk = std::min(samplesPerChunk, audioSamples - pos);
                            uint64_t numFloats = chunk * audioChannels;
                            uint64_t byteCount = numFloats * 3;

                            CMBlockBufferRef blockBuf = NULL;
                            CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL,
                                byteCount, NULL, NULL, 0, byteCount,
                                kCMBlockBufferAssureMemoryNowFlag, &blockBuf);
                            if (blockBuf) {
                                char* dst = NULL;
                                CMBlockBufferGetDataPointer(blockBuf, 0, NULL, NULL, &dst);
                                if (dst) {
                                    for (uint64_t s = 0; s < numFloats; s++) {
                                        float f = audioData[pos * audioChannels + s];
                                        if (f > 1.0f) f = 1.0f;
                                        if (f < -1.0f) f = -1.0f;
                                        int32_t sample = (int32_t)(f * 8388607.0f);
                                        // Big-endian: high byte first
                                        dst[s * 3 + 0] = (uint8_t)(sample >> 16);
                                        dst[s * 3 + 1] = (uint8_t)(sample >> 8);
                                        dst[s * 3 + 2] = (uint8_t)(sample >> 0);
                                    }
                                }
                                CMSampleBufferRef sbuf = NULL;
                                CMTime audioPts = CMTimeMake((int64_t)pos, (int32_t)audioRate);
                                CMAudioSampleBufferCreateWithPacketDescriptions(kCFAllocatorDefault,
                                    blockBuf, true, NULL, NULL, audioFmtDesc,
                                    (CMItemCount)chunk, audioPts, NULL, &sbuf);
                                if (sbuf) { [audioInput appendSampleBuffer:sbuf]; CFRelease(sbuf); }
                                CFRelease(blockBuf);
                            }
                        }
                        CFRelease(audioFmtDesc);
                    }
                    free(audioData);
                    [audioInput markAsFinished];
                    audioDone = true;
                }
            });
        } else {
            if (audioData) free(audioData);
            audioDone = true;
        }

        while (!videoDone || !audioDone) {
            if (g_cancel) { [writer cancelWriting]; break; }
            usleep(50000);
        }

        if (!g_cancel) {
            [writer finishWritingWithCompletionHandler:^{}];
            while (writer.status == AVAssetWriterStatusWriting) usleep(50000);
        }

        if (pxPool) CVPixelBufferPoolRelease(pxPool);
        return writer.status == AVAssetWriterStatusCompleted;
    }
}

extern "C" {

static NSString* helperPath(void) {
    // 1. Inside app bundle next to main executable (production + `build.sh`)
    NSString* ep = [[NSBundle mainBundle] executablePath];
    if (ep) {
        NSString* s = [[ep stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"export_helper"];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:s]) return s;
    }
    // 2. Bundle parent directory (legacy dev builds)
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    if (bundlePath) {
        NSString* s = [[bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"export_helper"];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:s]) return s;
    }
    // 3. CWD build/export_helper (direct invocation)
    NSString* s = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"build/export_helper"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:s]) return s;
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"export_helper"]) return @"export_helper";
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

    // Copy async-safe values — Swift's outputDir pointer dangles by the
    // time the dispatch_async block executes.
    std::vector<int> indicesCopy(indices, indices + count);
    std::string outDirBase = (outputDir && outputDir[0]) ? outputDir : "";

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

                NSString* outDir;
                if (!outDirBase.empty()) {
                    outDir = [NSString stringWithUTF8String:outDirBase.c_str()];
                } else {
                    outDir = [[NSString stringWithUTF8String:fpBuf] stringByDeletingLastPathComponent];
                }
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

                // Track the current task for cancellation
                g_exportTask = task;

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
                g_exportTask = nil;
                NSData* ed = [eh readDataToEndOfFile];
                if (ed.length > 0) fprintf(stderr, "helper: %s\n", [[[NSString alloc] initWithData:ed encoding:NSUTF8StringEncoding] UTF8String]);
                if ([task terminationStatus] == 0)
                    fprintf(stderr, "Export OK: %s\n", [outPath UTF8String]);
                else
                    fprintf(stderr, "Export FAILED: %s\n", [outPath UTF8String]);
            }
            // Safety kill: ensure no helper lingers
            [g_exportTask terminate];
            [g_exportTask waitUntilExit];
            g_exportTask = nil;
            g_running=false;
            if (pf) pf(count-1, count, -1, -1, ctx);
        }
    });
    return 0;
}

void braw_export_cancel(void) {
    g_cancel=true;
    [g_exportTask terminate];
}

int  braw_export_is_running(void) { return g_running?1:0; }

void braw_export_cleanup(void) {
    g_cancel=true;
    [g_exportTask terminate];
    g_exportTask = nil;
    g_running=false;
}

} // extern "C"
