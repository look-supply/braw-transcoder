#include "worker/SDKDecoder.h"
#include "BlackmagicRawAPI.h"
#include "BlackmagicRawAPIDispatch.cpp"
#import <Metal/Metal.h>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <unistd.h>

struct SDKDecoder::Impl {
    IBlackmagicRawFactory* factory=nullptr;
    IBlackmagicRaw* codec=nullptr;
    IBlackmagicRawClip* clip=nullptr;
    IBlackmagicRawCallback* callback=nullptr;
    id<MTLDevice> device=nil;
    id<MTLCommandQueue> queue=nil;
    std::mutex mutex;
    std::condition_variable cv;
    bool prepared=false, prepareOK=false, completed=false, frameOK=false;
    bool nativeCaptured=false;
    uint32_t width=0,height=0,nativeISO=800,nativeColorTemp=5600;
    uint64_t frameCount=0;
    float frameRate=0,nativeExposure=0;
    int16_t nativeTint=0;
    int format=0;
    ClipAdjustments adjustments;
    float scale=1;
    Frame frame;
    std::string cameraType, version;
    static std::string FromCFString(CFStringRef s) {
        if (!s) return {};
        CFIndex n=CFStringGetMaximumSizeForEncoding(CFStringGetLength(s),kCFStringEncodingUTF8)+1;
        std::string out(n,'\0');
        if(!CFStringGetCString(s,out.data(),n,kCFStringEncodingUTF8)) return {};
        out.resize(strlen(out.c_str())); return out;
    }
    void Finish(bool ok) { std::lock_guard lock(mutex); frameOK=ok; completed=true; cv.notify_one(); }
};

