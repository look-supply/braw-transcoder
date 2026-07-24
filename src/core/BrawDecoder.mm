#include "core/BrawDecoder.h"
#include "BlackmagicRawAPI.h"
#include "BlackmagicRawAPIDispatch.cpp"
#import <CoreFoundation/CoreFoundation.h>
#include <iostream>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <thread>
#include <vector>
#include <cstdlib>

class BrawDecoderCallback;

// ── Forward declarations for batch decode ──────────────────────

struct BatchFrameInfo;
struct BatchContext;

// ── Per-frame result storage (single-frame path) ───────────────

struct DecodedFrame {
    int width = 0;
    int height = 0;
    int bytesPerRow = 0;
    std::vector<uint8_t> pixels;
};

// ── Batch slot (reusable slot tracking one in-flight frame) ────

struct BatchSlot {
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
    int bytesPerRow = 0;
    uint64_t frameIndex = UINT64_MAX;
    bool ready = false;
};

// ── Per-job user data for batch decode ─────────────────────────

struct BatchFrameInfo {
    uint64_t frameIndex;
    int slotIndex;
    ClipAdjustments adjustments;
    float scale;
    BatchContext* ctx;
    bool error = false;
};

// ── Shared batch state ─────────────────────────────────────────

struct BatchContext {
    uint64_t startFrame;
    uint64_t endFrame;
    uint64_t nextSubmit;      // next frame index to submit
    uint64_t nextDeliver;     // next frame index expected by consumer
    int concurrency;
    BrawDecoder::FrameCallback callback;
    std::vector<BatchSlot> slots;
    std::mutex mtx;
    std::condition_variable cv;
    bool done = false;
};

// ── BrawDecoder Impl ───────────────────────────────────────────

struct BrawDecoder::Impl {
    IBlackmagicRawFactory* factory = nullptr;
    IBlackmagicRaw*        codec   = nullptr;
    IBlackmagicRawClip*    clip    = nullptr;

    std::string filePath;
    uint32_t width  = 0;
    uint32_t height = 0;
    float frameRate = 0.0f;
    uint64_t frameCount = 0;
    std::string cameraType;

    // Single-frame decode state
    struct PendingRequest {
        uint64_t frameIndex;
        ClipAdjustments adjustments;
        BrawDecoder::FrameCallback callback;
        float scale = 1.0f;
        // Result storage
        std::vector<uint8_t> pixels;
        int resultWidth = 0;
        int resultHeight = 0;
        int resultBytesPerRow = 0;
    };
    PendingRequest pending;
    std::atomic<bool> frameReady{false};
    std::atomic<bool> callbackInvoked{false};
    std::mutex decodeMutex;
    std::condition_variable decodeCV;

    // Native camera settings (captured on first decode)
    bool nativeCaptured = false;
    uint32_t nativeISO = 800;
    uint32_t nativeColorTemp = 5600;
    int16_t nativeTint = 0;
    float nativeExposure = 0.0f;
    float frameFocalLength = 0.0f;
    BlackmagicRawResourceFormat resourceFormat = blackmagicRawResourceFormatBGRAU8;

    // Pipeline readiness (async PreparePipeline)
    bool pipelineReady = false;
    std::mutex pipelineMutex;
    std::condition_variable pipelineCV;

    BrawDecoderCallback* callback = nullptr;

    static CFStringRef ToCFString(const std::string& s) {
        return CFStringCreateWithCString(kCFAllocatorDefault, s.c_str(), kCFStringEncodingUTF8);
    }

    static std::string FromCFString(CFStringRef s) {
        if (!s) return "";
        const char* cstr = CFStringGetCStringPtr(s, kCFStringEncodingUTF8);
        if (cstr) return cstr;
        char buf[1024];
        if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8))
            return buf;
        return "";
    }
};

// ── Apply frame adjustments (shared between single and batch paths) ──

