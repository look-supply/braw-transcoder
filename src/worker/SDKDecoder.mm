#include "worker/SDKDecoder.h"
#include "worker/Protocol.h"
#include "core/ImageGeometry.h"
#include "core/ImageDesqueeze.h"
#include "BlackmagicRawAPI.h"
#include "BlackmagicRawAPIDispatch.cpp"
#import <Metal/Metal.h>
#import <Accelerate/Accelerate.h>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <unistd.h>

struct SDKDecoder::Impl {
    IBlackmagicRawFactory* factory=nullptr;
    IBlackmagicRaw* codec=nullptr;
    IBlackmagicRawClip* clip=nullptr;
    IBlackmagicRawPost3DLUT* embeddedLUT=nullptr;
    IBlackmagicRawCallback* callback=nullptr;
    id<MTLDevice> device=nil;
    id<MTLCommandQueue> queue=nil;
    std::mutex mutex;
    std::condition_variable cv;
    bool prepared=false, prepareOK=false, completed=false, frameOK=false;
    bool nativeCaptured=false;
    uint32_t width=0,height=0,nativeISO=800,nativeColorTemp=5600;
    std::vector<uint32_t> isoList;
    bool isoReadOnly=true;
    uint32_t lensCorrectionSupport=0;
    uint64_t frameCount=0;
    float frameRate=0,nativeExposure=0;
    int16_t nativeTint=0;
    int format=0;
    ClipAdjustments adjustments;
    std::array<IBlackmagicRawClip*,8> geometryClips{};
    GeometryInfo geometryInfo;
    ToneCurveInfo toneInfo;
    float scale=1;
    uint32_t previewWidth=0,previewHeight=0;
    Frame frame;
    std::string cameraType, version;
    std::map<std::string,std::string> frameMetadata;
    static std::string FromCFString(CFStringRef s) {
        if (!s) return {};
        CFIndex n=CFStringGetMaximumSizeForEncoding(CFStringGetLength(s),kCFStringEncodingUTF8)+1;
        std::string out(n,'\0');
        if(!CFStringGetCString(s,out.data(),n,kCFStringEncodingUTF8)) return {};
        out.resize(strlen(out.c_str())); return out;
    }
    void Finish(bool ok) { std::lock_guard lock(mutex); frameOK=ok; completed=true; cv.notify_one(); }
};

