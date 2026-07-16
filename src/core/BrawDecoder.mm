#include "core/BrawDecoder.h"
#include "BlackmagicRawAPI.h"
#include "BlackmagicRawAPIDispatch.cpp"
#import <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>
#include <iostream>
#include <mutex>
#include <condition_variable>
#include <atomic>

class BrawDecoderCallback;

struct DecodedFrame {
    int width = 0;
    int height = 0;
    int bytesPerRow = 0;
    std::vector<uint8_t> pixels;
};

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

    id<MTLDevice>       metalDevice = nil;
    id<MTLCommandQueue> metalQueue  = nil;
    bool pipelineReady = false;

    struct PendingRequest {
        uint64_t frameIndex;
        ClipAdjustments adjustments;
        BrawDecoder::FrameCallback callback;
        float scale = 1.0f;
    };
    PendingRequest pending;

    std::mutex decodeMutex;
    std::condition_variable decodeCV;
    std::atomic<bool> frameReady{false};
    void* readyBuffer = nullptr;
    int readyWidth = 0;
    int readyHeight = 0;
    int readyBytesPerRow = 0;

    std::atomic<bool> callbackInvoked{false};

    id<MTLBuffer> stagingBuffer = nil;

    BrawDecoderCallback* callback = nullptr;
    std::mutex callbackMutex;

    bool nativeCaptured = false;
    uint32_t nativeISO = 800;
    uint32_t nativeColorTemp = 5600;
    int16_t nativeTint = 0;
    float nativeExposure = 0.0f;

    // Batch decode support (parallel CPU decode across cores)
    std::vector<DecodedFrame> batchResults;
    std::atomic<int> batchPending{0};

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

class BrawDecoderCallback : public IBlackmagicRawCallback {
public:
    BrawDecoder::Impl* impl = nullptr;