static void ApplyAdjustments(IBlackmagicRawClip* clip,
                              IBlackmagicRawFrameProcessingAttributes* frameAttrs,
                              const ClipAdjustments& adjustments,
                              uint32_t nativeISO,
                              uint32_t nativeColorTemp,
                              int16_t nativeTint,
                              float nativeExposure)
{
    Variant isoVal; VariantInit(&isoVal);
    isoVal.vt = blackmagicRawVariantTypeU32;
    isoVal.uintVal = adjustments.iso > 0 ? adjustments.iso : nativeISO;
    frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeISO, &isoVal);
    VariantClear(&isoVal);

    Variant kelvinVal; VariantInit(&kelvinVal);
    kelvinVal.vt = blackmagicRawVariantTypeU32;
    kelvinVal.uintVal = adjustments.colorTemp > 0 ? adjustments.colorTemp : nativeColorTemp;
    frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, &kelvinVal);
    VariantClear(&kelvinVal);

    Variant tintVal; VariantInit(&tintVal);
    tintVal.vt = blackmagicRawVariantTypeS16;
    tintVal.iVal = adjustments.tint != 0 ? adjustments.tint : nativeTint;
    frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint, &tintVal);
    VariantClear(&tintVal);

    Variant expVal; VariantInit(&expVal);
    expVal.vt = blackmagicRawVariantTypeFloat32;
    expVal.fltVal = adjustments.exposure;
    frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure, &expVal);
    VariantClear(&expVal);

    IBlackmagicRawClipProcessingAttributes* clipAttrs = nullptr;
    if (SUCCEEDED(clip->CloneClipProcessingAttributes(&clipAttrs)) && clipAttrs) {
        Variant hlVal; VariantInit(&hlVal);
        hlVal.vt = blackmagicRawVariantTypeU16;
        hlVal.uiVal = adjustments.highlightRecovery ? 1 : 0;
        clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeHighlightRecovery, &hlVal);
        VariantClear(&hlVal);

        // Embedded LUT — only for preview, never for export.
        // During batch/export decode, previewLUT will be false.
        if (adjustments.previewLUT) {
            Variant lutMode; VariantInit(&lutMode);
            lutMode.vt = blackmagicRawVariantTypeString;
            lutMode.bstrVal = CFSTR("Embedded");
            clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributePost3DLUTMode, &lutMode);
            VariantClear(&lutMode);
        }
        clipAttrs->Release();
    }
}

// ── Apply resolution scale to frame ────────────────────────────

static void ApplyScale(IBlackmagicRawFrame* frame, float scale) {
    if (scale > 0.0f && scale < 1.0f) {
        if (scale <= 0.125f)       frame->SetResolutionScale(blackmagicRawResolutionScaleEighth);
        else if (scale <= 0.25f)   frame->SetResolutionScale(blackmagicRawResolutionScaleQuarter);
        else if (scale <= 0.5f)    frame->SetResolutionScale(blackmagicRawResolutionScaleHalf);
    }
}

// ── Capture native metadata from frame processing attributes ───

static void CaptureNativeFromFrameAttrs(BrawDecoder::Impl* impl,
                                         IBlackmagicRawFrameProcessingAttributes* attrs) {
    if (impl->nativeCaptured || !attrs) return;
    Variant natISO, natTemp, natTint, natExp;
    VariantInit(&natISO); VariantInit(&natTemp); VariantInit(&natTint); VariantInit(&natExp);
    attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeISO, &natISO);
    attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, &natTemp);
    attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint, &natTint);
    attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure, &natExp);
    impl->nativeISO = natISO.uintVal;
    impl->nativeColorTemp = natTemp.uintVal;
    impl->nativeTint = natTint.iVal;
    impl->nativeExposure = natExp.fltVal;
    impl->nativeCaptured = true;
    VariantClear(&natISO); VariantClear(&natTemp); VariantClear(&natTint); VariantClear(&natExp);
}

// ── SDK Callback ───────────────────────────────────────────────

class BrawDecoderCallback : public IBlackmagicRawCallback {
public:
    BrawDecoder::Impl* impl = nullptr;

