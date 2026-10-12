#include "bridge/braw_api.h"
#include "core/BrawDecoder.h"
#include "core/ChildProcess.h"
#include "core/ExportEncoderError.h"
#include "core/ExportAudio.h"
#include "worker/Protocol.h"
#include <Accelerate/Accelerate.h>
#include <chrono>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <thread>
#include <stdexcept>
#include <cstdio>
#include <cstring>
#include <signal.h>
#include <unistd.h>
namespace fs=std::filesystem;
static void require(bool ok,const std::string& message){if(!ok)throw std::runtime_error(message);}
static std::string temporary(){char path[]="/tmp/braw-reliability-XXXXXX";char* p=mkdtemp(path);require(p,"mkdtemp failed");return p;}
struct Directory{std::string path=temporary();~Directory(){std::error_code e;fs::remove_all(path,e);}};
static void resolutionDimensions() {
    struct Case { int mode, w, h, expectedW, expectedH; };
    const Case cases[] = {
        {5,12288,6480,8192,4320}, {6,12288,6480,6144,3240},
        {6,6144,2592,6144,2592}, {6,4096,2304,4096,2304}, {5,7680,3204,7680,3204},
        {5,6144,3456,6144,3456}, {5,6048,4032,6048,4032},
        {5,1920,1080,1920,1080}, {1,1920,1080,1920,1080},
        {3,640,480,640,480}, {1,5184,2160,5184,2160},
        {1,12288,6480,4096,2160}, {3,12288,6480,2048,1080},
        {5,6480,12288,2278,4320}, {0,12288,6480,12288,6480},
        {2,12288,6480,4096,2160}, {4,12288,6480,2048,1080}
    };
    for (const auto& c : cases) {
        int w=0,h=0;
        require(braw_export_dimensions(c.mode,c.w,c.h,&w,&h),"Resolution calculation failed");
        require(w==c.expectedW && h==c.expectedH,"Unexpected output dimensions");
        require(w<=c.w && h<=c.h,"Export would upscale");
        require(std::abs(double(w)-double(c.w)*h/c.h)<=1.0,"Aspect ratio changed beyond pixel rounding");
    }
    int w=0,h=0;
    require(!braw_export_dimensions(7,1920,1080,&w,&h),"Invalid mode accepted");
    require(!braw_export_dimensions(5,0,1080,&w,&h),"Invalid source accepted");
    puts("PASS: 4320/2160/1080 ceilings, original sizes, aspect ratio, legacy modes, and no upscaling");
}
static void processes() {
    resolutionDimensions();
    {
        BrawDecoder decoder;
        require(!decoder.OpenClip("/missing.braw"),"Missing source accepted");
        const auto error=decoder.LastError();
        require(error.find("opening source clip /missing.braw")!=std::string::npos&&
                error.find("worker status")!=std::string::npos&&error.find("OpenClip failed")!=std::string::npos,
                "Source-open failure omitted operation or SDK detail: "+error);
    }
    const auto unsupported=ExportEncoderError(1,17520,8040,"Processing worker exited or closed its channel\nCannot prepare encoder: -12902");
    require(unsupported.find("17520 × 8040")!=std::string::npos&&unsupported.find("Choose a smaller height preset")!=std::string::npos&&unsupported.find("full resolution")!=std::string::npos,"Missing actionable encoder initialization error");
    require(ExportEncoderError(1,4096,2160,"Cancelled").find("unsupported")==std::string::npos,"Cancellation reported as unsupported dimensions");
    auto exe=SiblingExecutable("braw_reliability_test");char byte;
    {
        ChildProcess p;require(p.Start({exe,"--hang"},true),p.Error());auto pid=p.PID();
        require(!p.Read(&byte,1,1),"Hung child did not time out");
        require(p.Reason().find("timed out")!=std::string::npos,p.Error());
        require(kill(pid,0)<0,"Timed-out child still exists");
    }
    {
        ChildProcess p;require(p.Start({exe,"--crash"},true),p.Error());
        require(!p.Read(&byte,1),"Crashed child accepted");
    }
    {
        ChildProcess p;require(p.Start({exe,"--allocate"},true,32*1024*1024),p.Error());
        require(!p.Read(&byte,1,5),"Memory-heavy child accepted");
        require(p.Reason().find("memory budget")!=std::string::npos,p.Error());
    }
    {
        ChildProcess p;std::atomic<bool> cancelled{true};require(p.Start({exe,"--hang"},true),p.Error());
        require(!p.Read(&byte,1,5,&cancelled),"Cancelled child accepted");require(p.Reason()=="Cancelled",p.Error());
    }
    puts("PASS: child crash, deadline, memory cutoff, cancellation, and reaping");
}
static void native(const char* sample) {
    Directory dir;
    auto* project=braw_project_create();require(project,"Project creation failed");
    require(braw_project_import(project,"/missing.braw")==-1,"Invalid media was accepted");
    require(braw_project_import(project,sample)==0,"Sample import failed");
    auto* clip=braw_project_get_clip_retained(project,0);require(clip,"No retained clip");
    int index=0;
    require(braw_export_prepare()==0,"Could not reserve export");
    braw_export_cancel();braw_export_reset();
    require(braw_export_is_running(),"Cancellation unlocked export early");
    int result=braw_export_start(project,&index,1,1,3,4,100,dir.path.c_str(),nullptr,nullptr);
    require(result==-2,"Cancellation before background work was lost");
    require(!braw_export_is_running(),"Cancelled export still running");
    require(!fs::exists(fs::path(dir.path)/"sample.mov"),"Cancelled export published output");
    // Keep the previous output intact until a replacement succeeds.
    auto output=fs::path(dir.path)/(fs::path(sample).stem().string()+".mov");
    {std::ofstream file(output);file<<"sentinel";}
    require(braw_export_start(project,&index,1,1,3,4,0,dir.path.c_str(),nullptr,nullptr)==-1,"Invalid export accepted");
    require(std::string(braw_export_last_error()).find("Invalid export settings")!=std::string::npos,"Missing export error");
    {std::ifstream file(output);std::string s;file>>s;require(s=="sentinel","Existing output changed");}
    struct CancelContext {bool signalled=false;};CancelContext context;
    result=braw_export_start(project,&index,1,2,0,4,100,dir.path.c_str(),
        [](int,int,int frame,int,void* raw){if(frame>=1){static_cast<CancelContext*>(raw)->signalled=true;braw_export_cancel();}},&context);
    require(context.signalled&&result==-2,"Cancellation during streaming failed: "+std::string(braw_export_last_error()));
    {std::ifstream file(output);std::string s;file>>s;require(s=="sentinel","Interrupted export changed existing output");}
    require(std::distance(fs::directory_iterator(dir.path),fs::directory_iterator{})==1,"Interrupted export left temporary files");
    // Cancellation must not poison the next run. Test a software codec as well.
    require(braw_export_start(project,&index,1,2,0,4,100,dir.path.c_str(),nullptr,nullptr)==0,
        "Restart export failed: "+std::string(braw_export_last_error()));
    require(fs::file_size(output)>1024,"Restart output is empty");
    require(std::distance(fs::directory_iterator(dir.path),fs::directory_iterator{})==1,"Successful replacement left temporary files");
    // A late publication failure must preserve a conflicting directory and
    // clean up the already encoded temporary MOV.
    fs::remove(output);fs::create_directory(output);
    {std::ofstream file(output/"sentinel");file<<"preserved";}
    require(braw_export_start(project,&index,1,2,0,4,100,dir.path.c_str(),nullptr,nullptr)==-1,"Conflicting directory accepted");
    require(std::string(braw_export_last_error()).find("Could not publish output")!=std::string::npos,"Missing publication error");
    require(fs::exists(output/"sentinel"),"Failed publication changed destination");
    require(std::distance(fs::directory_iterator(dir.path),fs::directory_iterator{})==1,"Failed publication left temporary files");
    braw_project_destroy(project);
    int w=0,h=0;auto* pixels=braw_clip_decode_frame_scaled(clip,0,&w,&h,.125f);
    require(pixels&&w>0&&h>0,"Retained clip died with its project");braw_clip_free_frame(pixels);
    require(!braw_clip_decode_frame(clip,UINT64_MAX,&w,&h),"Out-of-range frame accepted");
    std::atomic<bool> done=false;std::atomic<bool> decoded=false;
    std::thread thread([&]{int width=0,height=0;auto* p=braw_clip_decode_frame_scaled(clip,0,&width,&height,.25f);
        decoded=p!=nullptr;if(p)braw_clip_free_frame(p);done=true;});
    while(!done.load()){braw_clip_set_exposure(clip,.5f);braw_clip_set_tint(clip,0);}
    thread.join();require(decoded,"Concurrent adjustment update broke decoding");
    braw_clip_close(clip);
    require(ChildProcess::ChildrenMemory()==0,"Children leaked after teardown");
    puts("PASS: invalid media, retained handles, cancellation, restart, automatic overwrite, failure preservation, cleanup");
}
static void stress(const char* pipeline,const char* path,int count,int format=0,float scale=1) {
    bool defaultPipeline=std::string(pipeline)=="default";
    if(defaultPipeline)unsetenv("BRAW_DECODE_PIPELINE");
    else setenv("BRAW_DECODE_PIPELINE",pipeline,1);
    bool wantsMetal=std::string(pipeline)!="cpu";
    BrawDecoder decoder;decoder.SetOutputFormat(format);
    require(decoder.OpenClip(path),decoder.LastError());
    require(decoder.UsingMetal()==wantsMetal,"Requested pipeline fell back during open");
    printf("SDK %s; %s; %ux%u; %llu source frames; %d decode requests\n",decoder.SDKVersion().c_str(),pipeline,
        decoder.GetWidth(),decoder.GetHeight(),decoder.GetFrameCount(),count);
    ClipAdjustments a;a.iso=decoder.GetNativeISO();a.colorTemp=decoder.GetNativeColorTemp();a.tint=decoder.GetNativeTint();
    uint64_t peak=0;int expectedWidth=0,expectedHeight=0;auto start=std::chrono::steady_clock::now();
    for(int i=0;i<count;i++) {
        int w=0,h=0,stride=0;auto bytes=decoder.DecodeFrameSync(i%decoder.GetFrameCount(),&w,&h,&stride,a,scale);
        require(!bytes.empty(),decoder.LastError());
        require(decoder.UsingMetal()==wantsMetal,"Requested Metal pipeline failed and fell back to CPU");
        if(i==0) {
            expectedWidth=w;expectedHeight=h;
            printf("Decoded dimensions %dx%d at requested SDK scale %f\n",w,h,scale);
            if(scale==1) require(w==int(decoder.GetWidth())&&h==int(decoder.GetHeight()),"Native frame dimensions changed");
            else require(w>0&&h>0&&w<int(decoder.GetWidth())&&h<int(decoder.GetHeight()),"SDK reduction did not reduce dimensions");
        }
        // SDK reduction dimensions vary by sensor; a 17K clip returns 1/6
        // dimensions for its Eighth mode. Validate the actual frame layout.
        require(w==expectedWidth&&h==expectedHeight&&stride==w*(format==1?6:4),"Unexpected frame layout");
        peak=std::max(peak,ChildProcess::ChildrenMemory());
        if((i+1)%50==0)printf("%d frames; child %.0f MiB; peak %.0f MiB\n",i+1,ChildProcess::ChildrenMemory()/1048576.,peak/1048576.);
    }
    printf("PASS: %.1f seconds; peak child footprint %.0f MiB; shared budget %.0f MiB\n",
        std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count(),peak/1048576.,ChildProcess::MemoryBudget()/1048576.);
}
// Deliberately bypass normal worker recycling to test the SDK's own lifetime.
// ChildProcess still enforces the same memory budget and operation deadlines.
static void singleWorkerStress(const char* path) {
    using namespace WorkerProtocol;
    BrawDecoder metadata;
    require(metadata.OpenClip(path),metadata.LastError());
    auto frames=metadata.GetFrameCount();
    auto width=metadata.GetWidth(),height=metadata.GetHeight();
    Request request;
    request.command=Open;request.metal=true;request.format=1;
    request.size=strlen(path);
    auto iso=metadata.GetNativeISO(),temperature=metadata.GetNativeColorTemp();
    auto tint=metadata.GetNativeTint();
    metadata.Close();
    ChildProcess worker;
    require(worker.Start({SiblingExecutable("braw_worker")},true),worker.Error());
    auto exchange=[&](const Request& command,const char* payload) {
        require(worker.Write(&command,sizeof(command)),worker.Error());
        if(command.size)require(worker.Write(payload,command.size),worker.Error());
        Response response;
        require(worker.Read(&response,sizeof(response)),worker.Error());
        require(response.magicValue==magic&&response.status==0&&response.size<=maxPayload,"Invalid worker response: "+worker.Error());
        std::vector<uint8_t> bytes(response.size);
        if(response.size)require(worker.Read(bytes.data(),bytes.size()),worker.Error());
        return response;
    };
    exchange(request,path);
    request={};request.command=Frame;request.iso=iso;request.temperature=temperature;request.tint=tint;
    request.scale=1;request.lut=false;
    uint64_t peak=0;auto start=std::chrono::steady_clock::now();
    for(uint64_t i=0;i<frames;i++) {
        request.index=i;
        auto response=exchange(request,nullptr);
        require(response.width==width&&response.height==height&&response.stride==width*6,"Unexpected full-resolution RGB16 layout");
        peak=std::max(peak,ChildProcess::ChildrenMemory());
        if(i==0||(i+1)%500==0||i+1==frames)printf("Single Metal worker: %llu/%llu full-resolution frames; child %.0f MiB; peak %.0f MiB\n",
            i+1,frames,ChildProcess::ChildrenMemory()/1048576.,peak/1048576.);
    }
    printf("PASS: unrecycled Metal SDK worker, %.1f seconds, peak %.0f MiB\n",
        std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count(),peak/1048576.);
}
static void highlightPreview(const char* path) {
    BrawDecoder decoder;
    require(decoder.OpenClip(path),decoder.LastError());
    ClipAdjustments a;
    a.iso=decoder.GetNativeISO();a.colorTemp=decoder.GetNativeColorTemp();a.tint=decoder.GetNativeTint();
    a.previewLUT=false;a.highlightRecovery=true;
    int w=0,h=0,stride=0;
    auto full=decoder.DecodeFrameSync(0,&w,&h,&stride,a,1);
    require(!full.empty(),decoder.LastError());
    vImage_Buffer source{full.data(),size_t(h),size_t(w),size_t(stride)};
    auto preview=decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f);
    require(!preview.empty(),decoder.LastError());
    std::vector<uint8_t> reference(preview.size());
    vImage_Buffer dest{reference.data(),size_t(h),size_t(w),size_t(stride)};
    require(vImageScale_ARGB8888(&source,&dest,nullptr,kvImageHighQualityResampling)==kvImageNoError,"Reference resize failed");
    require(preview==reference,"Recovery preview differs from resized native-resolution decode");
    printf("PASS: recovery preview matches native-resolution recovery resized to %dx%d (%s)\n",w,h,decoder.UsingMetal()?"Metal":"CPU");
}
static void lutToggle(const char* path) {
    BrawDecoder decoder;
    require(decoder.OpenClip(path),decoder.LastError());
    ClipAdjustments a;
    a.iso=decoder.GetNativeISO();a.colorTemp=decoder.GetNativeColorTemp();a.tint=decoder.GetNativeTint();
    int w=0,h=0,stride=0;
    a.previewLUT=false;
    auto off=decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f);
    require(!off.empty(),decoder.LastError());
    a.previewLUT=true;
    auto on=decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f);
    require(!on.empty(),decoder.LastError());
    a.previewLUT=false;
    auto offAgain=decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f);
    require(!offAgain.empty(),decoder.LastError());
    require(off!=on,"Embedded LUT toggle did not change decoded pixels");
    require(off==offAgain,"Disabling LUT did not restore original pixels");
    printf("PASS: embedded LUT off/on/off changes pixels and restores ungraded preview (%dx%d, %s)\n",w,h,decoder.UsingMetal()?"Metal":"CPU");
}
static void resolutionExport(const char* sample) {
    Directory dir;
    auto* project=braw_project_create();
    require(braw_project_import(project,sample)==0,"Resolution fixture import failed");
    auto* clip=braw_project_get_clip(project,0);
    require(braw_clip_get_frame_count(clip)==1,"Use a one-frame resolution fixture");
    for (int codec : {1,2}) for (int mode : {5,6,3}) {
        auto folder=fs::path(dir.path)/(std::to_string(codec)+"-"+std::to_string(mode));
        fs::create_directory(folder);int index=0;
        require(braw_export_start(project,&index,1,codec,3,mode,100,folder.c_str(),nullptr,nullptr)==0,
                "Resolution export failed: "+std::string(braw_export_last_error()));
        auto output=folder/(fs::path(sample).stem().string()+".mov");
        auto bitmap=folder/"frame.bmp";
        ChildProcess ffmpeg;
        require(ffmpeg.Start({SiblingExecutable("ffmpeg"),"-hide_banner","-loglevel","error","-threads","2",
                "-i",output.string(),"-frames:v","1","-c:v","bmp",bitmap.string()},false),ffmpeg.Error());
        ffmpeg.CloseInput();require(ffmpeg.Wait(30),ffmpeg.Error());
        std::ifstream file(bitmap,std::ios::binary);char header[26]{};file.read(header,sizeof(header));
        int32_t w=0,h=0;memcpy(&w,header+18,4);memcpy(&h,header+22,4);
        int expectedW=0,expectedH=0;
        require(braw_export_dimensions(mode,braw_clip_get_width(clip),braw_clip_get_height(clip),&expectedW,&expectedH),"Bad dimensions");
        require(w==expectedW&&std::abs(h)==expectedH,"Encoded dimensions differ from displayed dimensions");
        printf("PASS: %s mode %d encoded %d × %d\n",codec==1?"HEVC":"ProRes",mode,w,std::abs(h));
    }
    braw_project_destroy(project);
}
static std::vector<uint8_t> readBytes(const fs::path& path) {
    std::ifstream file(path,std::ios::binary);
    require(bool(file),"Cannot read "+path.string());
    return {std::istreambuf_iterator<char>(file),std::istreambuf_iterator<char>()};
}
static void verifyAudio(const fs::path& mov,const fs::path& folder,const std::vector<uint8_t>& source,
                        uint32_t channels,uint32_t rate,uint32_t bits) {
    auto raw=folder/"decoded.pcm",wave=folder/"decoded.wav";
    const auto format="s"+std::to_string(bits)+"le";
    for (bool wav : {false,true}) {
        ChildProcess ffmpeg;
        require(ffmpeg.Start({SiblingExecutable("ffmpeg"),"-hide_banner","-loglevel","error","-i",mov.string(),
                "-map","0:a:0","-c:a","copy","-f",wav?"wav":format,(wav?wave:raw).string()},false),ffmpeg.Error());
        ffmpeg.CloseInput();require(ffmpeg.Wait(30),ffmpeg.Error());
    }
    require(readBytes(raw)==source,"Audio sample bytes changed or channels dropped/reordered");
    auto wav=readBytes(wave);bool found=false;
    auto u16=[&](size_t i){return uint32_t(wav[i])|(uint32_t(wav[i+1])<<8);};
    auto u32=[&](size_t i){return u16(i)|(u16(i+2)<<16);};
    for (size_t i=12;i+8<=wav.size();) {
        const uint32_t size=u32(i+4);
        if (memcmp(wav.data()+i,"fmt ",4)==0) {
            require(size>=16&&i+8+size<=wav.size(),"Invalid WAV format");
            require(u16(i+10)==channels&&u32(i+12)==rate&&u16(i+22)==bits,"MOV audio format differs from source");
            found=true;break;
        }
        i+=8+uint64_t(size)+(size&1);
    }
    require(found,"Missing audio format");
}
static void multichannelAudio(const char* sample) {
    Directory dir;
    for (uint32_t channels : {1u,2u,4u,8u,16u}) for (uint32_t bits : {16u,24u,32u}) {
        auto folder=fs::path(dir.path)/(std::to_string(channels)+"-"+std::to_string(bits));fs::create_directory(folder);
        std::vector<uint8_t> pcm;
        // Different signed sample patterns in every channel, including the low
        // bits of 32-bit PCM, expose remixing, reordering and bit-depth loss.
        for (uint32_t frame=0;frame<2400;frame++) for(uint32_t channel=0;channel<channels;channel++) {
            uint32_t value=(frame*7919+channel*104729)^0xa5a5a5a5;
            for(uint32_t byte=0;byte<bits/8;byte++)pcm.push_back(uint8_t(value>>(byte*8)));
        }
        auto audio=folder/"source.pcm";
        {std::ofstream file(audio,std::ios::binary);file.write((const char*)pcm.data(),pcm.size());}
        auto mov=folder/"output.mov";
        std::vector<std::string> args={SiblingExecutable("ffmpeg"),"-hide_banner","-loglevel","error",
            "-f","rawvideo","-pixel_format","rgb24","-video_size","64x64","-framerate","24","-i","pipe:0"};
        auto audioArgs=ExportAudioArguments(48000,channels,bits,audio.string());args.insert(args.end(),audioArgs.begin(),audioArgs.end());
        args.insert(args.end(),{"-c:v","prores_ks","-profile:v","0","-pix_fmt","yuv422p10le","-threads","1",mov.string()});
        ChildProcess ffmpeg;require(ffmpeg.Start(args,false),ffmpeg.Error());std::vector<uint8_t> frame(64*64*3);
        require(ffmpeg.Write(frame.data(),frame.size()),ffmpeg.Error());ffmpeg.CloseInput();require(ffmpeg.Wait(30),ffmpeg.Error());
        verifyAudio(mov,folder,pcm,channels,48000,bits);
        printf("PASS: %u-channel %u-bit MOV audio is byte-identical\n",channels,bits);
    }
    BrawDecoder decoder;require(decoder.OpenClip(sample),decoder.LastError());auto info=decoder.GetAudioInfo();
    require(info.samples&&info.channels,"Real BRAW fixture has no audio");std::vector<uint8_t> source;
    for(uint64_t start=0;start<info.samples;) {
        uint32_t count=std::min<uint64_t>(65536,info.samples-start);std::vector<uint8_t> chunk;
        require(decoder.ReadAudio(start,count,chunk),decoder.LastError());source.insert(source.end(),chunk.begin(),chunk.end());start+=count;
    }
    decoder.Close();auto* project=braw_project_create();require(braw_project_import(project,sample)==0,"Audio fixture import failed");
    for (int codec : {0,1,2}) {
        auto folder=fs::path(dir.path)/("real-braw-"+std::to_string(codec));fs::create_directory(folder);int index=0;
        require(braw_export_start(project,&index,1,codec,0,3,100,folder.c_str(),nullptr,nullptr)==0,braw_export_last_error());
        verifyAudio(folder/(fs::path(sample).stem().string()+".mov"),folder,source,info.channels,info.rate,info.bits);
        printf("PASS: real BRAW exported PCM matches SDK audio exactly (codec %d)\n",codec);
    }
    braw_project_destroy(project);
}
int main(int argc,char** argv) {
    setvbuf(stdout,nullptr,_IOLBF,0);
    if(argc>1&&std::string(argv[1])=="--hang"){while(true)pause();}
    if(argc>1&&std::string(argv[1])=="--crash")_exit(17);
    if(argc>1&&std::string(argv[1])=="--allocate"){std::vector<uint8_t> memory(128*1024*1024,42);while(true)pause();}
    try {
        if(argc>1&&std::string(argv[1])=="--multichannel-audio") {
            require(argc==3,"Usage: --multichannel-audio clip-with-audio");multichannelAudio(argv[2]);return 0;
        }
        if(argc>1&&std::string(argv[1])=="--resolution-export") {
            require(argc==3,"Usage: --resolution-export one-frame-clip");resolutionExport(argv[2]);return 0;
        }
        if(argc>1&&std::string(argv[1])=="--highlight-preview") {
            require(argc==3,"Usage: --highlight-preview clip");highlightPreview(argv[2]);return 0;
        }
        if(argc>1&&std::string(argv[1])=="--lut") {
            require(argc==3,"Usage: --lut clip-with-embedded-LUT");lutToggle(argv[2]);return 0;
        }
        if(argc>1&&std::string(argv[1])=="--audio") {
            require(argc==4,"Usage: --audio clip output-PCM-file");
            BrawDecoder decoder;require(decoder.OpenClip(argv[2]),decoder.LastError());
            auto audio=decoder.GetAudioInfo();require(audio.bits==24&&audio.samples>0,"Expected 24-bit source audio");
            std::ofstream output(argv[3],std::ios::binary);require(bool(output),"Cannot create audio output");
            for(uint64_t i=0;i<audio.samples;) {
                uint32_t count=std::min<uint64_t>(65536,audio.samples-i);
                std::vector<uint8_t> bytes;require(decoder.ReadAudio(i,count,bytes),decoder.LastError());
                output.write(reinterpret_cast<const char*>(bytes.data()),bytes.size());require(bool(output),"Audio write failed");
                i+=count;
            }
            printf("PASS: extracted %llu source audio samples\n",audio.samples);return 0;
        }
        if(argc>1&&std::string(argv[1])=="--single-worker") {
            require(argc==3,"Usage: --single-worker clip");singleWorkerStress(argv[2]);return 0;
        }
        if(argc>1&&std::string(argv[1])=="--stress") {
            require(argc>=5&&argc<=7,"Usage: --stress cpu|metal|default clip count [format: 0=BGRA8, 1=RGB16] [SDK scale]");stress(argv[2],argv[3],std::stoi(argv[4]),argc>=6?std::stoi(argv[5]):0,argc==7?std::stof(argv[6]):1);return 0;
        }
        if(argc>1&&std::string(argv[1])=="--inspect") {
            require(argc==3,"Usage: --inspect clip");BrawDecoder decoder;
            require(decoder.OpenClip(argv[2]),decoder.LastError());auto audio=decoder.GetAudioInfo();
            printf("SDK %s; %ux%u; %.6f fps; %llu frames; %.2f seconds; audio %u Hz, %u channels, %u bits, %llu samples\n",
                decoder.SDKVersion().c_str(),decoder.GetWidth(),decoder.GetHeight(),decoder.GetFrameRate(),decoder.GetFrameCount(),
                decoder.GetFrameCount()/double(decoder.GetFrameRate()),audio.rate,audio.channels,audio.bits,audio.samples);
            printf("As-shot ISO %u; read-only %d; supported:",decoder.GetNativeISO(),decoder.ISOIsReadOnly());for(auto iso:decoder.GetISOList())printf(" %u",iso);puts("");return 0;
        }
        if(argc>1&&std::string(argv[1])=="--iso") {
            require(argc==3,"Usage: --iso clip");
            BrawDecoder decoder;require(decoder.OpenClip(argv[2]),decoder.LastError());
            auto list=decoder.GetISOList();require(!list.empty(),"Missing ISO capabilities");
            auto* clip=braw_clip_open(argv[2]);require(clip,"Clip import failed");
            require(int(list.size())==braw_clip_get_iso_count(clip),"Bridge ISO list differs from SDK");
            for(size_t i=0;i<list.size();i++)require(list[i]==braw_clip_get_iso_at(clip,int(i)),"Bridge ISO value differs from SDK");
            ClipAdjustments a;a.iso=decoder.GetNativeISO();a.colorTemp=decoder.GetNativeColorTemp();a.tint=decoder.GetNativeTint();a.previewLUT=false;
            int w=0,h=0,stride=0;
            const auto native=decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f);require(!native.empty(),decoder.LastError());
            if(!decoder.ISOIsReadOnly())for(auto iso:{list.front(),list.back()}) {
                a.iso=iso;const auto pixels=decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f);
                require(!pixels.empty(),decoder.LastError());if(iso!=decoder.GetNativeISO())require(pixels!=native,"Supported ISO produced no pixel change: "+std::to_string(iso));
                braw_clip_set_iso(clip,iso);require(braw_clip_get_iso(clip)==iso,"Valid ISO was not retained in settings");
            }
            a.iso=UINT32_MAX;require(decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f).empty(),"Unsupported ISO decoded silently");
            require(decoder.LastError().find("not supported")!=std::string::npos,"Missing unsupported ISO explanation");
            braw_clip_set_iso(clip,UINT32_MAX);require(braw_clip_get_iso(clip)==decoder.GetNativeISO(),"Invalid ISO did not normalize to as-shot");
            // Verify the RGB16 format used by exports also honors ISO.
            decoder.Close();decoder.SetOutputFormat(1);require(decoder.OpenClip(argv[2]),decoder.LastError());
            a.iso=decoder.GetNativeISO();const auto rgbNative=decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f);require(!rgbNative.empty()&&stride==w*6,"Export RGB16 baseline failed");
            if(!decoder.ISOIsReadOnly()) {
                a.iso=list.front()==a.iso?list.back():list.front();
                const auto rgbAdjusted=decoder.DecodeFrameSync(0,&w,&h,&stride,a,.125f);
                require(!rgbAdjusted.empty(),decoder.LastError());if(a.iso!=decoder.GetNativeISO())require(rgbAdjusted!=rgbNative,"ISO did not change export RGB16 pixels");
            }
            if(decoder.GetFrameCount()==1&&!decoder.ISOIsReadOnly()&&list.front()!=list.back()) {
                Directory dir;auto* project=braw_project_create();require(braw_project_import(project,argv[2])==0,"Export fixture import failed");
                std::vector<std::string> decoded;
                for(auto iso:{list.front(),list.back()}) {
                    auto folder=fs::path(dir.path)/std::to_string(iso);fs::create_directory(folder);
                    braw_clip_set_iso(braw_project_get_clip(project,0),iso);int index=0;
                    require(braw_export_start(project,&index,1,2,3,0,100,folder.c_str(),nullptr,nullptr)==0,"Adjusted export failed: "+std::string(braw_export_last_error()));
                    auto output=folder/(fs::path(argv[2]).stem().string()+".mov");auto raw=folder/"frame.bgra";
                    ChildProcess ffmpeg;require(ffmpeg.Start({SiblingExecutable("ffmpeg"),"-hide_banner","-loglevel","error","-threads","2","-i",output.string(),"-map","0:v:0","-frames:v","1","-pix_fmt","bgra","-f","rawvideo",raw.string()},false),ffmpeg.Error());ffmpeg.CloseInput();require(ffmpeg.Wait(30),ffmpeg.Error());
                    std::ifstream file(raw,std::ios::binary);decoded.emplace_back(std::istreambuf_iterator<char>(file),std::istreambuf_iterator<char>());
                    require(decoded.back().size()==uint64_t(decoder.GetWidth())*decoder.GetHeight()*4,"Wrong exported frame dimensions");
                }
                require(decoded[0]!=decoded[1],"Exported MOV pixels ignored ISO adjustment");braw_project_destroy(project);
            }
            braw_clip_close(clip);printf("PASS: clip ISO list, supported preview/export pixel changes, unsupported ISO rejection (%u–%u, read-only %d)\n",list.front(),list.back(),decoder.ISOIsReadOnly());return 0;
        }
        if(argc>1&&(std::string(argv[1])=="--export"||std::string(argv[1])=="--export-folder")) {
            require(argc==6||argc==7,"Usage: --export cpu|metal clip output-directory resolution [codec: 0=H264, 1=HEVC, 2=ProRes]");
            setenv("BRAW_DECODE_PIPELINE",argv[2],1);fs::create_directories(argv[4]);
            auto* project=braw_project_create();std::vector<fs::path> sources;
            if(std::string(argv[1])=="--export-folder") {
                for(const auto& entry:fs::directory_iterator(argv[3]))if(entry.path().extension()==".braw")sources.push_back(entry.path());
                std::sort(sources.begin(),sources.end());
            } else sources.push_back(argv[3]);
            require(!sources.empty(),"No BRAW clips found");std::vector<int> indices;
            for(const auto& source:sources){const int index=braw_project_import(project,source.c_str());require(index>=0,"Import failed");indices.push_back(index);}
            uint64_t peak=0;auto start=std::chrono::steady_clock::now();
            int codec=argc==7?std::stoi(argv[6]):1;
            int result=braw_export_start(project,indices.data(),int(indices.size()),codec,3,std::stoi(argv[5]),100,argv[4],
                [](int clip,int clips,int frame,int total,void* ctx){
                    auto& peak=*static_cast<uint64_t*>(ctx);peak=std::max(peak,ChildProcess::ChildrenMemory());
                    if(frame==1||frame%250==0||frame==total) {printf("clip %d/%d; %d/%d frames; children %.0f MiB; peak %.0f MiB\n",
                        clip+1,clips,frame,total,ChildProcess::ChildrenMemory()/1048576.,peak/1048576.);fflush(stdout);}
                },&peak);
            std::string error=braw_export_last_error(),warning=braw_export_last_warning();braw_project_destroy(project);
            if(!warning.empty())printf("%s\n",warning.c_str());
            require(result==0,error);printf("PASS: full export %.1f seconds; peak child footprint %.0f MiB\n",
                std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count(),peak/1048576.);return 0;
        }
        if(argc>1&&std::string(argv[1])=="--skip-17k") {
            require(argc==4,"Usage: --skip-17k 17k-clip supported-clip");
            Directory dir;auto* project=braw_project_create();
            require(braw_project_import(project,argv[2])==0&&braw_project_import(project,argv[3])==1,"Import failed");
            const auto skipped=fs::path(dir.path)/(fs::path(argv[2]).stem().string()+".mov");
            {std::ofstream file(skipped);file<<"preserved";}
            int index=0;
            require(braw_export_start(project,&index,1,1,3,0,100,dir.path.c_str(),nullptr,nullptr)==-3,"All-skipped export reported success");
            require(std::string(braw_export_last_error()).find("No clips exported")!=std::string::npos,"Missing all-skipped explanation");
            require(std::string(braw_export_last_warning()).find(fs::path(argv[2]).filename().string())!=std::string::npos,"Missing skipped filename");
            int indices[]={0,1,0};
            require(braw_export_start(project,indices,3,1,3,0,100,dir.path.c_str(),nullptr,nullptr)==0,"Mixed batch failed: "+std::string(braw_export_last_error()));
            require(fs::exists(fs::path(dir.path)/(fs::path(argv[3]).stem().string()+".mov")),"Supported clip was not exported");
            {std::ifstream file(skipped);std::string contents;file>>contents;require(contents=="preserved","Skipped export changed existing output");}
            require(std::distance(fs::directory_iterator(dir.path),fs::directory_iterator{})==2,"Skipped export left temporary files");
            require(!std::string(braw_export_last_warning()).empty(),"Mixed export omitted warning");
            index=1;require(braw_export_start(project,&index,1,1,3,0,100,dir.path.c_str(),nullptr,nullptr)==0,"Subsequent supported export failed");
            require(std::string(braw_export_last_warning()).empty(),"Skip warning leaked into next export");
            braw_project_destroy(project);puts("PASS: native 17K skip, mixed batch continuation, prior output preserved, warning reset");return 0;
        }
        processes();if(argc>1)native(argv[1]);return 0;
    }catch(const std::exception& e){fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
