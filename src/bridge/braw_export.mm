#include "bridge/braw_api.h"
#include "core/Types.h"
#include "core/BrawDecoder.h"
#import <Foundation/Foundation.h>
#include <atomic>
#include <dispatch/dispatch.h>
#include <unistd.h>

static std::atomic<bool> g_running{false};
static std::atomic<bool> g_cancel{false};

static NSString* findFFmpeg(void) {
    NSString* ep=[[NSBundle mainBundle]executablePath];
    if(ep){NSString*s=[[ep stringByDeletingLastPathComponent]stringByAppendingPathComponent:@"ffmpeg"];
        if(s&&[[NSFileManager defaultManager]isExecutableFileAtPath:s])return s;}
    NSString* b=[[NSBundle mainBundle]pathForResource:@"ffmpeg" ofType:nil];
    if(b&&[[NSFileManager defaultManager]isExecutableFileAtPath:b])return b;
    NSString* sys[]={@"/opt/homebrew/bin/ffmpeg",@"/usr/local/bin/ffmpeg",@"/usr/bin/ffmpeg"};
    for(int i=0;i<3;i++)if([[NSFileManager defaultManager]isExecutableFileAtPath:sys[i]])return sys[i];
    return nil;
}

static bool exportClip(BrawClipHandle* clip, int,int,float fps,
    uint64_t fs,uint64_t fe,int codec,int bitrate,
    const std::string& outPath,ExportProgressFn pf,void* pctx,int ci,int tc,
    const std::string&,uint32_t,uint32_t) {
    uint64_t n=fe-fs; if(!n)return false;
    uint32_t sw=braw_clip_get_width(clip),sh=braw_clip_get_height(clip);
    NSString* ff=findFFmpeg(); if(!ff)return false;

    // Write raw BGRA to temp file
    char rt[512]; snprintf(rt,sizeof(rt),"/tmp/braw_%d.bin",getpid());
    FILE* f=fopen(rt,"wb"); if(!f)return false;

    BrawDecoder bd;
    if(!bd.OpenClip(braw_clip_get_filepath(clip))){fclose(f);unlink(rt);return false;}
    bd.CaptureNativeSettings();
    ClipAdjustments a; a.iso=braw_clip_get_iso(clip); a.colorTemp=braw_clip_get_color_temp(clip);
    a.tint=braw_clip_get_tint(clip); a.exposure=braw_clip_get_exposure(clip);
    a.highlightRecovery=braw_clip_get_highlight_recovery(clip); a.previewLUT=true; // Required for correct CPU pipeline pixel output

    for(uint64_t i=fs;i<fe&&!g_cancel.load();i++){
        bd.RequestFrame(i,a,^(const uint8_t* p,int w,int h,int bpr){
            if(g_cancel.load())return;
            size_t rw=(size_t)w*4;
            uint8_t* buf=(uint8_t*)malloc(rw*(size_t)h);
            for(int y=0;y<h;y++) memcpy(buf+y*rw,p+(size_t)y*bpr,rw);
            fwrite(buf,1,rw*h,f); free(buf);
            if(pf)pf(ci,tc,(int)i,(int)n,pctx);
        });
    }
    bd.Close(); fclose(f);
    fprintf(stderr,"EXPORT: raw file written (%lld bytes)\n",(long long)((size_t)sw*sh*4*n));

    // Encode with ffmpeg
    char cmd[4096]; snprintf(cmd,sizeof(cmd),
        "\"%s\" -y -f rawvideo -pixel_format bgra -s %dx%d -r %.2f -i \"%s\" "
        "-c:v %s -tag:v hvc1 -b:v %d -pix_fmt p010le "
        "-colorspace bt709 -color_primaries bt709 -color_trc bt709 "
        "-movflags +faststart \"%s\" 2>/tmp/ffmpeg_err.log",
        [ff UTF8String],(int)sw,(int)sh,fps,rt,
        codec==0?"h264_videotoolbox":codec==2?"prores_ks":"hevc_videotoolbox",
        bitrate, outPath.c_str());
    fprintf(stderr,"EXPORT: %s\n",cmd);
    int rc=system(cmd);
    unlink(rt);
    return rc==0&&!g_cancel.load();
}

extern "C" {
int braw_export_start(BrawProjectHandle* proj, const int* indices, int count,
    int codec,int pr,int rm,int dr,const char* od,ExportProgressFn pf,void* ctx){
    if(g_running.exchange(true)||!proj||!indices||count<=0)return -1;
    g_cancel=false;
    NSString* odc=(od&&od[0])?[NSString stringWithUTF8String:od]:nil;
    @autoreleasepool{
        for(int i=0;i<count&&!g_cancel.load();i++){
            auto* c=braw_project_get_clip(proj,indices[i]); if(!c)continue;
            uint64_t tf=braw_clip_get_frame_count(c); if(!tf)continue;
            const char*fp=braw_clip_get_filepath(c);
            NSString*nb=[NSString stringWithUTF8String:fp];
            NSString*bn=[[nb lastPathComponent]stringByDeletingPathExtension];
            NSString*od=odc?:[nb stringByDeletingLastPathComponent];
            std::string op=[[od stringByAppendingPathComponent:[bn stringByAppendingString:@".mov"]]UTF8String];
            exportClip(c,0,0,braw_clip_get_frame_rate(c),0,tf,codec,dr*1000000,op,pf,ctx,i,count,"",0,0);
        }
        g_running=false; if(pf)pf(count-1,count,-1,-1,ctx);
    }
    return 0;
}
int braw_export_is_running(void){return g_running.load()?1:0;}
void braw_export_cancel(void){g_cancel=true;g_running=false;}
void braw_export_reset(void){g_cancel=false;g_running=false;}
}
