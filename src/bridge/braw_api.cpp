#include "bridge/braw_api.h"
#include "core/Types.h"
#include "core/BrawDecoder.h"
#include <CoreFoundation/CoreFoundation.h>
#include <string>
#include <vector>
#include <mutex>
#include <thread>
#include <chrono>

struct BrawClipHandle {
    std::unique_ptr<BrawDecoder> decoder;
    ClipAdjustments adjustments;
    std::string filePath;
    uint32_t nativeWidth  = 0;
    uint32_t nativeHeight = 0;
    float    frameRate    = 0;
    uint64_t frameCount   = 0;
    std::recursive_mutex decoderMutex;
    bool decoderOpen = false;
    std::string gamma;
    std::string gamut;
    uint16_t colorScienceGen = 0;
    std::string cameraType;
    uint32_t nativeISO = 0;
    uint32_t nativeColorTemp = 5600;
    int16_t  nativeTint = 0;
    float    nativeExposure = 0.0f;
    std::vector<std::pair<std::string, std::string>> freeFormMetadata;
    std::atomic<int> pendingOps{0};
};

struct BrawProjectHandle {
    std::vector<BrawClipHandle*> clips;
    int selectedIndex = -1;
    BrawClipHandle* clipboardSrc = nullptr;
    ClipAdjustments clipboard;
    bool hasClipboard = false;
    std::mutex mtx;
};

// ── Clip API ──────────────────────────────────────

BrawClipHandle* braw_clip_open(const char* path) {
    auto* h = new BrawClipHandle();
    h->filePath = path;
    h->adjustments = {};
    h->decoder = std::make_unique<BrawDecoder>();
    if (h->decoder->OpenClip(path)) {
        h->nativeWidth  = h->decoder->GetWidth();
        h->nativeHeight = h->decoder->GetHeight();
        h->frameRate    = h->decoder->GetFrameRate();
        h->frameCount   = h->decoder->GetFrameCount();
        h->gamma        = h->decoder->GetClipGamma();
        h->gamut        = h->decoder->GetClipGamut();
        h->colorScienceGen = h->decoder->GetColorScienceGen();
        h->cameraType   = h->decoder->GetCameraType();
        // Capture native camera settings (ISO, WB, tint, exposure)
        h->decoder->CaptureNativeSettings();
        h->nativeISO        = h->decoder->GetNativeISO();
        h->nativeColorTemp  = h->decoder->GetNativeColorTemp();
        h->nativeTint       = h->decoder->GetNativeTint();
        h->nativeExposure   = h->decoder->GetNativeExposure();
        // Initialize adjustments with native values (so Swift reads correct defaults)
        h->adjustments.iso        = h->nativeISO;
        h->adjustments.colorTemp  = h->nativeColorTemp;
        h->adjustments.tint       = h->nativeTint;
        // Read free-form metadata
        auto ffm = h->decoder->GetFreeFormMetadata();
        h->freeFormMetadata.assign(ffm.begin(), ffm.end());
    }
    h->decoder->Close();
    h->decoder.reset();
    h->decoderOpen = false;
    return h;
}

void braw_clip_ensure_decoder(BrawClipHandle* h) {
    if (!h) return;
    std::lock_guard<std::recursive_mutex> lock(h->decoderMutex);
    if (h->decoderOpen) return;
    if (!h->decoder) h->decoder = std::make_unique<BrawDecoder>();
    h->decoder->OpenClip(h->filePath);
    h->decoderOpen = true;
}

void braw_clip_release_decoder(BrawClipHandle* h) {
    if (!h) return;
    std::lock_guard<std::recursive_mutex> lock(h->decoderMutex);
    while (h->pendingOps.load() > 0)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (h->decoder) { h->decoder->Close(); h->decoder.reset(); }
    h->decoderOpen = false;
}

void braw_clip_close(BrawClipHandle* h) {
    if (!h) return;
    { std::lock_guard<std::recursive_mutex> lock(h->decoderMutex);
      if (h->decoder) h->decoder->Close(); }
    delete h;
}

// ── Metadata getters ──────────────────────────────

