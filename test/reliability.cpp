#include "bridge/braw_api.h"
#include "core/BrawDecoder.h"
#include "core/ChildProcess.h"
#include "core/ExportEncoderError.h"
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
static void processes() {
    {
        BrawDecoder decoder;
        require(!decoder.OpenClip("/missing.braw"),"Missing source accepted");
        const auto error=decoder.LastError();
        require(error.find("opening source clip /missing.braw")!=std::string::npos&&
                error.find("worker status")!=std::string::npos&&error.find("OpenClip failed")!=std::string::npos,
                "Source-open failure omitted operation or SDK detail: "+error);
    }
    const auto unsupported=ExportEncoderError(1,17520,8040,"Processing worker exited or closed its channel\nCannot prepare encoder: -12902");
    require(unsupported.find("17520 × 8040")!=std::string::npos&&unsupported.find("Choose 4K or 1080p")!=std::string::npos&&unsupported.find("full resolution")!=std::string::npos,"Missing actionable encoder initialization error");
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
int main(int argc,char** argv) {
    setvbuf(stdout,nullptr,_IOLBF,0);
    if(argc>1&&std::string(argv[1])=="--hang"){while(true)pause();}
    if(argc>1&&std::string(argv[1])=="--crash")_exit(17);
    if(argc>1&&std::string(argv[1])=="--allocate"){std::vector<uint8_t> memory(128*1024*1024,42);while(true)pause();}
    try {
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
                decoder.GetFrameCount()/double(decoder.GetFrameRate()),audio.rate,audio.channels,audio.bits,audio.samples);return 0;
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
