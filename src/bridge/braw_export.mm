#include "bridge/braw_api.h"
#include "core/BrawDecoder.h"
#include "core/Types.h"
#include <VideoToolbox/VideoToolbox.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreMedia/CoreMedia.h>
#include <fstream>
#include <atomic>
#include <dispatch/dispatch.h>

static std::atomic<bool> g_exportRunning{false};
static std::atomic<bool> g_exportCancel{false};
static dispatch_queue_t g_exportQueue = nullptr;

static void WriteNALUsToFile(const std::string& path, const void* data, size_t size, bool append) {
    auto mode = append ? std::ios::binary | std::ios::app : std::ios::binary;
    std::ofstream file(path, mode);
    if (file.is_open()) file.write((const char*)data, size);
}

struct ExportContext {
    BrawProjectHandle* project;
    std::vector<int> indices;
    int codec, proResProfile, resolutionMode, dataRateMbps;
    std::string outputDir;
    ExportProgressFn progressFn;
    void* progressCtx;
};

static CMVideoCodecType CodecToCMType(int codec) {
    switch (codec) {
        case 0: return kCMVideoCodecType_H264;
        case 1: return kCMVideoCodecType_HEVC;
        case 2: return kCMVideoCodecType_AppleProRes4444;
        default: return kCMVideoCodecType_HEVC;
    }
}

static void CompressionCallback(void* ctx, void*, OSStatus status, VTEncodeInfoFlags,
                                 CMSampleBufferRef sampleBuffer) {
    if (status != noErr || !sampleBuffer) return;
    auto* path = (std::string*)ctx;
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) return;
    size_t len = 0;
    char* ptr = nullptr;
    if (CMBlockBufferGetDataPointer(block, 0, nullptr, &len, &ptr) == noErr && ptr && len > 0) {
        WriteNALUsToFile(*path, ptr, len, true);
    }
}

static bool ExportClip(BrawClipHandle* clip, const ExportContext& ctx, int clipIdx, int totalClips) {
    uint64_t frameCount = braw_clip_get_frame_count(clip);
    float fps = braw_clip_get_frame_rate(clip);
    uint32_t srcW = braw_clip_get_width(clip);
    uint32_t srcH = braw_clip_get_height(clip);

    int outW, outH;
    int heights[] = {0, 2160, 2160, 1080, 1080};
    if (ctx.resolutionMode == 0 || heights[ctx.resolutionMode] == 0) {
        outW = srcW; outH = srcH;
    } else {
        outH = heights[ctx.resolutionMode];
        outW = (int)((float)outH * (float)srcW / (float)srcH);
        outW = (outW + 1) & ~1;
    }

    float decodeScale = 1.0f;
    if (outH > 0 && (int)srcH > outH) {
        float ratio = (float)outH / (float)srcH;
        if (ratio <= 0.125f)      decodeScale = 0.125f;
        else if (ratio <= 0.25f)  decodeScale = 0.25f;
        else if (ratio <= 0.5f)   decodeScale = 0.5f;
    }

    std::string baseName = braw_clip_get_filename(clip);
    std::string ext = (ctx.codec == 2) ? ".mov" : ".mp4";
    std::string outPath = ctx.outputDir + "/" + baseName + "_export" + ext;

    VTCompressionSessionRef session = nullptr;
    CMVideoCodecType cmCodec = CodecToCMType(ctx.codec);
    OSStatus err = VTCompressionSessionCreate(
        kCFAllocatorDefault, outW, outH, cmCodec,
        NULL, NULL, NULL,
        &CompressionCallback, (void*)&outPath, &session);
    if (err != noErr) return false;

    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, (__bridge CFTypeRef)@NO);
    if (ctx.codec == 1)
        VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel);

    int bitrate = ctx.dataRateMbps * 1000000;
    CFNumberRef cfBR = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bitrate);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, cfBR);
    CFRelease(cfBR);
    int keyFrame = (int)(fps * 2);
    CFNumberRef cfKF = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keyFrame);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, cfKF);
    CFRelease(cfKF);
    float quality = 0.85f;
    CFNumberRef cfQ = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &quality);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_Quality, cfQ);
    CFRelease(cfQ);

    VTCompressionSessionPrepareToEncodeFrames(session);
    WriteNALUsToFile(outPath, nullptr, 0, false);

    // Single reusable buffer — no per-frame alloc
    size_t bufBytes = (size_t)outW * outH * 4;
    std::vector<uint8_t> recycleBuf(bufBytes);

    for (uint64_t fi = 0; fi < frameCount; fi++) {
        if (g_exportCancel) break;

        int fw = 0, fh = 0;
        uint8_t* pixels = braw_clip_decode_frame_scaled(clip, fi, &fw, &fh, decodeScale);
        if (!pixels) continue;

        size_t frameBytes = (size_t)fw * fh * 4;
        CVPixelBufferRef pxBuf = NULL;
        CVReturn cvr = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault, fw, fh, kCVPixelFormatType_32BGRA,
            recycleBuf.data(), fw * 4, NULL, NULL, NULL, &pxBuf);

        if (cvr == kCVReturnSuccess && pxBuf) {
            CVPixelBufferLockBaseAddress(pxBuf, 0);
            memcpy(recycleBuf.data(), pixels, frameBytes);
            CVPixelBufferUnlockBaseAddress(pxBuf, 0);

            CMTime pts = CMTimeMake((int64_t)fi, (int32_t)fps);
            VTCompressionSessionEncodeFrame(session, pxBuf, pts, kCMTimeInvalid, NULL, NULL, NULL);
            VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
            CVPixelBufferRelease(pxBuf);
        }

        braw_clip_free_frame(pixels);

        if (ctx.progressFn)
            ctx.progressFn(clipIdx, totalClips, (int)fi, (int)frameCount, ctx.progressCtx);
    }

    VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    return true;
}

int braw_export_start(BrawProjectHandle* proj, const int* indices, int count,
                       int codec, int proResProfile, int resolutionMode, int dataRateMbps,
                       const char* outputDir,
                       ExportProgressFn progressFn, void* ctx) {
    if (g_exportRunning) return -1;
    if (!proj || !indices || count <= 0) return -1;
    if (!g_exportQueue)
        g_exportQueue = dispatch_queue_create("com.braw.export", DISPATCH_QUEUE_SERIAL);

    ExportContext* ec = new ExportContext();
    ec->project = proj;
    ec->indices.assign(indices, indices + count);
    ec->codec = codec;
    ec->proResProfile = proResProfile;
    ec->resolutionMode = resolutionMode;
    ec->dataRateMbps = dataRateMbps;
    ec->outputDir = outputDir ? outputDir : "";
    ec->progressFn = progressFn;
    ec->progressCtx = ctx;

    g_exportRunning = true;
    g_exportCancel = false;
    dispatch_async(g_exportQueue, ^{
        @autoreleasepool {
            for (int i = 0; i < (int)ec->indices.size(); i++) {
                if (g_exportCancel) break;
                BrawClipHandle* clip = braw_project_get_clip(ec->project, ec->indices[i]);
                if (clip) ExportClip(clip, *ec, i, (int)ec->indices.size());
            }
            g_exportRunning = false;
            if (ec->progressFn) ec->progressFn(0, 0, -1, -1, ec->progressCtx);
            delete ec;
        }
    });
    return 0;
}

void braw_export_cancel(void) { g_exportCancel = true; }
int  braw_export_is_running(void) { return g_exportRunning ? 1 : 0; }