    void ReadComplete(IBlackmagicRawJob* readJob, HRESULT, IBlackmagicRawFrame* frame) override {
        if (!frame) return;

        // Check if this is a batch job (has user data) or single-frame
        BatchFrameInfo* finfo = nullptr;
        void* ud = nullptr;
        if (readJob) readJob->GetUserData(&ud);
        finfo = static_cast<BatchFrameInfo*>(ud);

        if (finfo) {
            // ── Batch decode path ──
            ApplyScale(frame, finfo->scale);

            IBlackmagicRawFrameProcessingAttributes* frameAttrs = nullptr;
            frame->CloneFrameProcessingAttributes(&frameAttrs);

            if (finfo->frameIndex == 0 && frameAttrs) {
                CaptureNativeFromFrameAttrs(impl, frameAttrs);
            }

            if (frameAttrs) {
                Variant v; VariantInit(&v);
                v.vt = blackmagicRawVariantTypeU32;
                v.uintVal = finfo->adjustments.iso > 0 ? finfo->adjustments.iso : impl->nativeISO;
                frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeISO, &v); VariantClear(&v);
                VariantInit(&v); v.vt = blackmagicRawVariantTypeU32;
                v.uintVal = finfo->adjustments.colorTemp > 0 ? finfo->adjustments.colorTemp : impl->nativeColorTemp;
                frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, &v); VariantClear(&v);
                VariantInit(&v); v.vt = blackmagicRawVariantTypeS16;
                v.iVal = finfo->adjustments.tint != 0 ? finfo->adjustments.tint : impl->nativeTint;
                frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint, &v); VariantClear(&v);
                VariantInit(&v); v.vt = blackmagicRawVariantTypeFloat32;
                v.fltVal = finfo->adjustments.exposure;
                frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure, &v); VariantClear(&v);
            }

            IBlackmagicRawClipProcessingAttributes* clipAttrs = nullptr;
            impl->clip->CloneClipProcessingAttributes(&clipAttrs);
            if (clipAttrs) {
                Variant v; VariantInit(&v); v.vt = blackmagicRawVariantTypeU16;
                v.uiVal = finfo->adjustments.highlightRecovery ? 1 : 0;
                clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeHighlightRecovery, &v); VariantClear(&v);
                if (finfo->adjustments.previewLUT) {
                    VariantInit(&v); v.vt = blackmagicRawVariantTypeString; v.bstrVal = CFSTR("Embedded");
                    clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributePost3DLUTMode, &v); VariantClear(&v);
                }
            }

            frame->SetResourceFormat(impl->resourceFormat);
            IBlackmagicRawJob* processJob = nullptr;
            frame->CreateJobDecodeAndProcessFrame(clipAttrs, frameAttrs, &processJob);
            if (processJob) {
                processJob->SetUserData(finfo);
                processJob->Submit();
            } else {
                delete finfo;
            }

            if (clipAttrs) clipAttrs->Release();
            if (frameAttrs) frameAttrs->Release();
            if (readJob) readJob->Release();
            return;
        }

        // ── Single-frame decode path ──
        BrawDecoder::Impl::PendingRequest& req = impl->pending;

        ApplyScale(frame, req.scale);

        IBlackmagicRawFrameProcessingAttributes* frameAttrs = nullptr;
        frame->CloneFrameProcessingAttributes(&frameAttrs);

        // Capture native settings on first decode
        CaptureNativeFromFrameAttrs(impl, frameAttrs);

        // Apply frame-level adjustments (ISO, WB, tint, exposure)
        if (frameAttrs) {
            Variant v; VariantInit(&v);
            v.vt = blackmagicRawVariantTypeU32;
            v.uintVal = req.adjustments.iso > 0 ? req.adjustments.iso : impl->nativeISO;
            frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeISO, &v); VariantClear(&v);
            VariantInit(&v); v.vt = blackmagicRawVariantTypeU32;
            v.uintVal = req.adjustments.colorTemp > 0 ? req.adjustments.colorTemp : impl->nativeColorTemp;
            frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, &v); VariantClear(&v);
            VariantInit(&v); v.vt = blackmagicRawVariantTypeS16;
            v.iVal = req.adjustments.tint != 0 ? req.adjustments.tint : impl->nativeTint;
            frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint, &v); VariantClear(&v);
            VariantInit(&v); v.vt = blackmagicRawVariantTypeFloat32;
            v.fltVal = req.adjustments.exposure;
            frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure, &v); VariantClear(&v);
        }

        // Apply clip-level adjustments (highlight recovery, LUT) and pass to job
        IBlackmagicRawClipProcessingAttributes* clipAttrs = nullptr;
        impl->clip->CloneClipProcessingAttributes(&clipAttrs);
        if (clipAttrs) {
            Variant v; VariantInit(&v); v.vt = blackmagicRawVariantTypeU16;
            v.uiVal = req.adjustments.highlightRecovery ? 1 : 0;
            clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeHighlightRecovery, &v); VariantClear(&v);
            if (req.adjustments.previewLUT) {
                VariantInit(&v); v.vt = blackmagicRawVariantTypeString; v.bstrVal = CFSTR("Embedded");
                clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributePost3DLUTMode, &v); VariantClear(&v);
            }
        }

        frame->SetResourceFormat(blackmagicRawResourceFormatBGRAU8);
        IBlackmagicRawJob* processJob = nullptr;
        frame->CreateJobDecodeAndProcessFrame(clipAttrs, frameAttrs, &processJob);
        if (processJob) processJob->Submit();

        if (clipAttrs) clipAttrs->Release();
        if (frameAttrs) frameAttrs->Release();
        if (readJob) readJob->Release();
    }

    void DecodeComplete(IBlackmagicRawJob*, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob*, float) override {}
    void TrimComplete(IBlackmagicRawJob*, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void* userData, HRESULT result) override {
        BrawDecoder::Impl* pImpl = static_cast<BrawDecoder::Impl*>(userData);
        if (pImpl) {
            std::lock_guard<std::mutex> lock(pImpl->pipelineMutex);
            pImpl->pipelineReady = true;
            pImpl->pipelineCV.notify_one();
        }
    }

    void ProcessComplete(IBlackmagicRawJob* job, HRESULT result,
                         IBlackmagicRawProcessedImage* processedImage) override {
        if (!job) return;

        BatchFrameInfo* finfo = nullptr;
        void* ud = nullptr;
        job->GetUserData(&ud);
        finfo = static_cast<BatchFrameInfo*>(ud);

        if (finfo) {
            // ── Batch decode path ──
            BatchContext* ctx = finfo->ctx;
            int slotIdx = finfo->slotIndex;

            if (SUCCEEDED(result) && processedImage && slotIdx >= 0
                && slotIdx < (int)ctx->slots.size()) {
                uint32_t pw = 0, ph = 0;
                processedImage->GetWidth(&pw);
                processedImage->GetHeight(&ph);

                void* resource = nullptr;
                processedImage->GetResource(&resource);

                uint32_t sizeBytes = 0;
                processedImage->GetResourceSizeBytes(&sizeBytes);

                if (resource && sizeBytes > 0) {
                    BatchSlot& slot = ctx->slots[slotIdx];
                    slot.width = pw;
                    slot.height = ph;
                    slot.bytesPerRow = sizeBytes / ph;
                    slot.pixels.resize(sizeBytes);
                    memcpy(slot.pixels.data(), resource, sizeBytes);
                    slot.frameIndex = finfo->frameIndex;
                    slot.ready = true;
                } else {
                    ctx->done = true;
                }
            } else {
                ctx->done = true;
            }

            delete finfo;
            job->Release();

            // Notify consumer that a slot is ready
            ctx->cv.notify_one();
            return;
        }

        // ── Single-frame decode path ──
        if (SUCCEEDED(result) && processedImage) {
            uint32_t pw = 0, ph = 0;
            processedImage->GetWidth(&pw);
            processedImage->GetHeight(&ph);

            void* resource = nullptr;
            processedImage->GetResource(&resource);

            uint32_t sizeBytes = 0;
            processedImage->GetResourceSizeBytes(&sizeBytes);

            if (resource && sizeBytes > 0) {
                impl->pending.pixels.assign((uint8_t*)resource, (uint8_t*)resource + sizeBytes);
                impl->pending.resultWidth = pw;
                impl->pending.resultHeight = ph;
                impl->pending.resultBytesPerRow = sizeBytes / ph;
                impl->frameReady = true;
            }
        }

        impl->callbackInvoked = true;
        impl->decodeCV.notify_one();
        job->Release();
    }

    HRESULT QueryInterface(REFIID, void**) override { return E_NOINTERFACE; }
    uint32_t AddRef() override { return 1; }
    uint32_t Release() override { return 1; }
};