    void ReadComplete(IBlackmagicRawJob*, HRESULT, IBlackmagicRawFrame* frame) override {
        if (!frame) return;

        BrawDecoder::Impl::PendingRequest req = impl->pending;

        // Apply resolution scale
        if (req.scale > 0.0f && req.scale < 1.0f) {
            if (req.scale <= 0.125f)       frame->SetResolutionScale(blackmagicRawResolutionScaleEighth);
            else if (req.scale <= 0.25f)   frame->SetResolutionScale(blackmagicRawResolutionScaleQuarter);
            else if (req.scale <= 0.5f)    frame->SetResolutionScale(blackmagicRawResolutionScaleHalf);
        }

        IBlackmagicRawFrameProcessingAttributes* frameAttrs = nullptr;
        frame->CloneFrameProcessingAttributes(&frameAttrs);

        // Capture native camera settings on first decode
        if (!impl->nativeCaptured && frameAttrs) {
            Variant natISO, natTemp, natTint, natExp;
            VariantInit(&natISO); VariantInit(&natTemp); VariantInit(&natTint); VariantInit(&natExp);
            frameAttrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeISO, &natISO);
            frameAttrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, &natTemp);
            frameAttrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint, &natTint);
            frameAttrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure, &natExp);
            impl->nativeISO = natISO.uintVal;
            impl->nativeColorTemp = natTemp.uintVal;
            impl->nativeTint = natTint.iVal;
            impl->nativeExposure = natExp.fltVal;
            impl->nativeCaptured = true;
            VariantClear(&natISO); VariantClear(&natTemp); VariantClear(&natTint); VariantClear(&natExp);
        }

        // Apply user adjustments (if non-zero, override native; otherwise keep native)
        {
            Variant isoVal;
            VariantInit(&isoVal);
            isoVal.vt = blackmagicRawVariantTypeU32;
            isoVal.uintVal = req.adjustments.iso > 0 ? req.adjustments.iso : impl->nativeISO;
            frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeISO, &isoVal);
            VariantClear(&isoVal);
        }
        {
            Variant kelvinVal;
            VariantInit(&kelvinVal);
            kelvinVal.vt = blackmagicRawVariantTypeU32;
            kelvinVal.uintVal = req.adjustments.colorTemp > 0 ? req.adjustments.colorTemp : impl->nativeColorTemp;
            frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, &kelvinVal);
            VariantClear(&kelvinVal);
        }
        {
            Variant tintVal;
            VariantInit(&tintVal);
            tintVal.vt = blackmagicRawVariantTypeS16;
            tintVal.iVal = req.adjustments.tint != 0 ? req.adjustments.tint : impl->nativeTint;
            frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint, &tintVal);
            VariantClear(&tintVal);
        }
        {
            Variant expVal;
            VariantInit(&expVal);
            expVal.vt = blackmagicRawVariantTypeFloat32;
            expVal.fltVal = req.adjustments.exposure;
            frameAttrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure, &expVal);
            VariantClear(&expVal);
        }

        IBlackmagicRawClipProcessingAttributes* clipAttrs = nullptr;
        impl->clip->CloneClipProcessingAttributes(&clipAttrs);

        {
            Variant hlVal;
            VariantInit(&hlVal);
            hlVal.vt = blackmagicRawVariantTypeU16;
            hlVal.uiVal = req.adjustments.highlightRecovery ? 1 : 0;
            clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeHighlightRecovery, &hlVal);
            VariantClear(&hlVal);
        }

        if (req.adjustments.bakeLUT || req.adjustments.previewLUT) {
            Variant lutMode;
            VariantInit(&lutMode);
            lutMode.vt = blackmagicRawVariantTypeString;
            lutMode.bstrVal = CFSTR("Embedded");
            clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributePost3DLUTMode, &lutMode);
            VariantClear(&lutMode);
        }

        frame->SetResourceFormat(blackmagicRawResourceFormatBGRAU8);
        IBlackmagicRawJob* job = nullptr;
        frame->CreateJobDecodeAndProcessFrame(clipAttrs, frameAttrs, &job);
        if (job) job->Submit();

        clipAttrs->Release();
        frameAttrs->Release();
    }

    void DecodeComplete(IBlackmagicRawJob*, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob*, float) override {}
    void TrimComplete(IBlackmagicRawJob*, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void*, HRESULT) override {}

    void ProcessComplete(IBlackmagicRawJob* job, HRESULT result,
                         IBlackmagicRawProcessedImage* processedImage) override {
        if (result != 0 || !processedImage) {
            impl->callbackInvoked = true;
            impl->decodeCV.notify_one();
            return;
        }

        uint32_t pw = 0, ph = 0;
        processedImage->GetWidth(&pw);
        processedImage->GetHeight(&ph);

        BlackmagicRawResourceType resType;
        processedImage->GetResourceType(&resType);

        void* resource = nullptr;
        processedImage->GetResource(&resource);

        uint32_t sizeBytes = 0;
        processedImage->GetResourceSizeBytes(&sizeBytes);

        impl->readyWidth  = pw;
        impl->readyHeight = ph;
        impl->readyBytesPerRow = sizeBytes / ph;

        // Copy pixel data from SDK's buffer to our own staging buffer immediately
        impl->stagingBuffer = nil;
        if (resource && sizeBytes > 0 && impl->metalDevice) {
            if (resType == 'metb') {
                // Metal buffer: blit from GPU to shared memory
                id<MTLBuffer> srcBuf = (__bridge id<MTLBuffer>)resource;
                id<MTLBuffer> staging = [impl->metalDevice newBufferWithLength:sizeBytes
                                                                       options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cmdBuf = [impl->metalQueue commandBuffer];
                id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
                [blit copyFromBuffer:srcBuf sourceOffset:0
                            toBuffer:staging destinationOffset:0 size:sizeBytes];
                [blit endEncoding];
                [cmdBuf commit];
                [cmdBuf waitUntilCompleted];
                impl->stagingBuffer = staging;
            } else {
                // CPU buffer: copy directly to a shared Metal buffer
                id<MTLBuffer> staging = [impl->metalDevice newBufferWithBytes:resource
                                                                       length:sizeBytes
                                                                      options:MTLResourceStorageModeShared];
                impl->stagingBuffer = staging;
            }
        }

        impl->frameReady  = true;
        impl->callbackInvoked = true;
        impl->decodeCV.notify_one();
    }

    HRESULT QueryInterface(REFIID, void**) override { return E_NOINTERFACE; }
    uint32_t AddRef() override { return 1; }
    uint32_t Release() override { return 1; }
};

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

    // Callback is always needed (for async job completion)
    m_impl->callback = new BrawDecoderCallback();
    m_impl->callback->impl = m_impl.get();
    m_impl->codec->SetCallback(m_impl->callback);

    // Metal pipeline (required for GPU decode; CPU decode works through this too)
    m_impl->metalDevice = MTLCreateSystemDefaultDevice();
    m_impl->metalQueue  = [m_impl->metalDevice newCommandQueue];
    m_impl->codec->PreparePipeline(
        blackmagicRawPipelineMetal,
        (__bridge void*)m_impl->metalDevice,
        (__bridge void*)m_impl->metalQueue,
        nullptr);

    return true;
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
    m_impl->metalQueue = nil;
    m_impl->metalDevice = nil;
    m_impl->width = 0;
    m_impl->height = 0;
    if (m_impl->callback) {
        delete m_impl->callback;
        m_impl->callback = nullptr;
    }
    m_impl->stagingBuffer = nil;
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
    if (!m_impl->clip || !m_impl->codec) return;

    m_impl->frameReady = false;
    m_impl->callbackInvoked = false;
    m_impl->readyBuffer = nullptr;

    m_impl->pending = {frameIndex, adjustments, callback, scale};

    IBlackmagicRawJob* readJob = nullptr;
    m_impl->clip->CreateJobReadFrame(frameIndex, &readJob);
    if (readJob) {
        readJob->Submit();
    }

    {
        std::unique_lock<std::mutex> lock(m_impl->decodeMutex);
        m_impl->decodeCV.wait(lock, [this] { return m_impl->callbackInvoked.load(); });
    }

    if (m_impl->frameReady && callback) {
        void* bufPtr = (__bridge void*)m_impl->stagingBuffer;
        callback(bufPtr, m_impl->readyWidth, m_impl->readyHeight,
                 m_impl->readyBytesPerRow);
    }

    m_impl->stagingBuffer = nil;
    m_impl->readyBuffer = nullptr;
}

