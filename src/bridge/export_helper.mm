// export_helper — subprocess that exports a single BRAW clip via CPU decode.
// Spawned by braw_export_start for each clip. All SDK memory
// is reclaimed by the OS when this process exits.
// CPU decode path doesn't leak (no GPU/Metal pipeline).
// Usage: export_helper <braw_path> <output_path> <codec> <profile> <res> <bitrate> [iso] [colorTemp] [tint] [exposure] [highlightRecovery] [bakeLUT]

#include "bridge/braw_api.h"
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static void progressFn(int ci, int tc, int fi, int tf, void*) {
    if (fi >= 0) {
        fprintf(stdout, "PROGRESS %d\n", fi);
        fflush(stdout);
    }
}

int main(int argc, char** argv) {
    fprintf(stderr, "HELPER: start %s -> %s\n", argv[1], argv[2]);
    if (argc < 7) {
        fprintf(stderr, "HELPER: insufficient args (%d)\n", argc);
        return 1;
    }

    BrawProjectHandle* proj = braw_project_create();
    if (!proj) { fprintf(stderr, "HELPER: project_create failed\n"); return 1; }

    int imp = braw_project_import(proj, argv[1]);
    if (imp < 0) {
        fprintf(stderr, "HELPER: import failed (%d) for %s\n", imp, argv[1]);
        braw_project_destroy(proj);
        return 1;
    }
    fprintf(stderr, "HELPER: import OK idx=%d\n", imp);

    BrawClipHandle* clip = braw_project_get_clip(proj, 0);
    if (clip) {
        if (argc > 7) braw_clip_set_iso(clip, (uint32_t)atoi(argv[7]));
        if (argc > 8) braw_clip_set_color_temp(clip, (uint32_t)atoi(argv[8]));
        if (argc > 9) braw_clip_set_tint(clip, (int16_t)atoi(argv[9]));
        if (argc > 10) braw_clip_set_exposure(clip, (float)atof(argv[10]));
        if (argc > 11) braw_clip_set_highlight_recovery(clip, atoi(argv[11]) != 0);
        if (argc > 12) braw_clip_set_bake_lut(clip, atoi(argv[12]) != 0);
    }

    int indices[] = {0};
    int ret = braw_export_start_inprocess(proj, indices, 1,
        atoi(argv[3]), atoi(argv[4]), atoi(argv[5]), atoi(argv[6]),
        argv[2], progressFn, nullptr);
    if (ret != 0) {
        fprintf(stderr, "HELPER: export_start_inprocess returned %d\n", ret);
        braw_project_destroy(proj);
        return 1;
    }
    fprintf(stderr, "HELPER: export_start_inprocess OK, waiting...\n");

    while (braw_export_is_running()) usleep(100000);
    fprintf(stderr, "HELPER: done\n");
    braw_project_destroy(proj);
    return 0;
}