// ── Helper: submit a single batch frame ────────────────────────

static bool SubmitBatchFrame(IBlackmagicRawClip* clip, BatchFrameInfo* finfo) {
    if (!clip) return false;
    IBlackmagicRawJob* readJob = nullptr;
    HRESULT hr = clip->CreateJobReadFrame(finfo->frameIndex, &readJob);
    if (SUCCEEDED(hr) && readJob) {
        readJob->SetUserData(finfo);
        readJob->Submit();
        return true;
    }
    return false;
}

// ── BrawDecoder implementation ─────────────────────────────────

BrawDecoder::BrawDecoder() : m_impl(std::make_unique<Impl>()) {}

BrawDecoder::~BrawDecoder() {
    Close();
}

bool BrawDecoder::OpenClip(const std::string& path) {
    Close();
    m_impl->filePath = path;

    CFStringRef libPath = CFSTR("/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries");
    m_impl->factory = CreateBlackmagicRawFactoryInstanceFromPath(libPath);
    if (!m_impl->factory) {
        std::cerr << "Failed to create BRAW factory" << std::endl;
        return false;
    }

    if (FAILED(m_impl->factory->CreateCodec(&m_impl->codec))) {
        std::cerr << "Failed to create codec" << std::endl;
        return false;
    }

    CFStringRef cfPath = Impl::ToCFString(path);
    HRESULT hr = m_impl->codec->OpenClip(cfPath, &m_impl->clip);
    CFRelease(cfPath);

    if (FAILED(hr) || !m_impl->clip) {
        std::cerr << "Failed to open clip: " << path << std::endl;
        return false;
    }

    m_impl->clip->GetWidth(&m_impl->width);
    m_impl->clip->GetHeight(&m_impl->height);
    m_impl->clip->GetFrameRate(&m_impl->frameRate);
    m_impl->clip->GetFrameCount(&m_impl->frameCount);

    CFStringRef camType = nullptr;
    m_impl->clip->GetCameraType(&camType);
    m_impl->cameraType = Impl::FromCFString(camType);
    if (camType) CFRelease(camType);

    // Set up callback
    m_impl->callback = new BrawDecoderCallback();
    m_impl->callback->impl = m_impl.get();
    m_impl->codec->SetCallback(m_impl->callback);

    // Prepare CPU pipeline for async job processing.
    // The userData (m_impl.get()) is passed to PreparePipelineComplete.
    m_impl->pipelineReady = false;
    HRESULT pipeHR = m_impl->codec->PreparePipeline(
        blackmagicRawPipelineCPU, nullptr, nullptr, m_impl.get());
    fprintf(stderr, "PreparePipeline returned 0x%lx\n", (long)pipeHR);
    if (SUCCEEDED(hr)) {
        std::unique_lock<std::mutex> lock(m_impl->pipelineMutex);
        m_impl->pipelineCV.wait_for(lock, std::chrono::seconds(5),
                                     [this] { return m_impl->pipelineReady; });
    }
    fprintf(stderr, "pipelineReady after prepare: %d\n", m_impl->pipelineReady);

    return true;
}