static std::map<std::string,std::string> ReadCameraMetadata(IBlackmagicRawMetadataIterator* iterator) {
    std::map<std::string,std::string> result;
    if(!iterator)return result;
    for(;;) {
        CFStringRef key=nullptr;
        if(FAILED(iterator->GetKey(&key))||!key)break;
        Variant value;VariantInit(&value);
        std::string text;
        if(SUCCEEDED(iterator->GetData(&value))) {
            switch(value.vt) {
                case blackmagicRawVariantTypeString:text=SDKDecoder::Impl::FromCFString(value.bstrVal);break;
                case blackmagicRawVariantTypeU8:text=std::to_string(value.uiVal & 0xff);break;
                case blackmagicRawVariantTypeU16:text=std::to_string(value.uiVal);break;
                case blackmagicRawVariantTypeU32:text=std::to_string(value.uintVal);break;
                case blackmagicRawVariantTypeS16:text=std::to_string(value.iVal);break;
                case blackmagicRawVariantTypeS32:text=std::to_string(value.intVal);break;
                case blackmagicRawVariantTypeFloat32:if(std::isfinite(value.fltVal))text=std::to_string(value.fltVal);break;
                case blackmagicRawVariantTypeFloat64:if(std::isfinite(value.dblVal))text=std::to_string(value.dblVal);break;
                default:break; // Binary LUTs/arrays are not camera slate text.
            }
        }
        auto name=SDKDecoder::Impl::FromCFString(key);
        if(!name.empty()&&!text.empty())result[name]=text;
        VariantClear(&value);CFRelease(key);
        if(iterator->Next()!=S_OK)break;
    }
    return result;
}

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
        const auto mode=impl->adjustments.anamorphic==CustomAnamorphicMode?1:impl->adjustments.anamorphic;
        impl->geometryClips[mode]->CloneClipProcessingAttributes(&clipAttrs);
        if(!attrs||!clipAttrs) {
            fprintf(stderr,"Missing processing attributes\n");
            if(attrs)attrs->Release(); if(clipAttrs)clipAttrs->Release();
            if(job)job->Release(); impl->Finish(false); return;
        }
        if(!impl->nativeCaptured) {
            IBlackmagicRawMetadataIterator* iterator=nullptr;
            if(SUCCEEDED(frame->GetMetadataIterator(&iterator))&&iterator) {
                impl->frameMetadata=ReadCameraMetadata(iterator);iterator->Release();
            }
            CFStringRef timecode=nullptr;
            if(SUCCEEDED(frame->GetTimecode(&timecode))&&timecode) {
                impl->frameMetadata["timecode"]=SDKDecoder::Impl::FromCFString(timecode);CFRelease(timecode);
            }
            float sensorRate=0;
            if(SUCCEEDED(frame->GetSensorRate(&sensorRate))&&sensorRate>0)
                impl->frameMetadata["sensor_fps"]=std::to_string(sensorRate);
            Variant v; VariantInit(&v);
            if(SUCCEEDED(attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeISO,&v))) impl->nativeISO=v.uintVal;
            VariantClear(&v); VariantInit(&v);
            if(SUCCEEDED(attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin,&v))) impl->nativeColorTemp=v.uintVal;
            VariantClear(&v); VariantInit(&v);
            if(SUCCEEDED(attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint,&v))) impl->nativeTint=v.iVal;
            VariantClear(&v); VariantInit(&v);
            if(SUCCEEDED(attrs->GetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure,&v))) impl->nativeExposure=v.fltVal;
            VariantClear(&v); impl->nativeCaptured=true;
            uint32_t count=0;
            if(SUCCEEDED(attrs->GetISOList(nullptr,&count,&impl->isoReadOnly))&&count&&count<=4096) {
                impl->isoList.resize(count);
                if(SUCCEEDED(attrs->GetISOList(impl->isoList.data(),&count,&impl->isoReadOnly)))impl->isoList.resize(count);
                else impl->isoList.clear();
            }
            const BlackmagicRawClipProcessingAttribute lensAttributes[] = {
                blackmagicRawClipProcessingAttributeLensDistortionCorrectionEnable,
                blackmagicRawClipProcessingAttributeLensShadingEnable,
                blackmagicRawClipProcessingAttributeLensChromaticAberrationCorrectionEnable
            };
            for (uint32_t i=0;i<3;i++) {
                Variant minimum,maximum;VariantInit(&minimum);VariantInit(&maximum);bool readOnly=true;
                HRESULT hr=clipAttrs->GetClipAttributeRange(lensAttributes[i],&minimum,&maximum,&readOnly);
                if(SUCCEEDED(hr)&&!readOnly&&minimum.vt==blackmagicRawVariantTypeU16&&
                   maximum.vt==blackmagicRawVariantTypeU16&&minimum.uiVal==0&&maximum.uiVal>=1)
                    impl->lensCorrectionSupport|=1u<<i;
                VariantClear(&minimum);VariantClear(&maximum);
            }
            IBlackmagicRawToneCurve* curves=nullptr;
            Variant gamma,gamut,generation;VariantInit(&gamma);VariantInit(&gamut);VariantInit(&generation);
            clipAttrs->GetClipAttribute(blackmagicRawClipProcessingAttributeGamma,&gamma);
            clipAttrs->GetClipAttribute(blackmagicRawClipProcessingAttributeGamut,&gamut);
            clipAttrs->GetClipAttribute(blackmagicRawClipProcessingAttributeColorScienceGen,&generation);
            const auto gammaName=gamma.vt==blackmagicRawVariantTypeString?SDKDecoder::Impl::FromCFString(gamma.bstrVal):"";
            const auto gamutName=gamut.vt==blackmagicRawVariantTypeString?SDKDecoder::Impl::FromCFString(gamut.bstrVal):"";
            auto& tone=impl->toneInfo;
            if(gamutName=="Blackmagic Design" && (gammaName=="Blackmagic Design Film" ||
                gammaName=="Blackmagic Design Extended Video" || gammaName=="Blackmagic Design Custom") &&
                SUCCEEDED(impl->codec->QueryInterface(IID_IBlackmagicRawToneCurve,(void**)&curves)) && curves) {
                auto camera=CFStringCreateWithCString(nullptr,impl->cameraType.c_str(),kCFStringEncodingUTF8);
                uint16_t videoBlack=0;auto& values=tone.defaults;
                HRESULT hr=curves->GetToneCurve(camera,gamma.bstrVal,generation.uiVal,
                    &values[0],&values[1],&values[2],&values[3],&values[4],&values[5],&values[6],&videoBlack);
                CFRelease(camera);curves->Release();tone.videoBlack=videoBlack!=0;
                if(gammaName=="Blackmagic Design Custom") {
                    Variant nativeBlack{};
                    if(SUCCEEDED(clipAttrs->GetClipAttribute(blackmagicRawClipProcessingAttributeToneCurveVideoBlackLevel,&nativeBlack))&&nativeBlack.vt==blackmagicRawVariantTypeU16)
                        tone.videoBlack=nativeBlack.uiVal!=0;
                    VariantClear(&nativeBlack);
                }
                tone.supported=SUCCEEDED(hr);
                const BlackmagicRawClipProcessingAttribute keys[]={
                    blackmagicRawClipProcessingAttributeToneCurveContrast,blackmagicRawClipProcessingAttributeToneCurveSaturation,
                    blackmagicRawClipProcessingAttributeToneCurveMidpoint,blackmagicRawClipProcessingAttributeToneCurveHighlights,
                    blackmagicRawClipProcessingAttributeToneCurveShadows,blackmagicRawClipProcessingAttributeToneCurveBlackLevel,
                    blackmagicRawClipProcessingAttributeToneCurveWhiteLevel};
                // Probe writable custom-gamma ranges without changing the source attributes.
                IBlackmagicRawClipProcessingAttributes* custom=nullptr;impl->clip->CloneClipProcessingAttributes(&custom);
                Variant customGamma{};customGamma.vt=blackmagicRawVariantTypeString;customGamma.bstrVal=CFSTR("Blackmagic Design Custom");
                if(!custom||FAILED(custom->SetClipAttribute(blackmagicRawClipProcessingAttributeGamma,&customGamma)))tone.supported=false;
                if(custom) {
                    for(size_t i=0;i<ToneValueCount;i++) {
                        Variant lo{},hi{},native{};bool readOnly=true;
                        if(gammaName=="Blackmagic Design Custom" && SUCCEEDED(clipAttrs->GetClipAttribute(keys[i],&native)) && native.vt==blackmagicRawVariantTypeFloat32)values[i]=native.fltVal;
                        if(FAILED(custom->GetClipAttributeRange(keys[i],&lo,&hi,&readOnly))||readOnly||
                           lo.vt!=blackmagicRawVariantTypeFloat32||hi.vt!=blackmagicRawVariantTypeFloat32||lo.fltVal>=hi.fltVal)tone.supported=false;
                        else {tone.minimum[i]=lo.fltVal;tone.maximum[i]=hi.fltVal;values[i]=std::clamp(values[i],lo.fltVal,hi.fltVal);}
                        VariantClear(&lo);VariantClear(&hi);VariantClear(&native);
                    }
                    Variant lo{},hi{};bool readOnly=true;
                    tone.videoBlackSupported=SUCCEEDED(custom->GetClipAttributeRange(blackmagicRawClipProcessingAttributeToneCurveVideoBlackLevel,&lo,&hi,&readOnly))&&!readOnly;
                    VariantClear(&lo);VariantClear(&hi);custom->Release();
                }
            }
            VariantClear(&gamma);VariantClear(&gamut);VariantClear(&generation);
            if(impl->isoList.empty()) {impl->isoList={impl->nativeISO};impl->isoReadOnly=true;}
        }
        // ISO=0 and temperature=0 mean native. Zero tint is a valid adjustment.
        auto a=impl->adjustments;
        Variant v; VariantInit(&v); v.vt=blackmagicRawVariantTypeU32;
        v.uintVal=a.iso?a.iso:impl->nativeISO;
        HRESULT isoResult=S_OK;
        if(std::find(impl->isoList.begin(),impl->isoList.end(),v.uintVal)==impl->isoList.end())isoResult=E_INVALIDARG;
        else if(!impl->isoReadOnly)isoResult=attrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeISO,&v);
        else if(v.uintVal!=impl->nativeISO)isoResult=E_INVALIDARG;
        if(FAILED(isoResult)) {
            fprintf(stderr,"Could not apply ISO %u for recorded analog gain (as-shot ISO %u): 0x%x\n",v.uintVal,impl->nativeISO,unsigned(isoResult));
            attrs->Release();clipAttrs->Release();if(job)job->Release();impl->Finish(false);return;
        }
        v.uintVal=a.colorTemp?a.colorTemp:impl->nativeColorTemp;
        attrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin,&v);
        v.vt=blackmagicRawVariantTypeS16; v.iVal=a.tint;
        attrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeWhiteBalanceTint,&v);
        v.vt=blackmagicRawVariantTypeFloat32; v.fltVal=a.exposure;
        attrs->SetFrameAttribute(blackmagicRawFrameProcessingAttributeExposure,&v);
        v.vt=blackmagicRawVariantTypeU16; v.uiVal=a.highlightRecovery?1:0;
        clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeHighlightRecovery,&v);
        v.uiVal=a.gamutCompression?1:0;
        HRESULT gamutResult=clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeGamutCompressionEnable,&v);
        if(FAILED(gamutResult)) {
            fprintf(stderr,"Could not set gamut compression to %s: 0x%x\n",a.gamutCompression?"enabled":"disabled",unsigned(gamutResult));
            attrs->Release();clipAttrs->Release();if(job)job->Release();impl->Finish(false);return;
        }
        if(a.lensCorrections & ~impl->lensCorrectionSupport) {
            fprintf(stderr,"Requested lens correction is unavailable for this clip.\n");
            attrs->Release();clipAttrs->Release();if(job)job->Release();impl->Finish(false);return;
        }
        const BlackmagicRawClipProcessingAttribute lensAttributes[] = {
            blackmagicRawClipProcessingAttributeLensDistortionCorrectionEnable,
            blackmagicRawClipProcessingAttributeLensShadingEnable,
            blackmagicRawClipProcessingAttributeLensChromaticAberrationCorrectionEnable
        };
        for(uint32_t i=0;i<3;i++)if(impl->lensCorrectionSupport & (1u<<i)) {
            v.uiVal=(a.lensCorrections & (1u<<i))?1:0;
            HRESULT hr=clipAttrs->SetClipAttribute(lensAttributes[i],&v);
            if(FAILED(hr)) {
                fprintf(stderr,"Could not apply lens correction %u: 0x%x\n",i,unsigned(hr));
                attrs->Release();clipAttrs->Release();if(job)job->Release();impl->Finish(false);return;
            }
        }
        if(a.toneCurveEnabled) {
            if(!impl->toneInfo.supported) {
                fprintf(stderr,"Custom tone curves are unavailable for this source gamma/gamut.\n");
                attrs->Release();clipAttrs->Release();if(job)job->Release();impl->Finish(false);return;
            }
            v.vt=blackmagicRawVariantTypeString;v.bstrVal=CFSTR("Blackmagic Design Custom");
            HRESULT hr=clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeGamma,&v);
            const BlackmagicRawClipProcessingAttribute keys[]={
                blackmagicRawClipProcessingAttributeToneCurveContrast,blackmagicRawClipProcessingAttributeToneCurveSaturation,
                blackmagicRawClipProcessingAttributeToneCurveMidpoint,blackmagicRawClipProcessingAttributeToneCurveHighlights,
                blackmagicRawClipProcessingAttributeToneCurveShadows,blackmagicRawClipProcessingAttributeToneCurveBlackLevel,
                blackmagicRawClipProcessingAttributeToneCurveWhiteLevel};
            v.vt=blackmagicRawVariantTypeFloat32;
            for(size_t i=0;i<ToneValueCount&&SUCCEEDED(hr);i++) {
                v.fltVal=a.toneValues[i];
                if(!std::isfinite(v.fltVal)||v.fltVal<impl->toneInfo.minimum[i]||v.fltVal>impl->toneInfo.maximum[i])hr=E_INVALIDARG;
                else hr=clipAttrs->SetClipAttribute(keys[i],&v);
            }
            if(SUCCEEDED(hr)&&impl->toneInfo.videoBlackSupported) {
                v.vt=blackmagicRawVariantTypeU16;v.uiVal=a.videoBlack?1:0;
                hr=clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributeToneCurveVideoBlackLevel,&v);
            }
            if(FAILED(hr)) {
                fprintf(stderr,"Could not apply custom tone curve: 0x%x\n",unsigned(hr));
                attrs->Release();clipAttrs->Release();if(job)job->Release();impl->Finish(false);return;
            }
        }
        v.vt=blackmagicRawVariantTypeString; v.bstrVal=a.previewLUT?CFSTR("Embedded"):CFSTR("Disabled");
        HRESULT lutResult=clipAttrs->SetClipAttribute(blackmagicRawClipProcessingAttributePost3DLUTMode,&v);
        if(FAILED(lutResult)) {
            fprintf(stderr,"Could not set preview LUT mode to %s: 0x%x\n",a.previewLUT?"Embedded":"Disabled",unsigned(lutResult));
            attrs->Release();clipAttrs->Release();if(job)job->Release();impl->Finish(false);return;
        }
        if(impl->scale<=.125f) frame->SetResolutionScale(blackmagicRawResolutionScaleEighth);
        else if(impl->scale<=.25f) frame->SetResolutionScale(blackmagicRawResolutionScaleQuarter);
        else if(impl->scale<=.5f) frame->SetResolutionScale(blackmagicRawResolutionScaleHalf);
        else frame->SetResolutionScale(blackmagicRawResolutionScaleFull);
        frame->SetResourceFormat(impl->format==1?blackmagicRawResourceFormatRGBU16:blackmagicRawResourceFormatBGRAU8);
        impl->previewWidth=impl->previewHeight=0;
        if(a.highlightRecovery && impl->format==0 && impl->scale<1) {
            // SDK 6 recovery produces colored shadow speckling in reduced
            // sensor decodes. Recover at full resolution, then resize the
            // processed image, preserving the sensor-specific preview size.
            IBlackmagicRawFrameEx* frameEx=nullptr;
            HRESULT resizeResult=frame->QueryInterface(IID_IBlackmagicRawFrameEx,(void**)&frameEx);
            if(SUCCEEDED(resizeResult)&&frameEx) {
                resizeResult=frameEx->GetProcessedImageResolution(&impl->previewWidth,&impl->previewHeight);
                frameEx->Release();
            }
            if(FAILED(resizeResult)||!impl->previewWidth||!impl->previewHeight||
               FAILED(frame->SetResolutionScale(blackmagicRawResolutionScaleFull))) {
                fprintf(stderr,"Could not prepare full-resolution highlight recovery preview\n");
                attrs->Release();clipAttrs->Release();if(job)job->Release();impl->Finish(false);return;
            }
        }
        IBlackmagicRawJob* process=nullptr;
        HRESULT hr=frame->CreateJobDecodeAndProcessFrame(clipAttrs,attrs,&process);
        attrs->Release(); clipAttrs->Release(); if(job)job->Release();
        if(FAILED(hr)||!process) { fprintf(stderr,"Create process job failed: 0x%x\n",unsigned(hr));impl->Finish(false); return; }
        hr=process->Submit();
        if(FAILED(hr)) { fprintf(stderr,"Submit process job failed: 0x%x\n",unsigned(hr));process->Release(); impl->Finish(false); }
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
                if(size>WorkerProtocol::maxPayload)
                    fprintf(stderr,"Decoded frame exceeds supported payload: %u bytes, limit %llu bytes\n",size,WorkerProtocol::maxPayload);
                if(w&&h&&size&&resource&&size<=WorkerProtocol::maxPayload&&imageBytes<=size) {
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
                        if(impl->previewWidth && impl->previewHeight) {
                            const uint32_t outW=impl->previewWidth,outH=impl->previewHeight;
                            if(outW<=w && outH<=h && uint64_t(outW)*outH*4<=WorkerProtocol::maxPayload) {
                                impl->frame.pixels.resize(uint64_t(outW)*outH*4);
                                vImage_Buffer sourceImage{const_cast<void*>(bytes),h,w,size_t(w)*4};
                                vImage_Buffer destination{impl->frame.pixels.data(),outH,outW,size_t(outW)*4};
                                const auto resizeError=vImageScale_ARGB8888(&sourceImage,&destination,nullptr,kvImageHighQualityResampling);
                                if(resizeError==kvImageNoError) {
                                    impl->frame.width=outW;impl->frame.height=outH;impl->frame.stride=outW*4;ok=true;
                                } else fprintf(stderr,"Preview resize failed: %ld\n",resizeError);
                            }
                        } else {
                            impl->frame.width=w; impl->frame.height=h; impl->frame.stride=w*pixelSize;
                            impl->frame.pixels.assign((const uint8_t*)bytes,(const uint8_t*)bytes+imageBytes); ok=true;
                        }
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
    if(!p.factory){fprintf(stderr,"Could not load Blackmagic RAW SDK from %s\n",BRAW_SDK_LIBRARY_PATH);return false;}
    HRESULT createResult=p.factory->CreateCodec(&p.codec);
    if(FAILED(createResult)||!p.codec){fprintf(stderr,"CreateCodec failed: 0x%x\n",unsigned(createResult));return false;}
    IBlackmagicRawConfiguration* config=nullptr;
    HRESULT configResult=p.codec->QueryInterface(IID_IBlackmagicRawConfiguration,(void**)&config);
    if(FAILED(configResult)||!config){fprintf(stderr,"Get SDK configuration failed: 0x%x\n",unsigned(configResult));return false;}
    CFStringRef version=nullptr;
    config->GetVersion(&version); p.version=Impl::FromCFString(version); if(version)CFRelease(version);

    HRESULT hr;
    if(metal) {
        p.device=MTLCreateSystemDefaultDevice(); p.queue=[p.device newCommandQueue];
        hr=p.device&&p.queue?config->SetPipeline(blackmagicRawPipelineMetal,(__bridge void*)p.device,(__bridge void*)p.queue):E_FAIL;
    } else hr=config->SetPipeline(blackmagicRawPipelineCPU,nullptr,nullptr);
    config->SetCPUThreads(4); config->Release(); if(FAILED(hr)){fprintf(stderr,"SetPipeline failed: 0x%x\n",unsigned(hr));return false;}
    CFStringRef cf=CFStringCreateWithCString(nullptr,path.c_str(),kCFStringEncodingUTF8);
    if(!cf){fprintf(stderr,"Could not convert source path to a UTF-8 string\n");return false;}
    hr=p.codec->OpenClip(cf,&p.clip); CFRelease(cf);
    if(FAILED(hr)||!p.clip){fprintf(stderr,"OpenClip failed: 0x%x\n",unsigned(hr));return false;}
    IBlackmagicRawClipProcessingAttributes* lutAttributes=nullptr;
    if(SUCCEEDED(p.clip->CloneClipProcessingAttributes(&lutAttributes))&&lutAttributes) {
        lutAttributes->GetEmbeddedPost3DLUT(&p.embeddedLUT);
        lutAttributes->Release();
    }
    const BlackmagicRawAnamorphicRatio ratios[]={blackmagicRawAnamorphicRatioFromMetadata,
        blackmagicRawAnamorphicRatioDisabled,blackmagicRawAnamorphicRatio133x,blackmagicRawAnamorphicRatio15x,
        blackmagicRawAnamorphicRatio16x,blackmagicRawAnamorphicRatio166x,blackmagicRawAnamorphicRatio18x,blackmagicRawAnamorphicRatio2x};
    p.geometryClips[0]=p.clip;p.clip->AddRef();
    for(size_t i=0;i<8;i++) {
        if(i) {
            IBlackmagicRawClipGeometry* geometry=nullptr;
            HRESULT result=p.factory->CreateClipGeometry(&geometry);
            if(SUCCEEDED(result)&&geometry)result=geometry->SetAnamorphicRatio(ratios[i]);
            if(SUCCEEDED(result))result=p.clip->CloneWithGeometry(geometry,&p.geometryClips[i]);
            if(geometry)geometry->Release();
            if(FAILED(result)||!p.geometryClips[i]){fprintf(stderr,"Cannot configure anamorphic geometry: 0x%x\n",unsigned(result));return false;}
        }
        p.geometryClips[i]->GetWidth(&p.geometryInfo.dimensions[i][0]);
        p.geometryClips[i]->GetHeight(&p.geometryInfo.dimensions[i][1]);
    }
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
    if(p.embeddedLUT){p.embeddedLUT->Release();p.embeddedLUT=nullptr;}
    if(p.codec) { p.codec->FlushJobs(); p.codec->SetCallback(nullptr); }
    for(auto*& clip:p.geometryClips)if(clip){clip->Release();clip=nullptr;}
    if(p.clip){p.clip->Release();p.clip=nullptr;}
    if(p.codec){p.codec->Release();p.codec=nullptr;}
    if(p.callback){p.callback->Release();p.callback=nullptr;}
    if(p.factory){p.factory->Release();p.factory=nullptr;}
    p.device=nil;p.queue=nil;p.nativeCaptured=false;p.width=0;p.height=0;
    p.frameMetadata.clear();p.isoList.clear();p.isoReadOnly=true;p.lensCorrectionSupport=0;p.toneInfo={};p.geometryInfo={};
}
bool SDKDecoder::Decode(uint64_t index,const ClipAdjustments& a,float scale,Frame& out) {
    auto& p=*m_impl;
    if(!p.clip||index>=p.frameCount) {fprintf(stderr,"Cannot read frame %llu: clip open=%d, frame count=%llu\n",index,p.clip!=nullptr,p.frameCount);return false;}
    {std::lock_guard lock(p.mutex);p.completed=false;p.frameOK=false;p.frame={};p.adjustments=a;p.scale=scale;}
    IBlackmagicRawJob* job=nullptr;
    if(a.anamorphic>CustomAnamorphicMode||a.rotation>3||a.flips>3||!ValidCustomDesqueeze(a.customDesqueeze)){fprintf(stderr,"Invalid image geometry\n");return false;}
    const auto mode=a.anamorphic==CustomAnamorphicMode?1:a.anamorphic;
    HRESULT hr=p.geometryClips[mode]->CreateJobReadFrame(index,&job);
    if(FAILED(hr)||!job){fprintf(stderr,"Create read job for frame %llu failed: 0x%x\n",index,unsigned(hr));return false;}
    hr=job->Submit();
    if(FAILED(hr)){fprintf(stderr,"Submit read job for frame %llu failed: 0x%x\n",index,unsigned(hr));job->Release();return false;}
    std::unique_lock lock(p.mutex);
    // An expired request cannot reuse callback storage. Exit the worker instead.
    if(!p.cv.wait_for(lock,std::chrono::seconds(25),[&]{return p.completed;}))_exit(22);
    if(!p.frameOK)return false;
    out=std::move(p.frame);
    if(a.anamorphic==CustomAnamorphicMode && !DesqueezeImage(out,p.format,a.customDesqueeze)) {
        fprintf(stderr,"Custom desqueeze failed\n");return false;
    }
    if(p.format==1)TransformImage<6>(out.pixels,out.width,out.height,a.rotation,a.flips);
    else TransformImage<4>(out.pixels,out.width,out.height,a.rotation,a.flips);
    out.stride=out.width*(p.format==1?6:4);return true;
}
#define GETTER(type,name,field) type SDKDecoder::name() const {return m_impl->field;}
GETTER(uint32_t,GetWidth,width) GETTER(uint32_t,GetHeight,height)
GETTER(float,GetFrameRate,frameRate) GETTER(uint64_t,GetFrameCount,frameCount)
GETTER(uint32_t,GetNativeISO,nativeISO) GETTER(uint32_t,GetNativeColorTemp,nativeColorTemp)
GETTER(std::vector<uint32_t>,GetISOList,isoList) GETTER(bool,ISOIsReadOnly,isoReadOnly) GETTER(uint32_t,GetLensCorrectionSupport,lensCorrectionSupport)
GETTER(int16_t,GetNativeTint,nativeTint) GETTER(float,GetNativeExposure,nativeExposure)
GETTER(std::string,GetCameraType,cameraType) GETTER(std::string,Version,version)
#undef GETTER
GeometryInfo SDKDecoder::GetGeometryInfo() const{return m_impl->geometryInfo;}
ToneCurveInfo SDKDecoder::GetToneCurveInfo() const{return m_impl->toneInfo;}
bool SDKDecoder::HasEmbeddedLUT() const{return m_impl->embeddedLUT!=nullptr;}
std::string SDKDecoder::EmbeddedLUTName() const {
    if(!m_impl->embeddedLUT)return {};
    CFStringRef name=nullptr;m_impl->embeddedLUT->GetName(&name);
    const auto result=Impl::FromCFString(name);if(name)CFRelease(name);return result;
}
bool SDKDecoder::ReadEmbeddedLUTCube(std::vector<uint8_t>& bytes) {
    bytes.clear();if(!m_impl->embeddedLUT)return false;
    char path[]="/tmp/braw-embedded-lut-XXXXXX";
    int fd=mkstemp(path);if(fd<0)return false;close(fd);
    auto file=CFStringCreateWithCString(nullptr,path,kCFStringEncodingUTF8);
    HRESULT result=m_impl->embeddedLUT->WriteCubeFile(file);CFRelease(file);
    if(SUCCEEDED(result)) {
        NSData* data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
        if(data.length && data.length<=WorkerProtocol::maxPayload)
            bytes.assign((const uint8_t*)data.bytes,(const uint8_t*)data.bytes+data.length);
    }
    unlink(path);
    if(bytes.empty())fprintf(stderr,"Could not extract embedded LUT: 0x%x\n",unsigned(result));
    return !bytes.empty();
}
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