const char* braw_clip_get_filename(BrawClipHandle* h) {
    if (!h) return "";
    size_t pos = h->filePath.rfind('/');
    return (pos != std::string::npos) ? h->filePath.c_str() + pos + 1 : h->filePath.c_str();
}
const char* braw_clip_get_filepath(BrawClipHandle* h) { return h ? h->filePath.c_str() : ""; }
const char* braw_clip_get_gamma(BrawClipHandle* h)   { return h ? h->gamma.c_str() : ""; }
const char* braw_clip_get_gamut(BrawClipHandle* h)   { return h ? h->gamut.c_str() : ""; }
uint16_t  braw_clip_get_color_science_gen(BrawClipHandle* h) { return h ? h->colorScienceGen : 0; }
const char* braw_clip_get_camera_type(BrawClipHandle* h) { return h ? h->cameraType.c_str() : ""; }
uint32_t  braw_clip_get_width(BrawClipHandle* h)     { return h ? h->nativeWidth : 0; }
uint32_t  braw_clip_get_height(BrawClipHandle* h)    { return h ? h->nativeHeight : 0; }
float     braw_clip_get_frame_rate(BrawClipHandle* h){ return h ? h->frameRate : 0; }
uint64_t  braw_clip_get_frame_count(BrawClipHandle* h){ return h ? h->frameCount : 0; }
uint32_t braw_clip_get_native_iso(BrawClipHandle* h)        { return h ? h->nativeISO : 0; }
uint32_t braw_clip_get_native_color_temp(BrawClipHandle* h) { return h ? h->nativeColorTemp : 0; }
int16_t  braw_clip_get_native_tint(BrawClipHandle* h)       { return h ? h->nativeTint : 0; }
float    braw_clip_get_native_exposure(BrawClipHandle* h)    { return h ? h->nativeExposure : 0.0f; }
void     braw_clip_capture_native(BrawClipHandle* h) {
    if (!h) return;
    std::lock_guard<std::recursive_mutex> lock(h->decoderMutex);
    braw_clip_ensure_decoder(h);
    h->decoder->CaptureNativeSettings();
    h->nativeISO       = h->decoder->GetNativeISO();
    h->nativeColorTemp = h->decoder->GetNativeColorTemp();
    h->nativeTint      = h->decoder->GetNativeTint();
    h->nativeExposure  = h->decoder->GetNativeExposure();
}
int braw_clip_get_metadata_count(BrawClipHandle* h) { return h ? (int)h->freeFormMetadata.size() : 0; }
const char* braw_clip_get_metadata_key(BrawClipHandle* h, int i) {
    if (!h || i < 0 || i >= (int)h->freeFormMetadata.size()) return "";
    return h->freeFormMetadata[i].first.c_str();
}
const char* braw_clip_get_metadata_value(BrawClipHandle* h, int i) {
    if (!h || i < 0 || i >= (int)h->freeFormMetadata.size()) return "";
    return h->freeFormMetadata[i].second.c_str();
}

// ── Adjustments ───────────────────────────────────

uint32_t braw_clip_get_iso(BrawClipHandle* h)               { return h ? h->adjustments.iso : 0; }
void braw_clip_set_iso(BrawClipHandle* h, uint32_t v)       { if (h) h->adjustments.iso = v; }
uint32_t braw_clip_get_color_temp(BrawClipHandle* h)         { return h ? h->adjustments.colorTemp : 0; }
void braw_clip_set_color_temp(BrawClipHandle* h, uint32_t v) { if (h) h->adjustments.colorTemp = v; }
int16_t  braw_clip_get_tint(BrawClipHandle* h)               { return h ? h->adjustments.tint : 0; }
void braw_clip_set_tint(BrawClipHandle* h, int16_t v)       { if (h) h->adjustments.tint = v; }
float    braw_clip_get_exposure(BrawClipHandle* h)           { return h ? h->adjustments.exposure : 0; }
void braw_clip_set_exposure(BrawClipHandle* h, float v)     { if (h) h->adjustments.exposure = v; }
bool braw_clip_get_highlight_recovery(BrawClipHandle* h)     { return h ? h->adjustments.highlightRecovery : false; }
void braw_clip_set_highlight_recovery(BrawClipHandle* h, bool v) { if (h) h->adjustments.highlightRecovery = v; }
bool braw_clip_get_preview_lut(BrawClipHandle* h)            { return h ? h->adjustments.previewLUT : false; }
void braw_clip_set_preview_lut(BrawClipHandle* h, bool v)   { if (h) h->adjustments.previewLUT = v; }
bool braw_clip_get_bake_lut(BrawClipHandle* h)               { return h ? h->adjustments.bakeLUT : false; }
void braw_clip_set_bake_lut(BrawClipHandle* h, bool v)      { if (h) h->adjustments.bakeLUT = v; }
void braw_clip_copy_adjustments(BrawClipHandle* src, BrawClipHandle* dst) { if (src && dst) dst->adjustments = src->adjustments; }