void BrawDecoder::SetOutputFormat(int format) {
    m_impl->resourceFormat = (format==1) ? blackmagicRawResourceFormatRGBU16 : blackmagicRawResourceFormatBGRAU8;
}

void BrawDecoder::Close() {
    if (m_impl->codec) {
        m_impl->codec->Release();
        m_impl->codec = nullptr;
    }
    if (m_impl->clip) {
        m_impl->clip->Release();
        m_impl->clip = nullptr;
    }
    if (m_impl->factory) {
        m_impl->factory->Release();
        m_impl->factory = nullptr;
    }
    m_impl->width = 0;
    m_impl->height = 0;
    if (m_impl->callback) {
        delete m_impl->callback;
        m_impl->callback = nullptr;
    }
    m_impl->nativeCaptured = false;
}

uint32_t BrawDecoder::GetWidth() const  { return m_impl->width; }
uint32_t BrawDecoder::GetHeight() const { return m_impl->height; }
float BrawDecoder::GetFrameRate() const { return m_impl->frameRate; }
uint64_t BrawDecoder::GetFrameCount() const { return m_impl->frameCount; }
std::string BrawDecoder::GetCameraType() const { return m_impl->cameraType; }

std::vector<uint32_t> BrawDecoder::GetISOList() {
    return {100, 125, 160, 200, 250, 320, 400, 500, 640,
            800, 1000, 1250, 1600, 2000, 2500, 3200, 4000,
            5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600};
}

void BrawDecoder::RequestFrame(uint64_t frameIndex,
                                const ClipAdjustments& adjustments,
                                FrameCallback callback,
                                float scale) {
    if (!m_impl->clip || !m_impl->codec) { fprintf(stderr, "RF: no clip/codec\n"); return; }

    m_impl->frameReady = false;
    m_impl->callbackInvoked = false;

    m_impl->pending = {};
    m_impl->pending.frameIndex = frameIndex;
    m_impl->pending.adjustments = adjustments;
    m_impl->pending.callback = callback;
    m_impl->pending.scale = scale;

    IBlackmagicRawJob* readJob = nullptr;
    HRESULT createHR = m_impl->clip->CreateJobReadFrame(frameIndex, &readJob);
    fprintf(stderr, "RF: CreateJobReadFrame returned 0x%lx, job=%p\n", (long)createHR, (void*)readJob);
    if (SUCCEEDED(createHR) && readJob) {
        HRESULT submitHR = readJob->Submit();
        fprintf(stderr, "RF: Submit returned 0x%lx\n", (long)submitHR);
    } else {
        fprintf(stderr, "RF: skipping submit\n");
        return;
    }

    // Wait for async job completion via SDK callbacks.
    // The CPU pipeline's worker threads process the job and fire callbacks.
    {
        std::unique_lock<std::mutex> lock(m_impl->decodeMutex);
        m_impl->decodeCV.wait_for(lock, std::chrono::seconds(30),
            [this] { return m_impl->callbackInvoked.load(); });
    }
    fprintf(stderr, "RF: callbackInvoked=%d frameReady=%d pixelCount=%zu\n",
            m_impl->callbackInvoked.load(), m_impl->frameReady.load(),
            m_impl->pending.pixels.size());

    if (m_impl->frameReady && callback && !m_impl->pending.pixels.empty()) {
        callback(m_impl->pending.pixels.data(),
                 m_impl->pending.resultWidth,
                 m_impl->pending.resultHeight,
                 m_impl->pending.resultBytesPerRow);
    }
}

void BrawDecoder::FlushJobs() {
    // Not needed for CPU decode path.
    // Jobs complete naturally; no GPU state to flush.
}

void BrawDecoder::CaptureNativeSettings() {
    if (!m_impl->clip || !m_impl->codec) return;
    if (m_impl->nativeCaptured) return;

    ClipAdjustments defaults = {};
    RequestFrame(0, defaults, [](const uint8_t*, int, int, int) {}, 1.0f);
}

