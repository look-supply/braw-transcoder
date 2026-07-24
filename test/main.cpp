#include "bridge/braw_api.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <chrono>
#include <unistd.h>

static int checkFile(const char* path) {
    char cmd[1024];
    // Check file exists and size
    snprintf(cmd, sizeof(cmd), "ls -la '%s' 2>/dev/null | awk '{print $5}'", path);
    FILE* fp = popen(cmd, "r");
    long size = 0;
    if (fp) { char b[64]={}; fgets(b,sizeof(b),fp); size = atol(b); pclose(fp); }

    // Check 10-bit video
    snprintf(cmd, sizeof(cmd),
             "ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt "
             "-of csv=p=0 '%s' 2>/dev/null | grep -c '10'", path);
    fp = popen(cmd, "r");
    int is10bit = 0;
    if (fp) { char b[16]={}; fgets(b,sizeof(b),fp); is10bit = atoi(b); pclose(fp); }

    // Check PCM s24le audio
    snprintf(cmd, sizeof(cmd),
             "ffprobe -v error -select_streams a:0 -show_entries stream=codec_name "
             "-of csv=p=0 '%s' 2>/dev/null", path);
    fp = popen(cmd, "r");
    char codec[32] = {};
    if (fp) { fgets(codec, sizeof(codec), fp); pclose(fp); }
    char* nl = strchr(codec, '\n');
    if (nl) *nl = '\0';
    int hasPCM = (strcmp(codec, "pcm_s24le") == 0 || strcmp(codec, "pcm_s24be") == 0) ? 1 : 0;

    printf("    %-55s %s  10bit=%s  audio=%-10s  size=%ld\n",
           path, size > 1024 ? "OK" : "EMPTY",
           is10bit ? "YES" : "NO",
           hasPCM ? codec : "NONE",
           size);
    return (size > 1024 && is10bit && hasPCM) ? 0 : 1;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: braw_test <clip1> [clip2 ...]\n");
        fprintf(stderr, "Tests CPU decode and export for one or more BRAW clips.\n");
        return 1;
    }

    int numClips = argc - 1;
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("═══════════════════════════════════════════════════════════════\n");
    printf("  CPU-ONLY DECODE & EXPORT TEST — %d clip(s)\n", numClips);
    printf("═══════════════════════════════════════════════════════════════\n\n");

    for (int i = 0; i < numClips; i++)
        printf("  Clip %d: %s\n", i, argv[i+1]);

    BrawProjectHandle* proj = braw_project_create();
    if (!proj) { printf("\nFAIL: project_create\n"); return 1; }

    // Import all clips
    printf("\n--- Import ---\n");
    for (int i = 0; i < numClips; i++) {
        int idx = braw_project_import(proj, argv[i+1]);
        printf("  Import %d -> idx=%d  filename='%s'\n",
               i, idx,
               braw_clip_get_filename(braw_project_get_clip(proj, idx)));
    }
    printf("  Total clips: %d\n", braw_project_get_clip_count(proj));

    // ── Test: Single-frame decode (metadata + thumbnail) ──
    printf("\n--- Single-frame decode (CPU) ---\n");
    for (int i = 0; i < numClips; i++) {
        auto* clip = braw_project_get_clip(proj, i);
        if (!clip) continue;
        int w = 0, h = 0;
        uint8_t* pixels = braw_clip_decode_frame_scaled(clip, 0, &w, &h, 0.25f);
        printf("  Clip %d: %ux%u native, decoded %dx%d at 0.25x scale%s\n",
               i,
               braw_clip_get_width(clip), braw_clip_get_height(clip),
               w, h,
               pixels ? " ✓" : " ✗");
        if (pixels) {
            // Verify pixel data is non-zero (frame decoded)
            bool hasContent = false;
            for (int j = 0; j < w * h * 4; j++) {
                if (pixels[j] != 0) { hasContent = true; break; }
            }
            printf("         pixels contain data: %s\n", hasContent ? "yes ✓" : "no ✗");
            braw_clip_free_frame(pixels);
        }
        printf("         metadata: %s · %s · Gen %u · %s\n",
               braw_clip_get_gamma(clip),
               braw_clip_get_gamut(clip),
               braw_clip_get_color_science_gen(clip),
               braw_clip_get_camera_type(clip));
    }

    // ── Test: braw_export_start (CPU batch export) ──
    printf("\n--- CPU batch export test ---\n");
    char tmpDir[256];
    snprintf(tmpDir, sizeof(tmpDir), "/tmp/braw_cpu_test_%d", getpid());
    char mkdirCmd[256];
    snprintf(mkdirCmd, sizeof(mkdirCmd), "rm -rf %s && mkdir -p %s", tmpDir, tmpDir);
    system(mkdirCmd);

    int allIndices[16];
    for (int i = 0; i < numClips && i < 16; i++) allIndices[i] = i;
    int count = (numClips < 16) ? numClips : 16;

    auto t0 = std::chrono::steady_clock::now();
    int ret = braw_export_start(proj, allIndices, count, 1, 3, 0, 200,
                                 tmpDir, nullptr, nullptr);
    printf("  braw_export_start returned: %d\n", ret);

    while (braw_export_is_running()) usleep(100000);
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("  Export time: %.1fs\n\n", secs);

    printf("  Output files:\n");
    int rc = 0;
    for (int i = 0; i < numClips && i < 16; i++) {
        auto* clip = braw_project_get_clip(proj, i);
        if (!clip) continue;
        const char* fn = braw_clip_get_filename(clip);
        char base[256];
        snprintf(base, sizeof(base), "%s", fn);
        char* dot = strrchr(base, '.');
        if (dot) *dot = '\0';
        char outPath[512];
        snprintf(outPath, sizeof(outPath), "%s/%s.mov", tmpDir, base);
        rc |= checkFile(outPath);
    }

    braw_project_destroy(proj);

    printf("\n═══════════════════════════════════════════════════════════════\n");
    printf("  OVERALL: %s\n", rc == 0 ? "ALL TESTS PASSED ✓" : "SOME TESTS FAILED ✗");
    printf("═══════════════════════════════════════════════════════════════\n");
    return rc;
}
