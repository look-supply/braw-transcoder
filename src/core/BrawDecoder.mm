#include "core/BrawDecoder.h"
#include "core/ChildProcess.h"
#include "worker/Protocol.h"
#import <Foundation/Foundation.h>
using namespace WorkerProtocol;
struct BrawDecoder::Impl {
    ChildProcess child;
    std::string path,error,version,camera,gamma,gamut;
    std::map<std::string,std::string> metadata;
    uint32_t width=0,height=0,iso=0,temperature=0;
    std::vector<uint32_t> isoList;
    bool isoReadOnly=true;
    uint64_t frames=0;
    float fps=0,exposure=0;
    int16_t tint=0;
    uint16_t generation=0;
    AudioInfo audio;
    int format=0;
    bool metal=false;
    const std::atomic<bool>* cancel=nullptr;
    bool Exchange(const Request& request,const std::string& payload,Response& response,std::vector<uint8_t>& bytes) {
        if(!child.Write(&request,sizeof(request),30,cancel)||
           (!payload.empty()&&!child.Write(payload.data(),payload.size(),30,cancel))||
           !child.Read(&response,sizeof(response),30,cancel)) {error=child.Error();return false;}
        if(response.magicValue!=magic||response.size>maxPayload||response.status!=0) {
            const std::string operation=request.command==Open?"opening source clip "+path+" on "+(request.metal?"Metal":"CPU"):
                request.command==Frame?"decoding frame "+std::to_string(request.index):
                "reading audio at sample "+std::to_string(request.index);
            if(response.magicValue!=magic)error="Invalid decoder response while "+operation+" (protocol mismatch).";
            else if(response.size>maxPayload)error="Decoder response exceeded the "+std::to_string(maxPayload/1048576)+" MiB frame limit while "+operation+".";
            else error="Blackmagic RAW SDK failed while "+operation+" (worker status "+std::to_string(response.status)+").";
            const auto detail=child.Error();
            if(!detail.empty())error+='\n'+detail;
            child.Stop();return false;
        }
        bytes.resize(response.size);
        if(!bytes.empty()&&!child.Read(bytes.data(),bytes.size(),30,cancel)){error=child.Error();return false;}
        return true;
    }
    bool Start(bool useMetal) {
        if(!child.Start({SiblingExecutable("braw_worker")},true)){error=child.Error();return false;}
        Request r;r.command=Open;r.size=path.size();r.metal=useMetal;r.format=format;
        Response result;std::vector<uint8_t> bytes;
        if(!Exchange(r,path,result,bytes))return false;
        NSData* data=[NSData dataWithBytes:bytes.data() length:bytes.size()];
        id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![object isKindOfClass:[NSDictionary class]]){error="Invalid decoder metadata";child.Stop();return false;}
        NSDictionary* info=object;
        width=[info[@"width"] unsignedIntValue];height=[info[@"height"] unsignedIntValue];
        frames=[info[@"frames"] unsignedLongLongValue];fps=[info[@"fps"] floatValue];
        iso=[info[@"iso"] unsignedIntValue];temperature=[info[@"temperature"] unsignedIntValue];
        isoList.clear();for(NSNumber* value in info[@"isoList"])if(value.unsignedIntValue)isoList.push_back(value.unsignedIntValue);
        isoReadOnly=info[@"isoReadOnly"]?[info[@"isoReadOnly"] boolValue]:true;
        if(isoList.empty()){isoList={iso};isoReadOnly=true;}
        tint=[info[@"tint"] shortValue];exposure=[info[@"exposure"] floatValue];
        generation=[info[@"generation"] unsignedShortValue];
        version=[info[@"sdk"] UTF8String]?:"";camera=[info[@"camera"] UTF8String]?:"";
        gamma=[info[@"gamma"] UTF8String]?:"";gamut=[info[@"gamut"] UTF8String]?:"";
        metadata.clear();for(NSString* key in info[@"metadata"])metadata[key.UTF8String]=[info[@"metadata"][key] UTF8String];
        audio.rate=[info[@"audioRate"] unsignedIntValue];audio.channels=[info[@"audioChannels"] unsignedIntValue];
        audio.bits=[info[@"audioBits"] unsignedIntValue];audio.samples=[info[@"audioSamples"] unsignedLongLongValue];
        if(!width||!height||!frames||fps<=0){error="Clip has no valid video";child.Stop();return false;}
        metal=useMetal;error.clear();return true;
    }
};
BrawDecoder::BrawDecoder():m_impl(std::make_unique<Impl>()){}
BrawDecoder::~BrawDecoder(){Close();}
bool BrawDecoder::OpenClip(const std::string& path) {
    Close();m_impl->path=path;
    const char* pipeline=getenv("BRAW_DECODE_PIPELINE");
    bool metal=!pipeline||std::string(pipeline)!="cpu";
    if(m_impl->Start(metal))return true;
    if(metal&&!(m_impl->cancel&&m_impl->cancel->load())) {
        fprintf(stderr,"Metal decoder failed; retrying CPU: %s\n",m_impl->error.c_str());
        return m_impl->Start(false);
    }
    m_impl->child.Stop();return false;
}
void BrawDecoder::Close(){m_impl->child.Stop();m_impl->width=0;m_impl->height=0;}
#define GET(type,name,field) type BrawDecoder::name() const{return m_impl->field;}
GET(uint32_t,GetWidth,width) GET(uint32_t,GetHeight,height) GET(float,GetFrameRate,fps)
GET(uint64_t,GetFrameCount,frames) GET(std::string,GetCameraType,camera)
GET(uint32_t,GetNativeISO,iso) GET(uint32_t,GetNativeColorTemp,temperature)
GET(int16_t,GetNativeTint,tint) GET(float,GetNativeExposure,exposure)
GET(std::string,GetClipGamma,gamma) GET(std::string,GetClipGamut,gamut)
GET(uint16_t,GetColorScienceGen,generation) GET(std::string,LastError,error)
GET(std::string,SDKVersion,version) GET(bool,UsingMetal,metal)
GET(bool,ISOIsReadOnly,isoReadOnly)
#undef GET
std::map<std::string,std::string> BrawDecoder::GetFreeFormMetadata() const{return m_impl->metadata;}
std::vector<uint32_t> BrawDecoder::GetISOList(){return m_impl->isoList;}
void BrawDecoder::SetOutputFormat(int format){m_impl->format=format;}
void BrawDecoder::SetCancellation(const std::atomic<bool>* cancel){m_impl->cancel=cancel;}
void BrawDecoder::SetCustomLUT(const std::string&){m_impl->error="Custom LUT files are not supported";}
void BrawDecoder::CaptureNativeSettings(){} // Included in the worker's open response.
void BrawDecoder::FlushJobs(){} // IPC responses arrive only after a completed request.
void BrawDecoder::RequestFrame(uint64_t index,const ClipAdjustments& a,FrameCallback callback,float scale) {
    auto& p=*m_impl;if(index>=p.frames||!p.width){p.error="Frame index is out of range";return;}
    if(p.cancel&&p.cancel->load()){p.error="Cancelled";return;}
    if(a.iso&&((p.isoReadOnly&&a.iso!=p.iso)||std::find(p.isoList.begin(),p.isoList.end(),a.iso)==p.isoList.end())) {
        p.error="ISO "+std::to_string(a.iso)+" is not supported by this clip's recorded analog gain. Use a listed ISO or adjust Exposure.";return;
    }
    Request request;request.command=Frame;request.index=index;request.iso=a.iso;
    request.temperature=a.colorTemp;request.tint=a.tint;request.exposure=a.exposure;
    request.scale=scale;request.highlight=a.highlightRecovery;request.lut=a.previewLUT;
    Response response;std::vector<uint8_t> pixels;
    bool ok=p.Exchange(request,{},response,pixels);
    if(!ok&&p.metal&&!(p.cancel&&p.cancel->load())) {
        fprintf(stderr,"Metal worker failed; retrying frame on CPU: %s\n",p.error.c_str());
        ok=p.Start(false)&&p.Exchange(request,{},response,pixels);
    }
    if(!ok)return;
    uint64_t row=uint64_t(response.width)*(p.format==1?6:4);
    if(!response.width||!response.height||response.stride<row||
       uint64_t(response.stride)*response.height!=pixels.size()) {
        p.error="Invalid frame received from decoder";p.child.Stop();return;
    }
    // Return tightly packed rows to every consumer; SDK row alignment is internal.
    if(response.stride!=row) {
        std::vector<uint8_t> packed(row*response.height);
        for(uint32_t y=0;y<response.height;y++)memcpy(packed.data()+y*row,pixels.data()+y*response.stride,row);
        pixels=std::move(packed);
    }
    p.error.clear();
    if(callback)callback(pixels.data(),response.width,response.height,row);
}
std::vector<uint8_t> BrawDecoder::DecodeFrameSync(uint64_t index,int* w,int* h,int* stride,const ClipAdjustments& a,float scale) {
    std::vector<uint8_t> out;RequestFrame(index,a,[&](const uint8_t* p,int width,int height,int row){
        *w=width;*h=height;*stride=row;out.assign(p,p+size_t(row)*height);},scale);return out;
}
void BrawDecoder::DecodeFramesCPUBatch(uint64_t start,uint64_t end,const ClipAdjustments& a,FrameCallback cb,int) {
    for(uint64_t i=start;i<end;i++){RequestFrame(i,a,cb);if(!m_impl->error.empty())return;}
}
BrawDecoder::AudioInfo BrawDecoder::GetAudioInfo() const{return m_impl->audio;}
bool BrawDecoder::GetAudioFormat(uint32_t* rate,uint32_t* channels){*rate=m_impl->audio.rate;*channels=m_impl->audio.channels;return *rate&&*channels&&m_impl->audio.samples;}
bool BrawDecoder::ReadAudio(uint64_t start,uint32_t count,std::vector<uint8_t>& bytes) {
    Request r;r.command=Audio;r.index=start;r.count=count;Response response;
    return m_impl->Exchange(r,{},response,bytes);
}
float* BrawDecoder::ExtractAudio(uint32_t* rate,uint32_t* channels,uint64_t* samples) {
    // Legacy whole-buffer API is bounded; exports use ReadAudio in chunks.
    *rate=0;*channels=0;*samples=0;auto info=m_impl->audio;
    uint64_t floats=info.samples*info.channels;
    if(!info.samples||!info.channels||floats>16*1024*1024||info.bits!=24){m_impl->error="Audio requires chunked extraction";return nullptr;}
    std::vector<uint8_t> raw;std::vector<float> converted;converted.reserve(floats);
    for(uint64_t start=0;start<info.samples;) {
        uint32_t count=std::min<uint64_t>(65536,info.samples-start);
        if(!ReadAudio(start,count,raw))return nullptr;
        for(size_t i=0;i+2<raw.size();i+=3){int32_t n=int32_t(uint32_t(raw[i])|(uint32_t(raw[i+1])<<8)|(uint32_t(raw[i+2])<<16));if(n&0x800000)n|=0xff000000;converted.push_back(n/8388608.f);}
        start+=count;
    }
    float* out=(float*)malloc(converted.size()*sizeof(float));if(!out)return nullptr;
    memcpy(out,converted.data(),converted.size()*sizeof(float));*rate=info.rate;*channels=info.channels;*samples=info.samples;return out;
}
BrawDecoder::GyroData BrawDecoder::ExtractGyroData(){m_impl->error="Gyro sidecar export is not implemented";return {};}
