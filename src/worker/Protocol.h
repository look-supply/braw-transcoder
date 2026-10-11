#pragma once
#include <cstdint>
namespace WorkerProtocol {
constexpr uint32_t magic=0x42524136;
// A native 17K RGB16 frame is ~806 MiB. Keep IPC bounded while supporting
// these camera frames; ChildProcess separately enforces the memory budget.
constexpr uint64_t maxPayload=1024ULL*1024*1024;
enum Command:uint32_t {Open=1,Frame=2,Audio=3};
struct Request {
    uint32_t magicValue=magic,command=0;
    uint64_t index=0;
    uint32_t count=0,iso=0,temperature=0;
    int32_t tint=0;
    float exposure=0,scale=1;
    uint32_t highlight=0,lut=0,metal=0,format=0;
    uint64_t size=0;
};
struct Response {
    uint32_t magicValue=magic;
    int32_t status=-1;
    uint32_t width=0,height=0,stride=0;
    uint64_t size=0;
};
}
