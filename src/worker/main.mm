#include "worker/SDKDecoder.h"
#include "worker/Protocol.h"
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <cerrno>
using namespace WorkerProtocol;
static bool transfer(void* p,size_t size,bool writing) {
    auto* bytes=(uint8_t*)p;
    while(size){ssize_t n=writing?write(1,bytes,size):read(0,bytes,size);
        if(n<0&&errno==EINTR)continue;if(n<=0)return false;bytes+=n;size-=n;}return true;
}
static NSString* str(const std::string& s){return [NSString stringWithUTF8String:s.c_str()]?:@"";}
int main() {
    SDKDecoder decoder;
    while(true) { @autoreleasepool {
        Request request;
        if(!transfer(&request,sizeof(request),false))return 0;
        if(request.magicValue!=magic||request.size>65536)return 2;
        std::string path(request.size,'\0');
        if(request.size&&!transfer(path.data(),path.size(),false))return 2;
        Response response;std::vector<uint8_t> payload;
        if(request.command==Open) {
            if(decoder.Open(path,request.metal,request.format)) {
                auto audio=decoder.GetAudioInfo();
                NSMutableDictionary* metadata=[NSMutableDictionary dictionary];
                for(auto& [key,value]:decoder.GetFreeFormMetadata())metadata[str(key)]=str(value);
                NSMutableArray* isoList=[NSMutableArray array];
                for(auto iso:decoder.GetISOList())[isoList addObject:@(iso)];
                NSDictionary* info=@{
                    @"width":@(decoder.GetWidth()),@"height":@(decoder.GetHeight()),
                    @"fps":@(decoder.GetFrameRate()),@"frames":@(decoder.GetFrameCount()),
                    @"camera":str(decoder.GetCameraType()),@"gamma":str(decoder.GetClipGamma()),
                    @"gamut":str(decoder.GetClipGamut()),@"generation":@(decoder.GetColorScienceGen()),
                    @"iso":@(decoder.GetNativeISO()),@"temperature":@(decoder.GetNativeColorTemp()),
                    @"isoList":isoList,@"isoReadOnly":@(decoder.ISOIsReadOnly()),
                    @"tint":@(decoder.GetNativeTint()),@"exposure":@(decoder.GetNativeExposure()),
                    @"sdk":str(decoder.Version()),@"metadata":metadata,
                    @"audioRate":@(audio.rate),@"audioChannels":@(audio.channels),
                    @"audioBits":@(audio.bits),@"audioSamples":@(audio.samples)};
                NSData* data=[NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
                if(data){payload.assign((const uint8_t*)data.bytes,(const uint8_t*)data.bytes+data.length);response.status=0;}
            }
        } else if(request.command==Frame) {
            ClipAdjustments a;a.iso=request.iso;a.colorTemp=request.temperature;a.tint=request.tint;
            a.exposure=request.exposure;a.highlightRecovery=request.highlight;a.previewLUT=request.lut;
            SDKDecoder::Frame frame;
            if(decoder.Decode(request.index,a,request.scale,frame)) {
                response.status=0;response.width=frame.width;response.height=frame.height;
                response.stride=frame.stride;payload=std::move(frame.pixels);
            }
        } else if(request.command==Audio) {
            if(decoder.ReadAudio(request.index,request.count,payload))response.status=0;
        } else return 2;
        if(response.status!=0) {
            fprintf(stderr,"BRAW request failed: command=%u, index=%llu, scale=%.3f\n",
                request.command,request.index,request.scale);
            fflush(stderr);
        }
        response.size=payload.size();
        if(!transfer(&response,sizeof(response),true))return 0;
        if(!payload.empty()&&!transfer(payload.data(),payload.size(),true))return 0;
    }}
}
