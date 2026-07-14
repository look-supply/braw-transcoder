// export_helper — subprocess that exports a single BRAW clip via CPU decode.
// Spawned by braw_export_start for each clip. All SDK memory
// is reclaimed by the OS when this process exits.
// CPU decode path doesn't leak (no GPU/Metal pipeline).
// Usage: export_helper <braw_path> <output_path> <codec> <profile> <res> <bitrate>

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
    if (argc < 7) return 1;

    BrawProjectHandle* proj = braw_project_create();
    if (!proj) return 1;
    if (braw_project_import(proj, argv[1]) < 0) { braw_project_destroy(proj); return 1; }

    int indices[] = {0};
    int ret = braw_export_start_inprocess(proj, indices, 1,
        atoi(argv[3]), atoi(argv[4]), atoi(argv[5]), atoi(argv[6]),
        argv[2], progressFn, nullptr);
    if (ret != 0) { braw_project_destroy(proj); return 1; }

    while (braw_export_is_running()) usleep(100000);
    braw_project_destroy(proj);
    return 0;
}
