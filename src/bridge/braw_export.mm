#include "bridge/braw_api.h"
#include "core/Types.h"
#include "core/BrawDecoder.h"
#include "core/ChildProcess.h"
#include "core/ExportColorMetadata.h"
#include "core/QuickTimeMetadata.h"
#import <Foundation/Foundation.h>
#include <atomic>
#include <mutex>
#include <filesystem>
#include <fstream>
#include <unistd.h>
#include <stdio.h>
#include <cerrno>
#include <cstring>

static std::atomic<bool> g_running{false},g_cancel{false};
static std::mutex g_stateMutex;
static std::string g_error;
static bool g_prepared=false;
static void setError(const std::string& error){std::lock_guard lock(g_stateMutex);g_error=error;}
static std::string findFFmpeg() {
    std::vector<std::string> paths={SiblingExecutable("ffmpeg"),"/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg","/usr/bin/ffmpeg"};
    for(auto& path:paths)if(access(path.c_str(),X_OK)==0)return path;
    return {};
}
struct ClipOwner {
    BrawClipHandle* handle;
    explicit ClipOwner(BrawClipHandle* h):handle(h){}
    ~ClipOwner(){braw_clip_close(handle);}
};
struct TemporaryDirectory {
    std::filesystem::path path;
    ~TemporaryDirectory(){if(!path.empty()){std::error_code error;std::filesystem::remove_all(path,error);}}
};
static bool exportClip(BrawClipHandle* clip,int codec,int profile,int resolution,int bitrate,
    const std::string& output,ExportProgressFn progress,void* context,int clipIndex,int totalClips) {
    auto ffmpeg=findFFmpeg();if(ffmpeg.empty()){setError("The bundled video encoder is missing.");return false;}
    namespace fs=std::filesystem;
    fs::path final(output);
    std::string pattern=(final.parent_path()/".braw-export-XXXXXX").string();
    std::vector<char> writable(pattern.begin(),pattern.end());writable.push_back(0);
    char* temp=mkdtemp(writable.data());
    if(!temp){setError("Could not create temporary files in the output folder.");return false;}
    TemporaryDirectory dir{temp};
    BrawDecoder decoder;decoder.SetCancellation(&g_cancel);decoder.SetOutputFormat(1);
    if(!decoder.OpenClip(braw_clip_get_filepath(clip))){setError(decoder.LastError());return false;}
    auto settings=braw_clip_get_settings(clip);
    ClipAdjustments a;a.iso=settings.iso;a.colorTemp=settings.temperature;a.tint=settings.tint;
    a.exposure=settings.exposure;a.highlightRecovery=settings.highlightRecovery;
    // Camera LUT is a preview setting; preserve the original log image in exports.
    a.previewLUT=false;
    auto audio=decoder.GetAudioInfo();
    fs::path audioFile=dir.path/"audio.pcm";
    bool hasAudio=audio.rate&&audio.channels&&audio.samples;
    if(hasAudio) {
        if(audio.bits!=16&&audio.bits!=24&&audio.bits!=32){setError("Unsupported source PCM audio depth.");return false;}
        std::ofstream file(audioFile,std::ios::binary);
        if(!file){setError("Could not create temporary audio file.");return false;}
        for(uint64_t start=0;start<audio.samples;) {
            if(g_cancel.load())return false;
            uint32_t count=std::min<uint64_t>(65536,audio.samples-start);
            std::vector<uint8_t> bytes;
            if(!decoder.ReadAudio(start,count,bytes)||bytes.size()!=uint64_t(count)*audio.channels*(audio.bits/8)) {
                setError("Source audio could not be read: "+decoder.LastError());return false;
            }
            file.write((const char*)bytes.data(),bytes.size());
            if(!file){setError("Could not write temporary audio; check available disk space.");return false;}
            start+=count;
        }
    }
    int nativeWidth=decoder.GetWidth(),nativeHeight=decoder.GetHeight();
    int targetHeight=resolution==0?nativeHeight:(resolution<=2?2160:1080);
    int targetWidth=resolution==0?nativeWidth:CalculateOutputWidth(targetHeight,nativeWidth,nativeHeight);
    if(targetWidth%2||targetHeight%2){setError("Output dimensions must be even.");return false;}
    // Use the highest SDK reduction that still supplies enough pixels for the
    // requested output. Smaller exports need not decode full-resolution frames.
    float scale=1;
    if(targetHeight<=nativeHeight/8)scale=.125f;
    else if(targetHeight<=nativeHeight/4)scale=.25f;
    else if(targetHeight<=nativeHeight/2)scale=.5f;
    int width=0,height=0,firstStride=0;
    auto firstFrame=decoder.DecodeFrameSync(0,&width,&height,&firstStride,a,scale);
    if(firstFrame.empty()||firstStride!=width*6){setError("Could not decode the first export frame: "+decoder.LastError());return false;}
    fs::path partial=dir.path/"output.mov";
    std::vector<std::string> args={ffmpeg,"-hide_banner","-loglevel","error","-nostdin","-n",
        "-f","rawvideo","-pixel_format","rgb48le","-video_size",std::to_string(width)+"x"+std::to_string(height),
        "-framerate",std::to_string(decoder.GetFrameRate()),"-i","pipe:0"};
    if(hasAudio) {
        args.insert(args.end(),{"-f","s"+std::to_string(audio.bits)+"le","-ar",std::to_string(audio.rate),
            "-ac",std::to_string(audio.channels),"-i",audioFile.string(),"-map","0:v:0","-map","1:a:0","-c:a","pcm_s24le"});
    } else args.insert(args.end(),{"-an"});
    if(resolution!=0)args.insert(args.end(),{"-vf","scale="+std::to_string(targetWidth)+":"+std::to_string(targetHeight)});
    if(codec==0)args.insert(args.end(),{"-c:v","h264_videotoolbox","-tag:v","avc1","-pix_fmt","yuv420p","-b:v",std::to_string(bitrate)});
    else if(codec==1)args.insert(args.end(),{"-c:v","hevc_videotoolbox","-tag:v","hvc1","-pix_fmt","p010le","-b:v",std::to_string(bitrate)});
    else args.insert(args.end(),{"-c:v","prores_ks","-profile:v",std::to_string(profile),"-pix_fmt",profile>=4?"yuva444p10le":"yuv422p10le","-threads","4"});
    // Preserve the SDK-reported source encoding without mapping proprietary
    // Blackmagic gamuts or Film curves to unrelated standard NCLC code points.
    // Descriptive source values remain available for unsupported encodings.
    // Supported camera encodings also receive the vendor's QuickTime keys.
    const auto gamma=decoder.GetClipGamma();
    const auto gamut=decoder.GetClipGamut();
    const auto generation=decoder.GetColorScienceGen();
    const auto camera=decoder.GetCameraType();
    auto metadata=[&](const std::string& key,const std::string& value) {
        if(!value.empty())args.insert(args.end(),{"-metadata",key+"="+value});
    };
    metadata("com.brawtranscoder.source.gamma",gamma);
    metadata("com.brawtranscoder.source.gamut",gamut);
    metadata("com.brawtranscoder.source.camera_type",camera);
    if(generation)metadata("com.brawtranscoder.source.color_science_generation",std::to_string(generation));
    metadata("com.brawtranscoder.source.filename",fs::path(braw_clip_get_filepath(clip)).filename().string());
    for(const auto& [key,value]:BlackmagicFilmMetadata(gamma,gamut,generation,camera))
        metadata(key,value);
    if(!gamma.empty()||!gamut.empty()) {
        std::string description="Source BRAW: gamut="+gamut+"; gamma="+gamma;
        if(generation)description+="; color science generation="+std::to_string(generation);
        metadata("description",description);
    }
    args.insert(args.end(),{"-movflags","+faststart+use_metadata_tags",partial.string()});
    ChildProcess encoder;if(!encoder.Start(args,false)){setError(encoder.Error());return false;}
    uint64_t frames=decoder.GetFrameCount();
    for(uint64_t i=0;i<frames;i++) {
        if(g_cancel.load())return false;
        int w=0,h=0,stride=0;
        std::vector<uint8_t> pixels;
        if(i==0){pixels=std::move(firstFrame);w=width;h=height;stride=firstStride;}
        else pixels=decoder.DecodeFrameSync(i,&w,&h,&stride,a,scale);
        if(pixels.empty()||w!=width||h!=height||stride!=width*6){setError("Frame "+std::to_string(i)+" could not be decoded: "+decoder.LastError());return false;}
        if(!encoder.Write(pixels.data(),pixels.size(),30,&g_cancel)){setError(encoder.Error());return false;}
        if(progress)progress(clipIndex,totalClips,int(i+1),int(frames),context);
    }
    decoder.Close();encoder.CloseInput();
    if(!encoder.Wait(60,&g_cancel)){setError(encoder.Error());return false;}
    if(g_cancel.load())return false;
    // The partial file is on the same volume; atomically replace the destination
    // only after encoding succeeds, preserving the previous file on failure.
    std::string metadataError;
    if(!PromoteQuickTimeMetadata(partial.string(),metadataError)){setError(metadataError);return false;}
    if(g_cancel.load())return false;
    if(rename(partial.c_str(),final.c_str())!=0){setError("Could not publish output: "+output+" ("+std::strerror(errno)+").");return false;}
    return true;
}
extern "C" {
int braw_export_prepare() {
    std::lock_guard lock(g_stateMutex);
    if(g_running.load())return -1;
    g_cancel=false;g_error.clear();g_prepared=true;g_running=true;return 0;
}
int braw_export_start(BrawProjectHandle* project,const int* indices,int count,
    int codec,int profile,int resolution,int rate,const char* outputDir,ExportProgressFn progress,void* context) {
    {
        std::lock_guard lock(g_stateMutex);
        if(g_running.load()&&!g_prepared)return -1;
        if(!g_prepared){g_cancel=false;g_error.clear();g_running=true;}
        g_prepared=false;
    }
    struct RunningGuard {~RunningGuard(){g_running=false;}} running;
    if(!project||!indices||count<=0||codec<0||codec>2||profile<0||profile>5||resolution<0||resolution>4||rate<=0||rate>1000){setError("Invalid export settings.");return -1;}
    @autoreleasepool {
        std::vector<std::unique_ptr<ClipOwner>> clips;
        for(int i=0;i<count;i++) {
            auto* clip=braw_project_get_clip_retained(project,indices[i]);
            if(!clip){setError("A selected clip is no longer available.");return -1;}
            clips.push_back(std::make_unique<ClipOwner>(clip));
        }
        for(int i=0;i<count;i++) {
            if(g_cancel.load())return -2;
            auto* clip=clips[i]->handle;
            std::filesystem::path source(braw_clip_get_filepath(clip));
            std::filesystem::path folder=outputDir&&outputDir[0]?std::filesystem::path(outputDir):source.parent_path();
            auto output=(folder/(source.stem().string()+".mov")).string();
            if(!exportClip(clip,codec,profile,resolution,rate*1000000,output,progress,context,i,count))return g_cancel.load()?-2:-1;
        }
    }
    return g_cancel.load()?-2:0;
}
int braw_export_is_running(){return g_running.load();}
void braw_export_cancel(){std::lock_guard lock(g_stateMutex);if(g_running.load())g_cancel=true;}
void braw_export_reset(){std::lock_guard lock(g_stateMutex);if(!g_running.load())g_cancel=false;}
const char* braw_export_last_error(){static thread_local std::string error;std::lock_guard lock(g_stateMutex);error=g_error;return error.c_str();}
}