void BrawDecoder::FlushJobs() {
    // FlushJobs hangs in some SDK versions; skip it.
    // Jobs are completed synchronously via RequestFrame's CV wait.
}

void BrawDecoder::CaptureNativeSettings() {
    if (!m_impl->clip || !m_impl->codec) return;
    if (m_impl->nativeCaptured) return;
    
    ClipAdjustments defaults = {};
    RequestFrame(0, defaults, [](void*, int, int, int) {}, 1.0f);
}

std::vector<uint8_t> BrawDecoder::DecodeFrameSync(uint64_t frameIndex,
                                                    int* outWidth, int* outHeight,
                                                    int* outBytesPerRow,
                                                    const ClipAdjustments& adjustments,
                                                    float scale) {
    std::vector<uint8_t> result;
    if (!m_impl->clip || !m_impl->codec) return result;

    std::atomic<bool> done{false};

    RequestFrame(frameIndex, adjustments, [&](void* bufPtr, int w, int h, int bytesPerRow) {
        *outWidth = w;
        *outHeight = h;
        *outBytesPerRow = bytesPerRow;

        id<MTLBuffer> buf = (__bridge id<MTLBuffer>)bufPtr;
        size_t size = bytesPerRow * h;
        result.resize(size);
        memcpy(result.data(), [buf contents], size);
        done = true;
    }, scale);

    return result;
}

void* BrawDecoder::DecodeFrameGPU(uint64_t frameIndex,
                                    int* outWidth, int* outHeight,
                                    int* outBytesPerRow,
                                    const ClipAdjustments& adjustments) {
    if (!m_impl->clip || !m_impl->codec) return nullptr;

    void* retainedBuf = nullptr;

    RequestFrame(frameIndex, adjustments, [&retainedBuf, outWidth, outHeight, outBytesPerRow](void* bufPtr, int w, int h, int bytesPerRow) {
        *outWidth = w;
        *outHeight = h;
        *outBytesPerRow = bytesPerRow;
        id<MTLBuffer> buf = (__bridge id<MTLBuffer>)bufPtr;
        retainedBuf = (__bridge_retained void*)buf;
    }, 1.0f);

    return retainedBuf;
}

void* BrawDecoder::DecodeFrameGPUScaled(uint64_t frameIndex,
                                         int* outWidth, int* outHeight,
                                         int* outBytesPerRow,
                                         const ClipAdjustments& adjustments,
                                         float scale) {
    if (!m_impl->clip || !m_impl->codec) return nullptr;

    void* retainedBuf = nullptr;

    RequestFrame(frameIndex, adjustments, [&retainedBuf, outWidth, outHeight, outBytesPerRow](void* bufPtr, int w, int h, int bytesPerRow) {
        *outWidth = w;
        *outHeight = h;
        *outBytesPerRow = bytesPerRow;
        id<MTLBuffer> buf = (__bridge id<MTLBuffer>)bufPtr;
        retainedBuf = (__bridge_retained void*)buf;
    }, scale);

    return retainedBuf;
}

