#include "bridge/braw_api.h"
#include "core/BrawDecoder.h"
#include "core/Types.h"
#include <iostream>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <chrono>

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : nullptr;
    const char* mode = argc > 2 ? argv[2] : "meta";

    if (!path) {
        std::cerr << "Usage: braw_test <file.braw> [meta|export]" << std::endl;
        return 1;
    }

    if (strcmp(mode, "export") == 0) {
        const char* outDir = "/tmp/braw_export_test";
        system("rm -rf /tmp/braw_export_test && mkdir -p /tmp/braw_export_test");

        BrawProjectHandle* proj = braw_project_create();
        int idx = braw_project_import(proj, path);
        if (idx < 0) { std::cerr << "FAIL: import" << std::endl; return 1; }

        printf("Exporting H.265 1080p passthrough, 200 Mbps...\n");
        int indices[] = {0};
        braw_export_start(proj, indices, 1, 1, 3, 4, 200, outDir,
            [](int ci, int tc, int fi, int tf, void*) {
                if (fi >= 0 && fi % 10 == 0)
                    printf("\rFrame %d/%d", fi+1, tf);
                fflush(stdout);
            }, nullptr);

        while (braw_export_is_running()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
        printf("\nDone.\n");
        braw_project_destroy(proj);
        return 0;
    }

    // Meta mode
    BrawDecoder decoder;
    if (!decoder.OpenClip(path)) { std::cerr << "FAIL: OpenClip" << std::endl; return 1; }

    printf("Width:      %d\n", decoder.GetWidth());
    printf("Height:     %d\n", decoder.GetHeight());
    printf("Frame rate: %.2f\n", decoder.GetFrameRate());
    printf("Frames:     %llu\n", decoder.GetFrameCount());
    printf("Camera:     %s\n", decoder.GetCameraType().c_str());
    printf("Gamma:      %s\n", decoder.GetClipGamma().c_str());
    printf("Gamut:      %s\n", decoder.GetClipGamut().c_str());
    printf("Color Gen:  %d\n", decoder.GetColorScienceGen());

    decoder.CaptureNativeSettings();
    printf("Native ISO:  %d\n", decoder.GetNativeISO());
    printf("Native temp: %dK\n", decoder.GetNativeColorTemp());
    printf("Native tint: %d\n", decoder.GetNativeTint());

    int dw=0, dh=0, dbpr=0;
    ClipAdjustments adj = {};
    auto px = decoder.DecodeFrameSync(0, &dw, &dh, &dbpr, adj, 1.0f);
    printf("Frame 0:     %dx%d %s\n", dw, dh, px.empty() ? "FAIL" : "OK");

    decoder.Close();
    return 0;
}
