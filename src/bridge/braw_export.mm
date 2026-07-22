#include "bridge/braw_api.h"
#include "core/Types.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#include <atomic>
#include <dispatch/dispatch.h>
#include <unistd.h>

// File-based diagnostics (same file as Swift diag)
#define DIAG(...) do { \
    FILE* _d = fopen("/tmp/braw_diag.txt", "a"); \
    if (_d) { fprintf(_d, "C: " __VA_ARGS__); fclose(_d); } \
} while(0)

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

// Map BRAW gamma to AVFoundation transfer function for Resolve ACM auto-detection.
// "Blackmagic Design Film" and "Blackmagic Design Video" both map closest to BT.709/BT.1886.
static NSString* gammaToTransfer(const char* gamma) {
    if (!gamma || !gamma[0]) return AVVideoTransferFunction_ITU_R_709_2;
    return AVVideoTransferFunction_ITU_R_709_2;
}

// Map BRAW gamut + color science gen to color primaries.
// "Blackmagic Wide Gamut" (Gen 5+) → BT.2020 primaries (closest standard wide gamut).
// "Blackmagic Design" (Gen 4) → BT.709 primaries.
static NSString* gamutToPrimaries(const char* gamut, uint16_t gen) {
    if (gen >= 5) return AVVideoColorPrimaries_ITU_R_2020;
    if (!gamut || !gamut[0]) return AVVideoColorPrimaries_ITU_R_709_2;
    std::string g(gamut);
    if (g.find("Wide") != std::string::npos) return AVVideoColorPrimaries_ITU_R_2020;
    return AVVideoColorPrimaries_ITU_R_709_2;
}

// Map BRAW gamut + gen to YCbCr matrix. Must match primaries for correct RGB→YUV conversion.
static NSString* gamutToMatrix(const char* gamut, uint16_t gen) {
    if (gen >= 5) return AVVideoYCbCrMatrix_ITU_R_2020;
    if (!gamut || !gamut[0]) return AVVideoYCbCrMatrix_ITU_R_709_2;
    std::string g(gamut);
    if (g.find("Wide") != std::string::npos) return AVVideoYCbCrMatrix_ITU_R_2020;
    return AVVideoYCbCrMatrix_ITU_R_709_2;
}