uint32_t BrawDecoder::GetNativeISO() const { return m_impl->nativeISO; }
uint32_t BrawDecoder::GetNativeColorTemp() const { return m_impl->nativeColorTemp; }
int16_t  BrawDecoder::GetNativeTint() const { return m_impl->nativeTint; }
float    BrawDecoder::GetNativeExposure() const { return m_impl->nativeExposure; }

std::string BrawDecoder::GetClipGamma() const {
    if (!m_impl->clip) return "";
    IBlackmagicRawClipProcessingAttributes* attrs = nullptr;
    m_impl->clip->CloneClipProcessingAttributes(&attrs);
    if (!attrs) return "";
    Variant v;
    VariantInit(&v);
    std::string result;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeGamma, &v))
        && v.vt == blackmagicRawVariantTypeString && v.bstrVal) {
        result = Impl::FromCFString(v.bstrVal);
    }
    VariantClear(&v);
    attrs->Release();
    return result;
}

std::string BrawDecoder::GetClipGamut() const {
    if (!m_impl->clip) return "";
    IBlackmagicRawClipProcessingAttributes* attrs = nullptr;
    m_impl->clip->CloneClipProcessingAttributes(&attrs);
    if (!attrs) return "";
    Variant v;
    VariantInit(&v);
    std::string result;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeGamut, &v))
        && v.vt == blackmagicRawVariantTypeString && v.bstrVal) {
        result = Impl::FromCFString(v.bstrVal);
    }
    VariantClear(&v);
    attrs->Release();
    return result;
}

std::map<std::string, std::string> BrawDecoder::GetFreeFormMetadata() const {
    std::map<std::string, std::string> result;
    if (!m_impl->clip) return result;
    IBlackmagicRawMetadataIterator* it = nullptr;
    if (FAILED(m_impl->clip->GetMetadataIterator(&it)) || !it) return result;
    while (it->Next() == S_OK) {
        CFStringRef key = nullptr;
        Variant val;
        VariantInit(&val);
        if (SUCCEEDED(it->GetKey(&key))) {
            if (SUCCEEDED(it->GetData(&val))) {
                std::string k = Impl::FromCFString(key);
                std::string v;
                switch (val.vt) {
                    case blackmagicRawVariantTypeString:
                        v = val.bstrVal ? Impl::FromCFString(val.bstrVal) : "";
                        break;
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
    Variant v;
    VariantInit(&v);
    uint16_t result = 0;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeColorScienceGen, &v))
        && v.vt == blackmagicRawVariantTypeU16) {
        result = v.uiVal;
    }
    VariantClear(&v);
    attrs->Release();
    return result;
}

float* BrawDecoder::ExtractAudio(uint32_t* outSampleRate, uint32_t* outChannels,
                                   uint64_t* outSampleCount) {
    // BRAW SDK's GetAudioSamples returns garbage on this SDK version.
    // Use ffmpeg to extract audio from the source file.
    *outSampleRate = 0; *outChannels = 0; *outSampleCount = 0;
    if (!m_impl->clip || m_impl->filePath.empty()) return nullptr;

    // Get format metadata from SDK
    IBlackmagicRawClipAudio* audio = nullptr;
    if (SUCCEEDED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipAudio, (void**)&audio)) && audio) {
        audio->GetAudioSampleRate(outSampleRate);
        audio->GetAudioChannelCount(outChannels);
        audio->Release();
    }
    if (*outSampleRate == 0) *outSampleRate = 48000;
    if (*outChannels == 0) *outChannels = 2;

    // Find ffmpeg
    const char* ffmpeg = nullptr;
    const char* paths[] = {"/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg","/usr/bin/ffmpeg"};
    for (int i = 0; i < 3; i++) { if (access(paths[i], X_OK) == 0) { ffmpeg = paths[i]; break; } }
    if (!ffmpeg) return nullptr;

    // Extract audio to temp file
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "/tmp/braw_audio_%d_%d.raw", getpid(), rand());
    char cmd[4096];
    snprintf(cmd, sizeof(cmd), "%s -y -i \"%s\" -vn -c:a pcm_f32le -f f32le \"%s\" 2>/dev/null",
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
