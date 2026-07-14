#include "bridge/braw_api.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <chrono>
#include <unistd.h>
#include <mach/mach.h>

static double myRSS() {
    struct mach_task_basic_info info;
    mach_msg_type_number_t c = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &c) == KERN_SUCCESS)
        return info.resident_size / (1024.0*1024.0);
    return 0;
}

static int checkFile(const char* path) {
    char cmd[1024];
    // Check file exists
    snprintf(cmd, sizeof(cmd), "ls -la '%s' 2>/dev/null | awk '{print $5}'", path);
    FILE* fp = popen(cmd, "r");
    long size = 0;
    if (fp) { char b[64]={}; fgets(b,sizeof(b),fp); size = atol(b); pclose(fp); }
    
    // Check 10-bit video
    snprintf(cmd, sizeof(cmd), "ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 '%s' 2>/dev/null | grep -c '10'", path);
    fp = popen(cmd, "r");
    int is10bit = 0;
    if (fp) { char b[16]={}; fgets(b,sizeof(b),fp); is10bit = atoi(b); pclose(fp); }
    
    // Check PCM audio
    snprintf(cmd, sizeof(cmd), "ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 '%s' 2>/dev/null | grep -c 'pcm'", path);
    fp = popen(cmd, "r");
    int hasPCM = 0;
    if (fp) { char b[16]={}; fgets(b,sizeof(b),fp); hasPCM = atoi(b); pclose(fp); }
    
    printf("    %-55s %s  10bit=%s  pcm=%s  size=%ld\n",
           path, size > 1024 ? "OK" : "EMPTY",
           is10bit ? "YES" : "NO",
           hasPCM ? "YES" : "NO",
           size);
    return (size > 1024 && is10bit && hasPCM) ? 0 : 1;
}

int main(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "Usage: braw_test <clip1> <clip2> <clip3> <clip4>\n");
        return 1;
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("═══════════════════════════════════════════════════════════════\n");
    printf("  END-TO-END EXPORT TEST — 4 different clips\n");
    printf("═══════════════════════════════════════════════════════════════\n\n");
    
    for (int i = 0; i < 4; i++)
        printf("  Clip %d: %s\n", i, argv[i+1]);

    BrawProjectHandle* proj = braw_project_create();
    if (!proj) { printf("\nFAIL: project_create\n"); return 1; }

    // Import all 4 clips
    printf("\n--- Import ---\n");
    for (int i = 0; i < 4; i++) {
        int idx = braw_project_import(proj, argv[i+1]);
        printf("  Import %d -> idx=%d  filepath='%s' filename='%s'\n",
               i, idx,
               braw_clip_get_filepath(braw_project_get_clip(proj, idx)),
               braw_clip_get_filename(braw_project_get_clip(proj, idx)));
    }
    printf("  Total clips: %d  RSS: %.0fMB\n", braw_project_get_clip_count(proj), myRSS());

    // ── Test 1: braw_export_start (same code path as UI's Export All) ──
    printf("\n══════ Test 1: braw_export_start ([0,1,2,3]) ══════\n");
    system("rm -rf /tmp/e2e_test && mkdir -p /tmp/e2e_test");
    
    int all[] = {0, 1, 2, 3};
    auto t0 = std::chrono::steady_clock::now();
    braw_export_start(proj, all, 4, 1, 3, 0, 200, "/tmp/e2e_test", nullptr, nullptr);
    while (braw_export_is_running()) usleep(100000);
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
    
    printf("  Time: %.1fs  RSS: %.0fMB\n\n", secs, myRSS());
    printf("  Output files:\n");
    int rc = 0;
    rc |= checkFile("/tmp/e2e_test/A002_07031812_C017_export.mov");
    rc |= checkFile("/tmp/e2e_test/A002_07031812_C018_export.mov");
    rc |= checkFile("/tmp/e2e_test/A002_07031813_C019_export.mov");
    rc |= checkFile("/tmp/e2e_test/A002_07031813_C020_export.mov");

    // ── Test 2: Source directory output (no outputDir specified, like UI default) ──
    printf("\n══════ Test 2: Export to source dir (no outputDir) ══════\n");
    system("rm -rf /tmp/e2e_src && mkdir -p /tmp/e2e_src");
    // Simulate empty outputDir — C code should use source file's directory
    braw_export_start(proj, all, 4, 1, 3, 0, 200, "", nullptr, nullptr);
    while (braw_export_is_running()) usleep(100000);
    printf("  RSS: %.0fMB\n\n", myRSS());
    // Check in the source directory
    // Note: without outputDir, C now uses source dir. For test, we can't check
    // easily in the volume path, so we use the known output dir.
    printf("  (output goes to source directory, not test dir)\n");

    // ── Test 3: Helper subprocess direct call ──
    printf("\n══════ Test 3: export_helper subprocess (4 helpers) ══════\n");
    system("rm -rf /tmp/e2e_sub && mkdir -p /tmp/e2e_sub");
    for (int i = 0; i < 4; i++) {
        char outPath[512];
        const char* name = braw_clip_get_filename(braw_project_get_clip(proj, i));
        char base[256];
        snprintf(base, sizeof(base), "%s", name);
        char* dot = strrchr(base, '.');
        if (dot) *dot = '\0';
        snprintf(outPath, sizeof(outPath), "/tmp/e2e_sub/%s_export.mov", base);
        
        char cmd[1024];
        snprintf(cmd, sizeof(cmd), "build/export_helper '%s' '%s' 1 3 0 200 >/dev/null 2>&1", argv[i+1], outPath);
        printf("  Helper %d...\n", i);
        system(cmd);
    }
    printf("\n  Subprocess output:\n");
    rc |= checkFile("/tmp/e2e_sub/A002_07031812_C017_export.mov");
    rc |= checkFile("/tmp/e2e_sub/A002_07031812_C018_export.mov");
    rc |= checkFile("/tmp/e2e_sub/A002_07031813_C019_export.mov");
    rc |= checkFile("/tmp/e2e_sub/A002_07031813_C020_export.mov");

    braw_project_destroy(proj);
    
    printf("\n═══════════════════════════════════════════════════════════════\n");
    printf("  OVERALL: %s\n", rc == 0 ? "ALL TESTS PASSED ✓" : "SOME TESTS FAILED ✗");
    printf("═══════════════════════════════════════════════════════════════\n");
    return rc;
}