class Callback final: public IBlackmagicRawCallback {
    std::atomic<uint32_t> refs{1};
public:
    SDKDecoder::Impl* impl;
    explicit Callback(SDKDecoder::Impl* p):impl(p){}
    HRESULT QueryInterface(REFIID,void**) override { return E_NOINTERFACE; }
    uint32_t AddRef() override { return ++refs; }
    uint32_t Release() override { auto r=--refs; if(!r) delete this; return r; }
    void ReadComplete(IBlackmagicRawJob* job,HRESULT result,IBlackmagicRawFrame* frame) override {
        if(FAILED(result)||!frame) { fprintf(stderr,"ReadComplete failed: 0x%x\n",unsigned(result)); if(job)job->Release(); impl->Finish(false); return; }
        IBlackmagicRawFrameProcessingAttributes* attrs=nullptr;
        IBlackmagicRawClipProcessingAttributes* clipAttrs=nullptr;
        frame->CloneFrameProcessingAttributes(&attrs);
        impl->clip->CloneClipProcessingAttributes(&clipAttrs);
        if(!attrs||!clipAttrs) {
            fprintf(stderr,"Missing processing attributes\n");
            if(attrs)attrs->Release(); if(clipAttrs)clipAttrs->Release();
            if(job)job->Release(); impl->Finish(false); return;
        }
        if(!impl->nativeCaptured) {
            Variant v; VariantInit(&v);
            if(SUCCEEDED(attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeISO,&v))) impl->nativeISO=v.uintVal;
            VariantClear(&v); VariantInit(&v);
            if(SUCCEEDED(attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin,&v))) impl->nativeColorTemp=v.uintVal;
            VariantClear(&v); VariantInit(&v);
            if(SUCCEEDED(attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint,&v))) impl->nativeTint=v.iVal;
            VariantClear(&v); VariantInit(&v);
            if(SUCCEEDED(attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure,&v))) impl->nativeExposure=v.fltVal;
            VariantClear(&v); impl->nativeCaptured=true;
        }
        // ISO=0 and temperature=0 mean native. Zero tint is a valid adjustment.
        auto a=impl->adjustments;
        Variant v; VariantInit(&v); v.vt=blackmagicRawVariantTypeU32;
        v.uintVal=a.iso?a.iso:impl->nativeISO;
        attrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeISO,&v);
        v.uintVal=a.colorTemp?a.colorTemp:impl->nativeColorTemp;
        attrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin,&v);
        v.vt=blackmagicRawVariantTypeS16; v.iVal=a.tint;
        attrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint,&v);
        v.vt=blackmagicRawVariantTypeFloat32; v.fltVal=a.exposure;
        attrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure,&v);
        v.vt=blackmagicRawVariantTypeU16; v.uiVal=a.highlightRecovery?1:0;
        clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeHighlightRecovery,&v);
        v.vt=blackmagicRawVariantTypeString; v.bstrVal=a.previewLUT?CFSTR("Embedded"):CFSTR("");
        clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributePost3DLUTMode,&v);
        if(impl->scale<=.125f) frame->SetResolutionScale(blackmagicRawResolutionScaleEighth);
        else if(impl->scale<=.25f) frame->SetResolutionScale(blackmagicRawResolutionScaleQuarter);
        else if(impl->scale<=.5f) frame->SetResolutionScale(blackmagicRawResolutionScaleHalf);
        frame->SetResourceFormat(impl->format==1?blackmagicRawResourceFormatRGBU16:blackmagicRawResourceFormatBGRAU8);
        IBlackmagicRawJob* process=nullptr;
        HRESULT hr=frame->CreateJobDecodeAndProcessFrame(clipAttrs,attrs,&process);
        attrs->Release(); clipAttrs->Release(); if(job)job->Release();
        if(FAILED(hr)||!process) { fprintf(stderr,"Create process job failed: 0x%x\n",unsigned(hr));impl->Finish(false); return; }
        if(FAILED(process->Submit())) { process->Release(); impl->Finish(false); }
    }
    void ProcessComplete(IBlackmagicRawJob* job,HRESULT hr,IBlackmagicRawProcessedImage* image) override {
        @autoreleasepool {
            bool ok=false;
            if(SUCCEEDED(hr)&&image) {
                uint32_t w=0,h=0,size=0; void* resource=nullptr;
                BlackmagicRawResourceType type=0;
                image->GetWidth(&w); image->GetHeight(&h); image->GetResourceSizeBytes(&size);
                image->GetResource(&resource); image->GetResourceType(&type);
                size_t pixelSize=impl->format==1?6:4;
                uint64_t imageBytes=uint64_t(w)*h*pixelSize;
                if(w&&h&&size&&resource&&size<=512ULL*1024*1024&&imageBytes<=size) {
                    const void* bytes=nullptr;
                    id<MTLBuffer> staging=nil;
                    if(type==blackmagicRawResourceTypeBufferCPU) bytes=resource;
                    else if(type==blackmagicRawResourceTypeBufferMetal) {
                        void* context=nullptr; void* commandQueue=nullptr;
                        image->GetResourceContextAndCommandQueue(&context,&commandQueue);
                        id<MTLCommandQueue> queue=(__bridge id<MTLCommandQueue>)commandQueue;
                        id<MTLBuffer> source=(__bridge id<MTLBuffer>)resource;
                        if(queue&&source.length>=size) {
                            staging=[queue.device newBufferWithLength:size options:MTLResourceStorageModeShared];
                            id<MTLCommandBuffer> command=[queue commandBuffer];
                            id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
                            if(staging&&blit) {
                                [blit copyFromBuffer:source sourceOffset:0 toBuffer:staging destinationOffset:0 size:size];
                                [blit endEncoding]; [command commit]; [command waitUntilCompleted];
                                if(command.status==MTLCommandBufferStatusCompleted) bytes=staging.contents;
                            }
                        }
                    }
                    if(bytes) {
                        impl->frame.width=w; impl->frame.height=h; impl->frame.stride=w*pixelSize;
                        impl->frame.pixels.assign((const uint8_t*)bytes,(const uint8_t*)bytes+imageBytes); ok=true;
                    }
                }
            }
            if(!ok)fprintf(stderr,"ProcessComplete failed: 0x%x\n",unsigned(hr));
            if(job)job->Release(); impl->Finish(ok);
        }
    }
    void PreparePipelineComplete(void*,HRESULT hr) override {
        std::lock_guard lock(impl->mutex); impl->prepared=true; impl->prepareOK=SUCCEEDED(hr); impl->cv.notify_one();
    }
    void ReadAudioComplete(IBlackmagicRawJob*,HRESULT,IBlackmagicRawAudioBuffer*) override {}
    void DecodeComplete(IBlackmagicRawJob*,HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob*,float) override {}
    void TrimComplete(IBlackmagicRawJob*,HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip*,CFStringRef,uint32_t,CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip*,CFStringRef,uint32_t,CFStringRef) override {}
};