std::vector<uint8_t> BrawDecoder::DecodeFrameSync(uint64_t frameIndex,
                                                    int* outWidth, int* outHeight,
                                                    int* outBytesPerRow,
                                                    const ClipAdjustments& adjustments,
                                                    float scale) {
    std::vector<uint8_t> result;
    if (!m_impl->clip || !m_impl->codec) return result;

    RequestFrame(frameIndex, adjustments, [&](const uint8_t* pixels, int w, int h, int bpr) {
        *outWidth = w;
        *outHeight = h;
        *outBytesPerRow = bpr;
        size_t size = (size_t)bpr * h;
        result.assign(pixels, pixels + size);
    }, scale);

    return result;
}

// ── Multi-core CPU batch decode ────────────────────────────────

void BrawDecoder::DecodeFramesCPUBatch(uint64_t startFrame, uint64_t endFrame,
                                        const ClipAdjustments& adjustments,
                                        FrameCallback callback,
                                        int concurrency) {
    if (!m_impl->clip || !m_impl->codec || startFrame >= endFrame) return;

    // Auto-detect concurrency
    if (concurrency <= 0) {
        int ncpus = (int)std::thread::hardware_concurrency();
        concurrency = (ncpus > 1) ? ncpus - 1 : 1;
        if (concurrency > 8) concurrency = 8;
    }

    uint64_t totalFrames = endFrame - startFrame;
    int slotCount = (int)std::min((uint64_t)concurrency, totalFrames);

    BatchContext ctx;
    ctx.startFrame = startFrame;
    ctx.endFrame = endFrame;
    ctx.nextSubmit = startFrame;
    ctx.nextDeliver = startFrame;
    ctx.concurrency = slotCount;
    ctx.callback = callback;
    ctx.slots.resize(slotCount);
    ctx.done = false;

    // Ensure native settings are captured (needed for adjustment application)
    if (!m_impl->nativeCaptured) {
        ClipAdjustments defaults = {};
        RequestFrame(0, defaults, [](const uint8_t*, int, int, int) {}, 1.0f);
    }

    // Submit initial batch
    for (int i = 0; i < slotCount && ctx.nextSubmit < endFrame; i++) {
        uint64_t frameIdx = ctx.nextSubmit;
        ctx.nextSubmit++;

        auto* finfo = new BatchFrameInfo();
        finfo->frameIndex = frameIdx;
        finfo->slotIndex = i;
        finfo->adjustments = adjustments;
        finfo->scale = 1.0f;
        finfo->ctx = &ctx;

        if (!SubmitBatchFrame(m_impl->clip, finfo)) {
            delete finfo;
        }

        // Track which frame this slot is processing
        ctx.slots[i].frameIndex = frameIdx;
    }

    // Track how many frames we've submitted total
    uint64_t totalSubmitted = endFrame - startFrame;
    uint64_t totalDelivered = 0;

    // Consumer loop: deliver frames in order
    int spinCount = 0;
    while (totalDelivered < totalSubmitted && !ctx.done) {
        // Check if the next expected frame is ready
        bool found = false;
        for (int i = 0; i < slotCount; i++) {
            BatchSlot& slot = ctx.slots[i];
            if (slot.ready && slot.frameIndex == ctx.nextDeliver) {
                // Deliver this frame
                if (callback) {
                    callback(slot.pixels.data(), slot.width,
                             slot.height, slot.bytesPerRow);
                }
                ctx.nextDeliver++;
                totalDelivered++;
                slot.ready = false;
                spinCount = 0;

                // Submit next frame in this slot
                uint64_t next = ctx.nextSubmit++;
                if (next < endFrame) {
                    auto* finfo = new BatchFrameInfo();
                    finfo->frameIndex = next;
                    finfo->slotIndex = i;
                    finfo->adjustments = adjustments;
                    finfo->scale = 1.0f;
                    finfo->ctx = &ctx;

                    if (!SubmitBatchFrame(m_impl->clip, finfo)) {
                        fprintf(stderr, "BATCH: submit failed at frame %llu\n",
                                (unsigned long long)next);
                        delete finfo;
                        ctx.done = true;
                    } else {
                        slot.frameIndex = next;
                    }
                }
                found = true;
                break;
            }
        }

        if (!found) {
            spinCount++;
            if (spinCount > 2000) { // ~10s with no progress
                // Check if any job is still in flight by scanning slots
                bool anyPending = false;
                for (int i = 0; i < slotCount; i++) {
                    if (ctx.slots[i].frameIndex != UINT64_MAX && !ctx.slots[i].ready) {
                        anyPending = true; break;
                    }
                }
                fprintf(stderr, "BATCH: stalled for %d loops, pending=%d delivered=%llu/%llu done=%d\n",
                        spinCount, anyPending ? 1 : 0,
                        (unsigned long long)totalDelivered,
                        (unsigned long long)totalSubmitted, ctx.done ? 1 : 0);
                if (!anyPending) {
                    fprintf(stderr, "BATCH: no pending jobs, exiting\n");
                    ctx.done = true;
                }
                spinCount = 0;
            }
            // Nothing ready yet — brief wait
            std::unique_lock<std::mutex> lock(ctx.mtx);
            ctx.cv.wait_for(lock, std::chrono::milliseconds(5));
        }
    }
    
    fprintf(stderr, "BATCH: done delivered=%llu/%llu done=%d\n",
            (unsigned long long)totalDelivered,
            (unsigned long long)totalSubmitted, ctx.done ? 1 : 0);
}