// ── Decode ────────────────────────────────────────

uint8_t* braw_clip_decode_frame(BrawClipHandle* h, uint64_t index, int* w, int* outH) {
    if (!h) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(h->decoderMutex);
    braw_clip_ensure_decoder(h);
    int bpr = 0;
    h->pendingOps++;
    auto pixels = h->decoder->DecodeFrameSync(index, w, outH, &bpr, h->adjustments);
    h->pendingOps--;
    if (pixels.empty()) return nullptr;
    uint8_t* out = (uint8_t*)malloc(pixels.size());
    memcpy(out, pixels.data(), pixels.size());
    return out;
}

void braw_clip_free_frame(uint8_t* data) { free(data); }

void* braw_clip_decode_frame_gpu(BrawClipHandle* h, uint64_t index, int* w, int* outH) {
    if (!h) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(h->decoderMutex);
    braw_clip_ensure_decoder(h);
    int bpr = 0;
    h->pendingOps++;
    void* result = h->decoder->DecodeFrameGPU(index, w, outH, &bpr, h->adjustments);
    h->pendingOps--;
    return result;
}

void braw_clip_free_frame_gpu(void* buf) { if (buf) CFRelease(buf); }

void* braw_clip_decode_frame_gpu_scaled(BrawClipHandle* h, uint64_t index, int* w, int* outH, float scale) {
    if (!h) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(h->decoderMutex);
    braw_clip_ensure_decoder(h);
    int bpr = 0;
    h->pendingOps++;
    void* result = h->decoder->DecodeFrameGPUScaled(index, w, outH, &bpr, h->adjustments, scale);
    h->pendingOps--;
    return result;
}

// Legacy stubs (Swift side still calls these)
extern "C" int64_t braw_get_resident_memory(void) { return 0; }
extern "C" void braw_pressure_relief(void) {}
extern "C" void braw_log_init_path(const char*) {}

float* braw_clip_extract_audio(BrawClipHandle* h, uint32_t* sr, uint32_t* ch, uint64_t* sc) {
    if (!h) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(h->decoderMutex);
    braw_clip_ensure_decoder(h);
    return h->decoder->ExtractAudio(sr, ch, sc);
}

// ── Project API ──────────────────────────────────

BrawProjectHandle* braw_project_create(void) { return new BrawProjectHandle(); }

void braw_project_destroy(BrawProjectHandle* h) {
    if (h) { for (auto* c : h->clips) braw_clip_close(c); delete h; }
}

int braw_project_import(BrawProjectHandle* h, const char* path) {
    if (!h) return -1;
    std::lock_guard<std::mutex> lock(h->mtx);
    auto* clip = braw_clip_open(path);
    if (!clip || clip->nativeWidth == 0) { braw_clip_close(clip); return -1; }
    h->clips.push_back(clip);
    if (h->selectedIndex < 0) h->selectedIndex = 0;
    return (int)(h->clips.size() - 1);
}

void braw_project_remove(BrawProjectHandle* h, int index) {
    if (!h) return;
    std::lock_guard<std::mutex> lock(h->mtx);
    if (index < 0 || index >= (int)h->clips.size()) return;
    braw_clip_close(h->clips[index]);
    h->clips.erase(h->clips.begin() + index);
    if (h->clips.empty()) h->selectedIndex = -1;
    else if (h->selectedIndex >= (int)h->clips.size()) h->selectedIndex = (int)(h->clips.size() - 1);
}

int braw_project_get_clip_count(BrawProjectHandle* h) { return h ? (int)h->clips.size() : 0; }
BrawClipHandle* braw_project_get_clip(BrawProjectHandle* h, int index) {
    return (!h || index < 0 || index >= (int)h->clips.size()) ? nullptr : h->clips[index];
}
int  braw_project_get_selected_index(BrawProjectHandle* h) { return h ? h->selectedIndex : -1; }
void braw_project_set_selected_index(BrawProjectHandle* h, int index) { if (h) h->selectedIndex = index; }

void braw_project_clear(BrawProjectHandle* h) {
    if (!h) return;
    std::lock_guard<std::mutex> lock(h->mtx);
    for (auto* c : h->clips) braw_clip_close(c);
    h->clips.clear();
    h->selectedIndex = -1;
}
