#include "core/ChildProcess.h"
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/poll.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <cerrno>
#include <cstring>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <set>
extern char** environ;
namespace {
std::mutex childrenMutex;
std::set<pid_t> children;
uint64_t Footprint(pid_t pid) {
    rusage_info_v4 info{};
    return proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t*)&info)==0?info.ri_phys_footprint:0;
}
}
std::string SiblingExecutable(const char* name) {
    uint32_t n=0;_NSGetExecutablePath(nullptr,&n);std::string path(n,'\0');
    if(_NSGetExecutablePath(path.data(),&n))return {};
    path.resize(strlen(path.c_str()));
    return (std::filesystem::path(path).parent_path()/name).string();
}
uint64_t ChildProcess::MemoryBudget() {
    uint64_t physical=0;size_t size=sizeof(physical);sysctlbyname("hw.memsize",&physical,&size,nullptr,0);
    return std::min<uint64_t>(4ULL*1024*1024*1024,physical/3);
}
uint64_t ChildProcess::ChildrenMemory() {
    std::lock_guard lock(childrenMutex);uint64_t total=0;
    for(auto pid:children)total+=Footprint(pid);return total;
}
ChildProcess::~ChildProcess(){Stop();if(!logPath.empty())unlink(logPath.c_str());}
bool ChildProcess::Start(const std::vector<std::string>& args,bool duplex,uint64_t memoryLimitBytes) {
    Stop();memoryChecked={};memoryLimit=memoryLimitBytes;reason.clear();if(!logPath.empty())unlink(logPath.c_str());logPath.clear();
    if(args.empty()||access(args[0].c_str(),X_OK)) {reason="Required executable is unavailable: "+(args.empty()?std::string():args[0]);return false;}
    int pair[2];
    if(socketpair(AF_UNIX,SOCK_STREAM,0,pair)) {reason="Could not create process channel";return false;}
    for(int x:pair) {
        fcntl(x,F_SETFD,FD_CLOEXEC);
        int bufferSize=262144;
        setsockopt(x,SOL_SOCKET,SO_SNDBUF,&bufferSize,sizeof(bufferSize));
        setsockopt(x,SOL_SOCKET,SO_RCVBUF,&bufferSize,sizeof(bufferSize));
    }
    int noSignal=1;setsockopt(pair[0],SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal));
    char log[]="/tmp/braw-process-XXXXXX";int logFD=mkstemp(log);
    if(logFD<0) {close(pair[0]);close(pair[1]);reason="Could not create process log";return false;}
    logPath=log;fcntl(logFD,F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions,pair[1],STDIN_FILENO);
    if(duplex)posix_spawn_file_actions_adddup2(&actions,pair[1],STDOUT_FILENO);
    else posix_spawn_file_actions_addopen(&actions,STDOUT_FILENO,"/dev/null",O_WRONLY,0);
    posix_spawn_file_actions_adddup2(&actions,logFD,STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions,pair[0]);posix_spawn_file_actions_addclose(&actions,pair[1]);
    std::vector<char*> argv;for(auto& arg:args)argv.push_back(const_cast<char*>(arg.c_str()));argv.push_back(nullptr);
    // Only explicitly duplicated channels are inherited.
    posix_spawnattr_t attr;posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT);
    int rc=posix_spawn(&pid,args[0].c_str(),&actions,&attr,argv.data(),environ);
    posix_spawnattr_destroy(&attr);posix_spawn_file_actions_destroy(&actions);close(pair[1]);close(logFD);
    if(rc) {close(pair[0]);pid=-1;reason="Could not start child: "+std::string(strerror(rc));return false;}
    fd=pair[0];fcntl(fd,F_SETFL,O_NONBLOCK);
    {std::lock_guard lock(childrenMutex);children.insert(pid);}
    return true;
}
bool ChildProcess::Healthy(const std::atomic<bool>* cancel) {
    if(cancel&&cancel->load()){reason="Cancelled";return false;}
    if(pid<0){reason="Worker is not running";return false;}
    auto now=std::chrono::steady_clock::now();
    // Sample memory at 100 ms intervals, not once per 64 KiB of video data.
    if(now-memoryChecked>=std::chrono::milliseconds(100)) {
        memoryChecked=now;
        if((memoryLimit&&Footprint(pid)>memoryLimit)||ChildrenMemory()>MemoryBudget()) {
            reason="Processing exceeded the memory budget";return false;
        }
    }
    return true;
}
bool ChildProcess::Transfer(void* ptr,size_t size,bool writing,int timeout,const std::atomic<bool>* cancel) {
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(timeout);
    auto* p=static_cast<uint8_t*>(ptr);
    while(size) {
        if(!Healthy(cancel)){Stop();return false;}
        if(std::chrono::steady_clock::now()>=deadline){reason="Processing timed out";Stop();return false;}
        pollfd descriptor{fd,short(writing?POLLOUT:POLLIN),0};
        int ready=poll(&descriptor,1,50);
        if(ready<0&&errno==EINTR)continue;
        if(ready<0){reason="Process channel failed";Stop();return false;}
        if(!ready)continue;
        ssize_t got=writing?send(fd,p,std::min<size_t>(size,65536),0):recv(fd,p,std::min<size_t>(size,65536),0);
        if(got<0&&(errno==EAGAIN||errno==EINTR))continue;
        if(got<=0){reason="Processing worker exited or closed its channel";Stop();return false;}
        p+=got;size-=got;
    }
    return true;
}
bool ChildProcess::Read(void* p,size_t n,int t,const std::atomic<bool>* c){return Transfer(p,n,false,t,c);}
bool ChildProcess::Write(const void* p,size_t n,int t,const std::atomic<bool>* c){return Transfer(const_cast<void*>(p),n,true,t,c);}
void ChildProcess::CloseInput(){if(fd>=0)shutdown(fd,SHUT_WR);}
bool ChildProcess::Wait(int timeout,const std::atomic<bool>* cancel) {
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(timeout);
    while(pid>0) {
        if(!Healthy(cancel)){Stop();return false;}
        int status=0;pid_t result=waitpid(pid,&status,WNOHANG);
        if(result==pid) {
            {std::lock_guard lock(childrenMutex);children.erase(pid);}pid=-1;
            if(fd>=0){close(fd);fd=-1;}
            if(WIFEXITED(status)&&WEXITSTATUS(status)==0)return true;
            reason="Child process failed";return false;
        }
        if(result<0&&errno!=EINTR){reason="Could not wait for child";Stop();return false;}
        if(std::chrono::steady_clock::now()>=deadline){reason="Processing timed out";Stop();return false;}
        poll(nullptr,0,50);
    }
    return false;
}
void ChildProcess::Stop() {
    if(fd>=0){close(fd);fd=-1;}
    if(pid>0) {
        kill(pid,SIGKILL);int status;while(waitpid(pid,&status,0)<0&&errno==EINTR){}
        {std::lock_guard lock(childrenMutex);children.erase(pid);}pid=-1;
    }
}
std::string ChildProcess::Error() const {
    std::ifstream file(logPath);std::string log((std::istreambuf_iterator<char>(file)),{});
    if(log.size()>4096)log=log.substr(log.size()-4096);
    return reason+(log.empty()?"":"\n"+log);
}