// ── Metadata ───────────────────────────────────────────────────

uint32_t BrawDecoder::GetNativeISO() const { return m_impl->nativeISO; }
uint32_t BrawDecoder::GetNativeColorTemp() const { return m_impl->nativeColorTemp; }
int16_t  BrawDecoder::GetNativeTint() const { return m_impl->nativeTint; }
float    BrawDecoder::GetNativeExposure() const { return m_impl->nativeExposure; }

std::string BrawDecoder::GetClipGamma() const {
    if (!m_impl->clip) return "";
    IBlackmagicRawClipProcessingAttributes* attrs = nullptr;
    m_impl->clip->CloneClipProcessingAttributes(&attrs);
    if (!attrs) return "";
    Variant v; VariantInit(&v);
    std::string result;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeGamma, &v))
        && v.vt == blackmagicRawVariantTypeString && v.bstrVal) {
        result = Impl::FromCFString(v.bstrVal);
    }
    VariantClear(&v); attrs->Release();
    return result;
}

std::string BrawDecoder::GetClipGamut() const {
    if (!m_impl->clip) return "";
    IBlackmagicRawClipProcessingAttributes* attrs = nullptr;
    m_impl->clip->CloneClipProcessingAttributes(&attrs);
    if (!attrs) return "";
    Variant v; VariantInit(&v);
    std::string result;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeGamut, &v))
        && v.vt == blackmagicRawVariantTypeString && v.bstrVal) {
        result = Impl::FromCFString(v.bstrVal);
    }
    VariantClear(&v); attrs->Release();
    return result;
}

std::map<std::string, std::string> BrawDecoder::GetFreeFormMetadata() const {
    std::map<std::string, std::string> result;
    if (!m_impl->clip) return result;
    IBlackmagicRawMetadataIterator* it = nullptr;
    if (FAILED(m_impl->clip->GetMetadataIterator(&it)) || !it) return result;
    while (it->Next() == S_OK) {
        CFStringRef key = nullptr; Variant val; VariantInit(&val);
        if (SUCCEEDED(it->GetKey(&key))) {
            if (SUCCEEDED(it->GetData(&val))) {
                std::string k = Impl::FromCFString(key);
                std::string v;
                switch (val.vt) {
                    case blackmagicRawVariantTypeString: v = val.bstrVal ? Impl::FromCFString(val.bstrVal) : ""; break;
                    case blackmagicRawVariantTypeU32:  v = std::to_string(val.uintVal); break;
                    case blackmagicRawVariantTypeS16:  v = std::to_string(val.iVal); break;
                    case blackmagicRawVariantTypeFloat32: v = std::to_string(val.fltVal); break;
                    case blackmagicRawVariantTypeU16:  v = std::to_string(val.uiVal); break;
                    case blackmagicRawVariantTypeFloat64: v = std::to_string(val.dblVal); break;
                    case blackmagicRawVariantTypeS32:  v = std::to_string(val.intVal); break;
                    default: v = "(unknown type)"; break;
                }
                if (!k.empty() && !v.empty()) result[k] = v;
                VariantClear(&val);
            }
            CFRelease(key);
        }
    }
    it->Release();
    return result;
}

uint16_t BrawDecoder::GetColorScienceGen() const {
    if (!m_impl->clip) return 0;
    IBlackmagicRawClipProcessingAttributes* attrs = nullptr;
    m_impl->clip->CloneClipProcessingAttributes(&attrs);
    if (!attrs) return 0;
    Variant v; VariantInit(&v);
    uint16_t result = 0;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeColorScienceGen, &v))
        && v.vt == blackmagicRawVariantTypeU16) {
        result = v.uiVal;
    }
    VariantClear(&v); attrs->Release();
    return result;
}

// ── Audio ──────────────────────────────────────────────────────

