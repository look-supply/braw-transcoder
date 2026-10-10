#pragma once
#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>
#include <sys/types.h>

// Owns exactly one child and its IPC endpoint; never signals unrelated processes.
class ChildProcess {
public:
    ChildProcess()=default;
    ~ChildProcess();
    ChildProcess(const ChildProcess&)=delete;
    ChildProcess& operator=(const ChildProcess&)=delete;
    bool Start(const std::vector<std::string>& args,bool duplex,uint64_t memoryLimitBytes=0);
    bool Read(void* data,size_t size,int timeoutSeconds=30,const std::atomic<bool>* cancel=nullptr);
    bool Write(const void* data,size_t size,int timeoutSeconds=30,const std::atomic<bool>* cancel=nullptr);
    void CloseInput();
    bool Wait(int timeoutSeconds,const std::atomic<bool>* cancel=nullptr);
    void Stop();
    std::string Error() const;
    const std::string& Reason() const {return reason;}
    pid_t PID() const{return pid;}
    static uint64_t MemoryBudget();
    static uint64_t ChildrenMemory();
private:
    bool Transfer(void*,size_t,bool,int,const std::atomic<bool>*);
    bool Healthy(const std::atomic<bool>*);
    pid_t pid=-1;
    int fd=-1;
    uint64_t memoryLimit=0;
    std::chrono::steady_clock::time_point memoryChecked{};
    std::string logPath,reason;
};
std::string SiblingExecutable(const char* name);