// Write EXIF metadata into the MOV file using exiftool.
// Resolve reads EXIF natively; this is the industry-standard approach
// used by Panasonic, Sony, Canon, etc. in their MOV files.
static void writeExifMetadata(const std::string& movPath, BrawClipHandle* clip, float fps) {
    NSString* exiftool = @"/usr/local/bin/exiftool";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:exiftool])
        exiftool = @"/opt/homebrew/bin/exiftool";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:exiftool]) {
        fprintf(stderr, "EXIF: exiftool not found, skipping metadata\n");
        return;
    }

    // Effective values (user override, else native)
    uint32_t iso = braw_clip_get_iso(clip);
    if (iso == 0) iso = braw_clip_get_native_iso(clip);
    uint32_t wb = braw_clip_get_color_temp(clip);
    if (wb == 0) wb = braw_clip_get_native_color_temp(clip);

    NSMutableArray* args = [NSMutableArray arrayWithObjects:
        @"-overwrite_original", @"-P", @"-m", nil];

    // ── Standard EXIF tags (group prefix required so they go into EXIF, not XMP) ──
    [args addObject:@"-EXIF:Make=Blackmagic Design"];
    const char* ct = braw_clip_get_camera_type(clip);
    if (ct && ct[0])
        [args addObject:[NSString stringWithFormat:@"-EXIF:Model=%s", ct]];
    if (iso > 0)
        [args addObject:[NSString stringWithFormat:@"-EXIF:ISO=%u", iso]];
    if (wb > 0)
        [args addObject:[NSString stringWithFormat:@"-EXIF:ColorTemperature=%u", wb]];
    [args addObject:@"-EXIF:ExposureProgram=Manual"];
    [args addObject:@"-EXIF:Software=BrawTranscoder 1.0"];

    // ── Free-form BRAW metadata → EXIF / XMP ──
    int ffCount = braw_clip_get_metadata_count(clip);
    for (int i = 0; i < ffCount; i++) {
        const char* k = braw_clip_get_metadata_key(clip, i);
        const char* v = braw_clip_get_metadata_value(clip, i);
        if (!k || !k[0] || !v || !v[0]) continue;
        if (strstr(v, "(unknown type)")) continue;
        NSString* key = [NSString stringWithUTF8String:k];
        NSString* val = [NSString stringWithUTF8String:v];

        if ([key isEqualToString:@"lens_type"]) {
            [args addObject:[NSString stringWithFormat:@"-EXIF:LensModel=%@", val]];
            // Parse focal length from lens name (e.g. "LUMIX S 50/F1.8")
            NSRange slash = [val rangeOfString:@"/" options:NSBackwardsSearch];
            if (slash.location != NSNotFound && slash.location > 0) {
                NSString* before = [val substringToIndex:slash.location];
                NSCharacterSet* digits = [NSCharacterSet decimalDigitCharacterSet];
                NSRange lastDigit = [before rangeOfCharacterFromSet:digits options:NSBackwardsSearch];
                if (lastDigit.location != NSNotFound) {
                    NSRange numStart = [before rangeOfCharacterFromSet:digits options:NSBackwardsSearch
                        range:NSMakeRange(0, lastDigit.location + 1)];
                    if (numStart.location != NSNotFound) {
                        NSString* fl = [before substringWithRange:
                            NSMakeRange(numStart.location, lastDigit.location - numStart.location + 1)];
                        [args addObject:[NSString stringWithFormat:@"-EXIF:FocalLength=%@", fl]];
                        [args addObject:[NSString stringWithFormat:@"-EXIF:FocalLengthIn35mmFormat=%@", fl]];
                    }
                }
                // Parse aperture from after the slash — strip "F"/"f" prefix
                NSString* after = [val substringFromIndex:slash.location + 1];
                NSRange firstDigit = [after rangeOfCharacterFromSet:digits];
                if (firstDigit.location != NSNotFound) {
                    NSString* numStr = [after substringFromIndex:firstDigit.location];
                    NSScanner* sc = [NSScanner scannerWithString:numStr];
                    double ap = 0;
                    if ([sc scanDouble:&ap] && ap > 0)
                        [args addObject:[NSString stringWithFormat:@"-EXIF:FNumber=%g", ap]];
                }
            }
        }
        else if ([key isEqualToString:@"date_recorded"]) {
            [args addObject:[NSString stringWithFormat:@"-EXIF:CreateDate=%@ 00:00:00", val]];
        }
        else if ([key isEqualToString:@"camera_id"]) {
            [args addObject:[NSString stringWithFormat:@"-EXIF:SerialNumber=%@", val]];
        }
        else if ([key isEqualToString:@"firmware_version"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:FirmwareVersion=%@", val]];
        }
        else if ([key isEqualToString:@"camera_number"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:CameraNumber=%@", val]];
        }
        else if ([key isEqualToString:@"shutter_type"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:ShutterType=%@", val]];
        }
        else if ([key isEqualToString:@"sensor_line_time"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:SensorLineTime=%@", val]];
        }
        else if ([key isEqualToString:@"braw_compression_ratio"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:BRAWCompressionRatio=%@", val]];
        }
        else if ([key isEqualToString:@"reel_name"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:ReelName=%@", val]];
        }
        else if ([key isEqualToString:@"scene"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:Scene=%@", val]];
        }
        else if ([key isEqualToString:@"take"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:Take=%@", val]];
        }
        else if ([key isEqualToString:@"lens_distortion_correction_enable"] ||
                 [key isEqualToString:@"lens_chromatic_aberration_correction_enable"] ||
                 [key isEqualToString:@"lens_shading_enable"] ||
                 [key isEqualToString:@"day_night"] ||
                 [key isEqualToString:@"shot_type"]) {
            [args addObject:[NSString stringWithFormat:@"-XMP:%@=%@", key, val]];
        }
    }

    // ── Blackmagic color metadata as XMP custom namespace ──
    const char* gammaS = braw_clip_get_gamma(clip);
    const char* gamutS = braw_clip_get_gamut(clip);
    uint16_t gen = braw_clip_get_color_science_gen(clip);
    if (gammaS && gammaS[0])
        [args addObject:[NSString stringWithFormat:@"-XMP:Gamma=%s", gammaS]];
    if (gamutS && gamutS[0])
        [args addObject:[NSString stringWithFormat:@"-XMP:Gamut=%s", gamutS]];
    if (gen > 0)
        [args addObject:[NSString stringWithFormat:@"-XMP:ColorScienceGen=%u", gen]];

    // Tint and exposure from native settings
    [args addObject:[NSString stringWithFormat:@"-XMP:Tint=%d",
                     braw_clip_get_native_tint(clip)]];
    [args addObject:[NSString stringWithFormat:@"-XMP:Exposure=%.2f",
                     braw_clip_get_native_exposure(clip)]];

    // Frame rate
    [args addObject:[NSString stringWithFormat:@"-XMP:CameraFPS=%.3f", fps]];

    [args addObject:[NSString stringWithUTF8String:movPath.c_str()]];

    fprintf(stderr, "EXIF: writing metadata with exiftool...\n");
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:exiftool];
    task.arguments = args;
    NSPipe* errPipe = [NSPipe pipe];
    task.standardError = errPipe;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    NSError* err = nil;
    [task launchAndReturnError:&err];
    if (err) {
        fprintf(stderr, "EXIF: launch failed: %s\n", [[err description] UTF8String]);
        return;
    }
    [task waitUntilExit];
    if (task.terminationStatus == 0) {
        fprintf(stderr, "EXIF: metadata written successfully\n");
    } else {
        NSData* ed = [[errPipe fileHandleForReading] readDataToEndOfFile];
        if (ed.length > 0) fprintf(stderr, "EXIF: %s\n",
            [[[NSString alloc] initWithData:ed encoding:NSUTF8StringEncoding] UTF8String]);
    }
}

static bool exportMOV(BrawClipHandle* clip, int outW, int outH, float fps,
                       uint64_t frameStart, uint64_t frameEnd,
                       int codec, int bitrate,
                       const std::string& outPath,
                       ExportProgressFn pf, void* pctx, int ci, int tc) {
    DIAG("exportMOV: enter range=[%llu,%llu) path=%s\n",
         (unsigned long long)frameStart, (unsigned long long)frameEnd, outPath.c_str());
    @autoreleasepool {
        uint64_t segmentFrames = frameEnd - frameStart;
        if (segmentFrames == 0) { DIAG("exportMOV: zero frames\n"); return false; }

        if (pf) { DIAG("exportMOV: calling progress callback\n"); pf(ci, tc, (int)frameStart, (int)frameEnd, pctx); }
        uint32_t srcW = braw_clip_get_width(clip);
        uint32_t srcH = braw_clip_get_height(clip);

        // ---- Extract audio with channel pruning ----
        uint32_t audioRate = 0, audioChannels = 0;
        uint64_t audioSamples = 0;
        DIAG("exportMOV: extracting audio...\n");
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

        // Slice audio to this segment's frame range
        uint64_t audioStartSample = 0;
        uint64_t audioEndSample = audioSamples;
        if (audioData && audioRate > 0 && fps > 0 && audioSamples > 0) {
            audioStartSample = (uint64_t)((double)frameStart * (double)audioRate / (double)fps);
            audioEndSample   = (uint64_t)((double)frameEnd   * (double)audioRate / (double)fps);
            if (audioStartSample > audioSamples) audioStartSample = audioSamples;
            if (audioEndSample > audioSamples) audioEndSample = audioSamples;
        }
        uint64_t segmentAudioSamples = (audioEndSample > audioStartSample) ? (audioEndSample - audioStartSample) : 0;

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

        // ── Minimal QuickTime user data for file identification ──
        {
            NSMutableArray* metaItems = [NSMutableArray array];
            AVMutableMetadataItem* make = [AVMutableMetadataItem metadataItem];
            make.key = AVMetadataQuickTimeUserDataKeyMake;
            make.keySpace = AVMetadataKeySpaceQuickTimeUserData;
            make.value = @"Blackmagic Design";
            [metaItems addObject:make];
            const char* ct = braw_clip_get_camera_type(clip);
            if (ct && ct[0]) {
                AVMutableMetadataItem* model = [AVMutableMetadataItem metadataItem];
                model.key = AVMetadataQuickTimeUserDataKeyModel;
                model.keySpace = AVMetadataKeySpaceQuickTimeUserData;
                model.value = [NSString stringWithUTF8String:ct];
                [metaItems addObject:model];
            }
            writer.metadata = metaItems;
        }

        // Video input with color metadata for Resolve ACM auto-detection
        const char* gammaStr = braw_clip_get_gamma(clip);
        const char* gamutStr = braw_clip_get_gamut(clip);
        uint16_t csGen = braw_clip_get_color_science_gen(clip);

        NSString* primaries = gamutToPrimaries(gamutStr, csGen);
        NSString* transfer = gammaToTransfer(gammaStr);
        NSString* matrix = gamutToMatrix(gamutStr, csGen);

        NSMutableDictionary* compressionProps = [NSMutableDictionary dictionaryWithDictionary:@{
            AVVideoAverageBitRateKey: @(bitrate),
            AVVideoMaxKeyFrameIntervalKey: @((int)(fps * 2)),
            AVVideoProfileLevelKey: (codec == 0) ? AVVideoProfileLevelH264HighAutoLevel
                                                   : @"HEVC_Main10_AutoLevel",
            AVVideoAllowFrameReorderingKey: @NO,
            AVVideoExpectedSourceFrameRateKey: @((int)fps),
        }];
        if (primaries) compressionProps[AVVideoColorPrimariesKey] = primaries;
        if (transfer)  compressionProps[AVVideoTransferFunctionKey] = transfer;
        if (matrix)    compressionProps[AVVideoYCbCrMatrixKey] = matrix;

        NSDictionary* vidSettings = @{
            AVVideoCodecKey: (codec == 0) ? AVVideoCodecTypeH264 : AVVideoCodecTypeHEVC,
            AVVideoWidthKey: @(outW),
            AVVideoHeightKey: @(outH),
            AVVideoCompressionPropertiesKey: compressionProps,
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
        if (audioData && audioRate > 0 && segmentAudioSamples > 0) {
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
        __block uint64_t frameIdx = frameStart;

        [videoInput requestMediaDataWhenReadyOnQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                                          usingBlock:^{
            @autoreleasepool {
                bool origPreviewLUT = braw_clip_get_preview_lut(clip);
                braw_clip_set_preview_lut(clip, false);

                // No decoder resets within a segment — each helper runs one
                // decoder lifecycle, then exits. OS reclaims all leaked memory.
                while (frameIdx < frameEnd && !g_cancel && !inputFinished) {
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
                        // Segment-relative PTS so concat demuxer can sequence correctly
                        CMTime pts = CMTimeMake((int64_t)(frameIdx - frameStart), (int32_t)fps);
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
                    // Report global frame index for progress tracking
                    if (pf) pf(ci, tc, (int)frameIdx, (int)(frameEnd - frameStart), pctx);
                    frameIdx++;
                }
                braw_clip_set_preview_lut(clip, origPreviewLUT);
                if (frameIdx >= frameEnd || g_cancel) {
                    if (!inputFinished) {
                        [videoInput markAsFinished];
                        inputFinished = true;
                    }
                    videoDone = true;
                    braw_clip_release_decoder(clip);
                }
            }
        }];

        // Audio — float to s24be (24-bit big-endian PCM), sliced to this segment
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

                        for (uint64_t pos = audioStartSample; pos < audioEndSample && !g_cancel; pos += samplesPerChunk) {
                            if (!audioInput.readyForMoreMediaData) { usleep(1000); continue; }
                            uint64_t chunk = std::min(samplesPerChunk, audioEndSample - pos);
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
                                        dst[s * 3 + 0] = (uint8_t)(sample >> 16);
                                        dst[s * 3 + 1] = (uint8_t)(sample >> 8);
                                        dst[s * 3 + 2] = (uint8_t)(sample >> 0);
                                    }
                                }
                                CMSampleBufferRef sbuf = NULL;
                                // Segment-relative audio PTS
                                CMTime audioPts = CMTimeMake((int64_t)(pos - audioStartSample), (int32_t)audioRate);
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

            if (writer.status == AVAssetWriterStatusCompleted) {
                writeExifMetadata(outPath, clip, fps);
            }
        }

        if (pxPool) CVPixelBufferPoolRelease(pxPool);
        return writer.status == AVAssetWriterStatusCompleted;
    }
}

// ── ffmpeg concat: merge segment MOV files into final output ────────────
static bool runFFmpegConcat(const std::string& outputPath,
                             const std::vector<std::string>& segments) {
    if (segments.size() == 1) {
        // Single segment — just rename
        if (rename(segments[0].c_str(), outputPath.c_str()) != 0) {
            fprintf(stderr, "CONCAT: rename %s -> %s failed\n", segments[0].c_str(), outputPath.c_str());
            return false;
        }
        return true;
    }

    // Write concat file
    char concatTmp[512];
    snprintf(concatTmp, sizeof(concatTmp), "/tmp/braw_concat_%d_%d.txt", getpid(), rand());
    FILE* listFile = fopen(concatTmp, "w");
    if (!listFile) { fprintf(stderr, "CONCAT: failed to create %s\n", concatTmp); return false; }
    for (const auto& seg : segments) {
        fprintf(listFile, "file '%s'\n", seg.c_str());
    }
    fclose(listFile);

    // Find ffmpeg
    NSString* ffmpeg = findFFmpeg();
    if (!ffmpeg) {
        fprintf(stderr, "CONCAT: ffmpeg not found\n");
        unlink(concatTmp);
        return false;
    }

    // Run ffmpeg concat demuxer
    NSString* outNS = [NSString stringWithUTF8String:outputPath.c_str()];
    NSString* listNS = [NSString stringWithUTF8String:concatTmp];
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffmpeg];
    task.arguments = @[@"-y", @"-f", @"concat", @"-safe", @"0",
                        @"-i", listNS,
                        @"-c", @"copy", @"-movflags", @"+faststart", outNS];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    NSError* err = nil;
    [task launchAndReturnError:&err];
    if (err) {
        fprintf(stderr, "CONCAT: launch failed: %s\n", [[err description] UTF8String]);
        unlink(concatTmp);
        return false;
    }
    [task waitUntilExit];
    unlink(concatTmp);
    bool ok = (task.terminationStatus == 0);
    if (!ok) fprintf(stderr, "CONCAT: ffmpeg exit code %d\n", task.terminationStatus);

    // Clean up segment files
    for (const auto& seg : segments) unlink(seg.c_str());
    return ok;
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
        outPath = ods + "/" + nm + ".mov";
    }

    g_running=true; g_cancel=false;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        for (int ci=0; ci<count && !g_cancel; ci++) {
            auto* c = braw_project_get_clip(proj, indices[ci]);
            if (!c) continue;
            uint64_t clipFrames = braw_clip_get_frame_count(c);
            exportMOV(c, ow, oh, fps, 0, clipFrames, codec, dataRateMbps*1000000, outPath, pf, ctx, ci, count);
        }
        g_running=false;
        if (pf) pf(0,0,-1,-1,ctx);
    });
    return 0;
}

// Export a single frame range segment — called by export_helper subprocess.
// Writes video+audio for frames [frameStart, frameEnd) to outputPath.
int braw_export_segment(BrawClipHandle* clip,
                         int codec, int proResProfile, int resolutionMode, int dataRateMbps,
                         const char* outputPath,
                         uint64_t frameStart, uint64_t frameEnd,
                         ExportProgressFn pf, void* ctx) {
    fprintf(stderr, "EXPORT_SEGMENT: enter clip=%p path=%s range=[%llu,%llu)\n",
            (void*)clip, outputPath ? outputPath : "(null)",
            (unsigned long long)frameStart, (unsigned long long)frameEnd);
    if (!clip || !outputPath || frameStart >= frameEnd) {
        fprintf(stderr, "EXPORT_SEGMENT: invalid args\n");
        return -1;
    }

    uint32_t sw = braw_clip_get_width(clip);
    uint32_t sh = braw_clip_get_height(clip);
    float fps = braw_clip_get_frame_rate(clip);
    int ow = (int)sw, oh = (int)sh;
    int hs[] = {0, 2160, 2160, 1080, 1080};
    if (resolutionMode > 0 && resolutionMode < 5 && hs[resolutionMode] > 0) {
        oh = hs[resolutionMode];
        ow = (int)((float)oh * sw / sh);
        ow = (ow + 1) & ~1;
    }

    bool ok = exportMOV(clip, ow, oh, fps, frameStart, frameEnd,
                         codec, dataRateMbps * 1000000,
                         std::string(outputPath), pf, ctx, 0, 1);
    return ok ? 0 : -1;
}

int braw_export_start(BrawProjectHandle* proj, const int* indices, int count,
                       int codec, int proResProfile, int resolutionMode, int dataRateMbps,
                       const char* outputDir, ExportProgressFn pf, void* ctx) {
    DIAG("braw_export_start: count=%d\n", count);
    if (g_running || !proj || !indices || count<=0) {
        DIAG("braw_export_start: g_running=%d proj=%p\n", g_running.load(), (void*)proj);
        return -1;
    }
    NSString* helper = helperPath();
    DIAG("helperPath: %s\n", helper ? [helper UTF8String] : "nil");
    if (!helper) { fprintf(stderr, "export_helper binary not found\n"); return -1; }

    std::vector<int> indicesCopy(indices, indices + count);
    std::string outDirBase = (outputDir && outputDir[0]) ? outputDir : "";

    g_running=true; g_cancel=false;
    fprintf(stderr, "EXPORT: starting export for %d clips\n", count);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            const uint64_t kSegFrames = BRAW_EXPORT_SEGMENT_FRAMES;
            const auto& idxVec = indicesCopy;

            for (int i=0; i<(int)idxVec.size() && !g_cancel; i++) {
                int projectIdx = idxVec[i];
                auto* clip = braw_project_get_clip(proj, projectIdx);
                if (!clip) { fprintf(stderr, "EXPORT: clip null at project index %d\n", projectIdx); continue; }

                char fpBuf[1024];
                snprintf(fpBuf, sizeof(fpBuf), "%s", braw_clip_get_filepath(clip));
                fprintf(stderr, "EXPORT: processing clip %d: %s\n", projectIdx, fpBuf);

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
                NSString* outPathBase = [outDir stringByAppendingPathComponent:[bn stringByAppendingString:@".mov"]];
                if (!outPathBase) { fprintf(stderr, "Skipping project index %d: path construction failed\n", projectIdx); continue; }
                std::string finalOutput = [outPathBase UTF8String];

                uint32_t adjIso = braw_clip_get_iso(clip);
                uint32_t adjCt  = braw_clip_get_color_temp(clip);
                int16_t  adjTint = braw_clip_get_tint(clip);
                float    adjExp  = braw_clip_get_exposure(clip);
                bool     adjHl   = braw_clip_get_highlight_recovery(clip);
                bool     adjBl   = braw_clip_get_bake_lut(clip);

                uint64_t totalFrames = braw_clip_get_frame_count(clip);
                if (totalFrames == 0) { fprintf(stderr, "clip %d: zero frames, skipping\n", projectIdx); continue; }

                // Build segment paths
                uint64_t numSegments = (totalFrames + kSegFrames - 1) / kSegFrames;
                fprintf(stderr, "EXPORT: clip %d: %llu frames, %llu segments (%llu each)\n",
                        projectIdx, (unsigned long long)totalFrames,
                        (unsigned long long)numSegments, (unsigned long long)kSegFrames);
                std::vector<std::string> segmentPaths;
                std::vector<bool> segmentOK(numSegments, false);
                bool clipFailed = false;

                for (uint64_t seg = 0; seg < numSegments && !g_cancel && !clipFailed; seg++) {
                DIAG("launching segment %llu/%llu helper=%s\n",
                     (unsigned long long)seg, (unsigned long long)numSegments,
                     [helper UTF8String]);
                fprintf(stderr, "EXPORT: launching segment %llu/%llu\n",
                        (unsigned long long)seg, (unsigned long long)numSegments);
                    uint64_t segStart = seg * kSegFrames;
                    uint64_t segEnd = std::min(segStart + kSegFrames, totalFrames);

                    char segPath[1024];
                    snprintf(segPath, sizeof(segPath), "%s.seg_%03llu.mov",
                             finalOutput.c_str(), (unsigned long long)seg);
                    segmentPaths.push_back(std::string(segPath));

                    NSString* segPathNS = [NSString stringWithUTF8String:segPath];
                    NSTask* task = [[NSTask alloc] init];
                    task.executableURL = [NSURL fileURLWithPath:helper];
                    task.arguments = @[nb, segPathNS,
                        [NSString stringWithFormat:@"%d", codec],
                        [NSString stringWithFormat:@"%d", proResProfile],
                        [NSString stringWithFormat:@"%d", resolutionMode],
                        [NSString stringWithFormat:@"%d", dataRateMbps],
                        [NSString stringWithFormat:@"%u", adjIso],
                        [NSString stringWithFormat:@"%u", adjCt],
                        [NSString stringWithFormat:@"%d", adjTint],
                        [NSString stringWithFormat:@"%f", adjExp],
                        [NSString stringWithFormat:@"%d", adjHl ? 1 : 0],
                        [NSString stringWithFormat:@"%d", adjBl ? 1 : 0],
                        [NSString stringWithFormat:@"%llu", (unsigned long long)segStart],
                        [NSString stringWithFormat:@"%llu", (unsigned long long)segEnd]];

                    NSPipe* op = [NSPipe pipe];
                    task.standardOutput = op;
                    // Send stderr to parent's stderr to avoid pipe buffer deadlocks
                    task.standardError = [NSFileHandle fileHandleWithStandardError];
                    NSFileHandle* rh = [op fileHandleForReading];

                    NSError* err = nil;
                    [task launchAndReturnError:&err];
                    if (err) {
                        fprintf(stderr, "Segment launch failed: %s\n", [[err description] UTF8String]);
                        g_cancel = true;
                        [task terminate];
                        clipFailed = true;
                        break;
                    }

                    g_exportTask = task;

                    // Read progress from helper stdout
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
                                // Report global frame index within the clip
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

                    if ([task terminationStatus] == 0) {
                        fprintf(stderr, "Segment %llu/%llu OK\n",
                                (unsigned long long)seg, (unsigned long long)numSegments);
                        segmentOK[seg] = true;
                    } else {
                        fprintf(stderr, "Segment %llu/%llu FAILED (exit %d)\n",
                                (unsigned long long)seg, (unsigned long long)numSegments,
                                task.terminationStatus);
                        clipFailed = true;
                        break;
                    }

                }

                // ── Concatenate segments for this clip ──
                if (!clipFailed && !g_cancel) {
                    fprintf(stderr, "EXPORT: concatenating %llu segments for clip %d\n",
                            (unsigned long long)numSegments, projectIdx);
                    // Collect only successfully completed segments
                    std::vector<std::string> goodSegments;
                    for (uint64_t seg = 0; seg < numSegments; seg++) {
                        if (segmentOK[seg]) goodSegments.push_back(segmentPaths[seg]);
                    }
                    if (goodSegments.empty()) {
                        fprintf(stderr, "EXPORT: no segments to concatenate for clip %d\n", projectIdx);
                        continue;
                    }

                    // Remove final output if it exists (concat will fail otherwise)
                    unlink(finalOutput.c_str());

                    bool concatOK = runFFmpegConcat(finalOutput, goodSegments);
                    if (concatOK) {
                        fprintf(stderr, "EXPORT: concat OK: %s\n", finalOutput.c_str());
                        fprintf(stderr, "EXPORT: writing EXIF metadata...\n");
                        float fps = braw_clip_get_frame_rate(clip);
                        writeExifMetadata(finalOutput, clip, fps);
                    } else {
                        fprintf(stderr, "EXPORT: concat FAILED for clip %d\n", projectIdx);
                    }
                } else {
                    // Clip failed or was cancelled — clean up any segments
                    for (const auto& sp : segmentPaths) unlink(sp.c_str());
                }
            }

            // Safety kill
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