SDKDecoder::SDKDecoder():m_impl(std::make_unique<Impl>()){}
SDKDecoder::~SDKDecoder(){Close();}
bool SDKDecoder::Open(const std::string& path,bool metal,int format) {
    Close(); auto& p=*m_impl; p.format=format;
    p.factory=CreateBlackmagicRawFactoryInstanceFromPath(CFSTR(BRAW_SDK_LIBRARY_PATH));
    if(!p.factory||FAILED(p.factory->CreateCodec(&p.codec)))return false;
    IBlackmagicRawConfiguration* config=nullptr;
    if(FAILED(p.codec->QueryInterface(IID_IBlackmagicRawConfiguration,(void**)&config)))return false;
    CFStringRef version=nullptr;
    config->GetVersion(&version); p.version=Impl::FromCFString(version); if(version)CFRelease(version);

    HRESULT hr;
    if(metal) {
        p.device=MTLCreateSystemDefaultDevice(); p.queue=[p.device newCommandQueue];
        hr=p.device&&p.queue?config->SetPipeline(blackmagicRawPipelineMetal,(__bridge void*)p.device,(__bridge void*)p.queue):E_FAIL;
    } else hr=config->SetPipeline(blackmagicRawPipelineCPU,nullptr,nullptr);
    config->SetCPUThreads(4); config->Release(); if(FAILED(hr)){fprintf(stderr,"SetPipeline failed: 0x%x\n",unsigned(hr));return false;}
    CFStringRef cf=CFStringCreateWithCString(nullptr,path.c_str(),kCFStringEncodingUTF8);
    if(!cf)return false;
    hr=p.codec->OpenClip(cf,&p.clip); CFRelease(cf);
    if(FAILED(hr)||!p.clip){fprintf(stderr,"OpenClip failed: 0x%x\n",unsigned(hr));return false;}
    p.clip->GetWidth(&p.width); p.clip->GetHeight(&p.height);
    p.clip->GetFrameCount(&p.frameCount); p.clip->GetFrameRate(&p.frameRate);
    if(!p.width||!p.height||!p.frameCount||p.frameRate<=0){fprintf(stderr,"Invalid metadata: %u x %u, %llu frames, %f fps\n",p.width,p.height,p.frameCount,p.frameRate);return false;}
    CFStringRef cam=nullptr; p.clip->GetCameraType(&cam); p.cameraType=Impl::FromCFString(cam); if(cam)CFRelease(cam);
    p.callback=new Callback(&p);
    if(FAILED(p.codec->SetCallback(p.callback))){fprintf(stderr,"SetCallback failed\n");return false;}
    p.prepared=false; p.prepareOK=false;
    hr=p.codec->PreparePipeline(metal?blackmagicRawPipelineMetal:blackmagicRawPipelineCPU,
        metal?(__bridge void*)p.device:nullptr,metal?(__bridge void*)p.queue:nullptr,nullptr);
    if(FAILED(hr)){fprintf(stderr,"PreparePipeline failed: 0x%x\n",unsigned(hr));return false;}
    std::unique_lock lock(p.mutex);
    if(!p.cv.wait_for(lock,std::chrono::seconds(10),[&]{return p.prepared;}))_exit(21);
    if(!p.prepareOK){fprintf(stderr,"Pipeline preparation failed\n");return false;}
    lock.unlock(); Frame frame; ClipAdjustments a; a.colorTemp=0; a.previewLUT=false;
    bool ok=Decode(0,a,.125f,frame);
    if(!ok){fprintf(stderr,"Native frame decode failed\n");return false;}
    if(SUCCEEDED(p.codec->QueryInterface(IID_IBlackmagicRawConfiguration,(void**)&config))) {
        version=nullptr;config->GetVersion(&version);p.version=Impl::FromCFString(version);
        if(version)CFRelease(version);config->Release();
    }
    // Some codec builds report 0.0 through GetVersion. Identify the framework
    // being loaded from its own bundle metadata as well.
    NSString* infoPath=[@BRAW_SDK_LIBRARY_PATH stringByAppendingPathComponent:@"BlackmagicRawAPI.framework/Resources/Info.plist"];
    NSDictionary* bundleInfo=[NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSString* bundleVersion=bundleInfo[@"CFBundleShortVersionString"];
    fprintf(stderr,"BRAW worker: framework %s, API reports %s, %s pipeline\n",
        bundleVersion.UTF8String?:"unknown",p.version.c_str(),metal?"Metal":"CPU");
    if(bundleVersion)p.version=bundleVersion.UTF8String;
    return true;
}
void SDKDecoder::Close() {
    auto& p=*m_impl;
    if(p.codec) { p.codec->FlushJobs(); p.codec->SetCallback(nullptr); }
    if(p.clip){p.clip->Release();p.clip=nullptr;}
    if(p.codec){p.codec->Release();p.codec=nullptr;}
    if(p.callback){p.callback->Release();p.callback=nullptr;}
    if(p.factory){p.factory->Release();p.factory=nullptr;}
    p.device=nil;p.queue=nil;p.nativeCaptured=false;p.width=0;p.height=0;
}
bool SDKDecoder::Decode(uint64_t index,const ClipAdjustments& a,float scale,Frame& out) {
    auto& p=*m_impl; if(!p.clip||index>=p.frameCount)return false;
    {std::lock_guard lock(p.mutex);p.completed=false;p.frameOK=false;p.frame={};p.adjustments=a;p.scale=scale;}
    IBlackmagicRawJob* job=nullptr;
    if(FAILED(p.clip->CreateJobReadFrame(index,&job))||!job)return false;
    if(FAILED(job->Submit())){job->Release();return false;}
    std::unique_lock lock(p.mutex);
    // An expired request cannot reuse callback storage. Exit the worker instead.
    if(!p.cv.wait_for(lock,std::chrono::seconds(25),[&]{return p.completed;}))_exit(22);
    if(!p.frameOK)return false;
    out=std::move(p.frame);return true;
}
#define GETTER(type,name,field) type SDKDecoder::name() const {return m_impl->field;}
GETTER(uint32_t,GetWidth,width) GETTER(uint32_t,GetHeight,height)
GETTER(float,GetFrameRate,frameRate) GETTER(uint64_t,GetFrameCount,frameCount)
GETTER(uint32_t,GetNativeISO,nativeISO) GETTER(uint32_t,GetNativeColorTemp,nativeColorTemp)
GETTER(int16_t,GetNativeTint,nativeTint) GETTER(float,GetNativeExposure,nativeExposure)
GETTER(std::string,GetCameraType,cameraType) GETTER(std::string,Version,version)
#undef GETTER
#include "SDKMetadata.inc"
SDKDecoder::AudioInfo SDKDecoder::GetAudioInfo() {
    AudioInfo info; IBlackmagicRawClipAudio* audio=nullptr;
    if(m_impl->clip&&SUCCEEDED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipAudio,(void**)&audio))&&audio) {
        audio->GetAudioSampleRate(&info.rate);audio->GetAudioChannelCount(&info.channels);
        audio->GetAudioBitDepth(&info.bits);audio->GetAudioSampleCount(&info.samples);audio->Release();
    }
    return info;
}
bool SDKDecoder::ReadAudio(uint64_t start,uint32_t count,std::vector<uint8_t>& bytes) {
    auto info=GetAudioInfo(); if(!info.channels||!info.bits||!count||count>65536||start>=info.samples)return false;
    uint64_t size=uint64_t(count)*info.channels*(info.bits/8);
    if(!size||size>16*1024*1024)return false;
    IBlackmagicRawClipAudio* audio=nullptr;
    if(FAILED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipAudio,(void**)&audio))||!audio)return false;
    bytes.resize(size);uint32_t read=0,got=0;
    HRESULT hr=audio->GetAudioSamples(start,bytes.data(),size,count,&read,&got);audio->Release();
    if(FAILED(hr)||!read||got>size)return false;
    bytes.resize(got);return true;
}