bool BrawDecoder::GetAudioFormat(uint32_t* outSampleRate, uint32_t* outChannels) {
    *outSampleRate = 48000; *outChannels = 2;
    if (!m_impl->clip) return false;
    IBlackmagicRawClipAudio* audio = nullptr;
    if (SUCCEEDED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipAudio, (void**)&audio)) && audio) {
        audio->GetAudioSampleRate(outSampleRate);
        audio->GetAudioChannelCount(outChannels);
        audio->Release();
    }
    return *outSampleRate > 0 && *outChannels > 0;
}

// ── Gyro Data ──────────────────────────────────────────────────

BrawDecoder::GyroData BrawDecoder::ExtractGyroData() {
    GyroData result;
    if (!m_impl->clip) return result;

    IBlackmagicRawClipGyroscopeMotion* gyro = nullptr;
    if (SUCCEEDED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipGyroscopeMotion, (void**)&gyro)) && gyro) {
        float sampleRate = 0; uint32_t sampleCount = 0;
        gyro->GetSampleRate(&sampleRate);
        gyro->GetSampleCount(&sampleCount);
        if (sampleCount > 0) {
            result.gyroscope.resize(sampleCount);
            float* buf = new float[sampleCount * 3];
            uint32_t readCount = 0;
            if (SUCCEEDED(gyro->GetSampleRange(0, sampleCount, buf, &readCount)) && readCount > 0) {
                for (uint32_t i = 0; i < readCount; i++) {
                    float t = (float)i / sampleRate;
                    result.gyroscope[i] = {t, buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2]};
                }
                result.gyroSampleRate = sampleRate; result.hasGyro = true;
                result.gyroscope.resize(readCount);
            }
            delete[] buf;
        }
        gyro->Release();
    }

    IBlackmagicRawClipAccelerometerMotion* accel = nullptr;
    if (SUCCEEDED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipAccelerometerMotion, (void**)&accel)) && accel) {
        float sampleRate = 0; uint32_t sampleCount = 0;
        accel->GetSampleRate(&sampleRate);
        accel->GetSampleCount(&sampleCount);
        if (sampleCount > 0) {
            result.accelerometer.resize(sampleCount);
            float* buf = new float[sampleCount * 3];
            uint32_t readCount = 0;
            if (SUCCEEDED(accel->GetSampleRange(0, sampleCount, buf, &readCount)) && readCount > 0) {
                for (uint32_t i = 0; i < readCount; i++) {
                    float t = (float)i / sampleRate;
                    result.accelerometer[i] = {t, buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2]};
                }
                result.accelSampleRate = sampleRate; result.hasAccel = true;
                result.accelerometer.resize(readCount);
            }
            delete[] buf;
        }
        accel->Release();
    }
    return result;
}

// ── Audio Extraction ───────────────────────────────────────────

float* BrawDecoder::ExtractAudio(uint32_t* outSampleRate, uint32_t* outChannels,
                                   uint64_t* outSampleCount) {
    *outSampleRate = 0; *outChannels = 0; *outSampleCount = 0;
    if (!m_impl->clip || m_impl->filePath.empty()) return nullptr;

    GetAudioFormat(outSampleRate, outChannels);

    const char* ffmpeg = nullptr;
    const char* paths[] = {"/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg","/usr/bin/ffmpeg"};
    for (int i = 0; i < 3; i++) { if (access(paths[i], X_OK) == 0) { ffmpeg = paths[i]; break; } }
    if (!ffmpeg) return nullptr;

    char tmp[512];
    snprintf(tmp, sizeof(tmp), "/tmp/braw_audio_%d_%d.raw", getpid(), rand());
    char cmd[4096];
    snprintf(cmd, sizeof(cmd),
             "(%s -y -i \"%s\" -vn -c:a pcm_f32le -f f32le \"%s\" 2>/dev/null) & PID=$!; "
             "(sleep 60; kill $PID 2>/dev/null) & WATCH=$!; wait $PID 2>/dev/null; kill $WATCH 2>/dev/null",
             ffmpeg, m_impl->filePath.c_str(), tmp);
    if (system(cmd) != 0) return nullptr;

    FILE* fp = fopen(tmp, "rb");
    if (!fp) return nullptr;
    fseek(fp, 0, SEEK_END); long flen = ftell(fp); fseek(fp, 0, SEEK_SET);
    if (flen <= 0) { fclose(fp); unlink(tmp); return nullptr; }

    float* samples = (float*)malloc((size_t)flen);
    size_t got = samples ? fread(samples, 1, (size_t)flen, fp) : 0;
    fclose(fp); unlink(tmp);
    if (!samples || got == 0) { free(samples); return nullptr; }

    uint64_t totalFloats = got / sizeof(float);
    *outSampleCount = totalFloats / *outChannels;
    return samples;
}
