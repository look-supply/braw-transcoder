#pragma once
#include <stdio.h>
#include <stdarg.h>
#include <string>
#include <mutex>
#include <mach/mach.h>
#include <mach/mach_time.h>

// File-backed logger that writes to the project directory.
// Flushes every write so crash logs are not lost.

static FILE* g_logFile = nullptr;
static std::mutex g_logMutex;
static uint64_t g_logStart = 0;

inline double braw_log_elapsed_ms(void) {
    if (g_logStart == 0) g_logStart = mach_absolute_time();
    uint64_t now = mach_absolute_time();
    static mach_timebase_info_data_t info = {0, 0};
    if (info.denom == 0) mach_timebase_info(&info);
    uint64_t nanos = (now - g_logStart) * info.numer / info.denom;
    return (double)nanos / 1000000.0;
}

inline void braw_log_init(const char* projectDir) {
    std::string path = std::string(projectDir) + "/braw_memory_trace.log";
    g_logFile = fopen(path.c_str(), "w");
    if (g_logFile) {
        fprintf(g_logFile, "=== BRAW Memory Trace Log ===\n");
        fprintf(g_logFile, "time_ms\trss_mb\tcaller\n");
        fflush(g_logFile);
    }
}

inline void braw_log_rss(const char* caller) {
    if (!g_logFile) return;
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    int64_t rss = 0;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) == KERN_SUCCESS) {
        rss = (int64_t)info.resident_size;
    }
    double elapsed = braw_log_elapsed_ms();
    std::lock_guard<std::mutex> lock(g_logMutex);
    fprintf(g_logFile, "%.0f\t%.0f\t%s\n", elapsed, (double)rss / (1024.0*1024.0), caller);
    fflush(g_logFile);
}

inline void braw_log_printf(const char* fmt, ...) {
    if (!g_logFile) return;
    va_list args;
    va_start(args, fmt);
    std::lock_guard<std::mutex> lock(g_logMutex);
    vfprintf(g_logFile, fmt, args);
    fflush(g_logFile);
    va_end(args);
}
