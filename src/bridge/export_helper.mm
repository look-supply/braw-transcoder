// export_helper — subprocess that exports a frame range of a single BRAW clip.
// Spawned by braw_export_start for each segment. Each helper processes a bounded
// number of frames (BRAW_EXPORT_SEGMENT_FRAMES = 200), then exits. OS reclaims
// all leaked BRAW SDK GPU memory when the process exits.
//
// Usage:
//   export_helper <braw_path> <output_path> <codec> <profile> <res> <bitrate>
//                 [iso] [colorTemp] [tint] [exposure] [highlightRecovery] [bakeLUT]
//                 <startFrame> <endFrame>

#include "bridge/braw_api.h"
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static void progressFn(int ci, int tc, int fi, int tf, void*) {
    // Report global frame index — parent maps to clip progress
    if (fi >= 0) {
        fprintf(stdout, "PROGRESS %d\n", fi);
        fflush(stdout);
    }
}

int main(int argc, char** argv) {
    if (argc < 15) {
        fprintf(stderr, "HELPER: insufficient args (%d, need 15)\n", argc);
        return 1;
    }

    fprintf(stderr, "HELPER: start %s -> %s frames [%s, %s)\n",
            argv[1], argv[2], argv[13], argv[14]);

    BrawProjectHandle* proj = braw_project_create();
    if (!proj) { fprintf(stderr, "HELPER: project_create failed\n"); return 1; }

    int imp = braw_project_import(proj, argv[1]);
    if (imp < 0) {
        fprintf(stderr, "HELPER: import failed (%d) for %s\n", imp, argv[1]);
        braw_project_destroy(proj);
        return 1;
    }

    BrawClipHandle* clip = braw_project_get_clip(proj, 0);
    if (!clip) {
        fprintf(stderr, "HELPER: get_clip failed\n");
        braw_project_destroy(proj);
        return 1;
    }

    // Apply adjustments
    if (argc > 7) braw_clip_set_iso(clip, (uint32_t)atoi(argv[7]));
    if (argc > 8) braw_clip_set_color_temp(clip, (uint32_t)atoi(argv[8]));
    if (argc > 9) braw_clip_set_tint(clip, (int16_t)atoi(argv[9]));
    if (argc > 10) braw_clip_set_exposure(clip, (float)atof(argv[10]));
    if (argc > 11) braw_clip_set_highlight_recovery(clip, atoi(argv[11]) != 0);
    if (argc > 12) braw_clip_set_bake_lut(clip, atoi(argv[12]) != 0);

    uint64_t startFrame = strtoull(argv[13], nullptr, 10);
    uint64_t endFrame   = strtoull(argv[14], nullptr, 10);

    fprintf(stderr, "HELPER: exporting frames [%llu, %llu)\n",
            (unsigned long long)startFrame, (unsigned long long)endFrame);

    int ret = braw_export_segment(clip,
        atoi(argv[3]), atoi(argv[4]), atoi(argv[5]), atoi(argv[6]),
        argv[2], startFrame, endFrame, progressFn, nullptr);

    if (ret != 0) {
        fprintf(stderr, "HELPER: export_segment returned %d\n", ret);
        braw_project_destroy(proj);
        return 1;
    }

    fprintf(stderr, "HELPER: segment done\n");
    braw_project_destroy(proj);
    return 0;
}
