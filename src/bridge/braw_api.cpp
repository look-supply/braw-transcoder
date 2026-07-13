#include "bridge/braw_api.h"
#include "core/Types.h"
#include "core/BrawDecoder.h"
#include "core/ProjectManager.h"
#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>

struct BrawClipHandle {
    std::unique_ptr<BrawDecoder> decoder;
    ClipAdjustments adjustments;
    std::string filePath;
    uint32_t nativeWidth  = 0;
    uint32_t nativeHeight = 0;
    float    frameRate    = 0;
    uint64_t frameCount   = 0;
    std::mutex decodeMutex;
    bool nativeCaptured = false;
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
    h->decoder = std::make_unique<BrawDecoder>();
    if (h->decoder->OpenClip(path)) {
        h->nativeWidth  = h->decoder->GetWidth();
        h->nativeHeight = h->decoder->GetHeight();
        h->frameRate    = h->decoder->GetFrameRate();
        h->frameCount   = h->decoder->GetFrameCount();
    }
    h->adjustments = {};
    return h;
}

void braw_clip_capture_native(BrawClipHandle* h) {
    if (h && h->decoder) {
        h->decoder->CaptureNativeSettings();
    }
}

const char* braw_clip_get_filename(BrawClipHandle* h) {
    if (!h) return "";
    size_t pos = h->filePath.rfind('/');
    return (pos != std::string::npos) ? h->filePath.c_str() + pos + 1 : h->filePath.c_str();
}

const char* braw_clip_get_filepath(BrawClipHandle* h) {
    return h ? h->filePath.c_str() : "";
}

const char* braw_clip_get_gamma(BrawClipHandle* h) {
    if (!h || !h->decoder) return "";
    static std::string gamma;
    gamma = h->decoder->GetClipGamma();
    return gamma.c_str();
}

const char* braw_clip_get_gamut(BrawClipHandle* h) {
    if (!h || !h->decoder) return "";
    static std::string gamut;
    gamut = h->decoder->GetClipGamut();
    return gamut.c_str();
}

uint16_t braw_clip_get_color_science_gen(BrawClipHandle* h) {
    return (h && h->decoder) ? h->decoder->GetColorScienceGen() : 0;
}

void braw_clip_close(BrawClipHandle* h) {
    if (h) {
        if (h->decoder) h->decoder->Close();
        delete h;
    }
}

uint32_t braw_clip_get_width(BrawClipHandle* h)      { return h ? h->nativeWidth : 0; }
uint32_t braw_clip_get_height(BrawClipHandle* h)     { return h ? h->nativeHeight : 0; }
float    braw_clip_get_frame_rate(BrawClipHandle* h) { return h ? h->frameRate : 0; }
uint64_t braw_clip_get_frame_count(BrawClipHandle* h){ return h ? h->frameCount : 0; }

uint32_t braw_clip_get_iso(BrawClipHandle* h)        { return h ? h->adjustments.iso : 0; }
void braw_clip_set_iso(BrawClipHandle* h, uint32_t v) { if (h) h->adjustments.iso = v; }
uint32_t braw_clip_get_color_temp(BrawClipHandle* h)  { return h ? h->adjustments.colorTemp : 0; }
void braw_clip_set_color_temp(BrawClipHandle* h, uint32_t v) { if (h) h->adjustments.colorTemp = v; }
int16_t  braw_clip_get_tint(BrawClipHandle* h)        { return h ? h->adjustments.tint : 0; }
void braw_clip_set_tint(BrawClipHandle* h, int16_t v) { if (h) h->adjustments.tint = v; }
float    braw_clip_get_exposure(BrawClipHandle* h)    { return h ? h->adjustments.exposure : 0; }
void braw_clip_set_exposure(BrawClipHandle* h, float v) { if (h) h->adjustments.exposure = v; }
bool braw_clip_get_highlight_recovery(BrawClipHandle* h) { return h ? h->adjustments.highlightRecovery : false; }
void braw_clip_set_highlight_recovery(BrawClipHandle* h, bool v) { if (h) h->adjustments.highlightRecovery = v; }
bool braw_clip_get_preview_lut(BrawClipHandle* h)     { return h ? h->adjustments.previewLUT : false; }
void braw_clip_set_preview_lut(BrawClipHandle* h, bool v) { if (h) h->adjustments.previewLUT = v; }
bool braw_clip_get_bake_lut(BrawClipHandle* h)        { return h ? h->adjustments.bakeLUT : false; }
void braw_clip_set_bake_lut(BrawClipHandle* h, bool v) { if (h) h->adjustments.bakeLUT = v; }

void braw_clip_copy_adjustments(BrawClipHandle* src, BrawClipHandle* dst) {
    if (src && dst) dst->adjustments = src->adjustments;
}

uint8_t* braw_clip_decode_frame(BrawClipHandle* h, uint64_t index, int* w, int* outH) {
    if (!h || !h->decoder) return nullptr;
    
    // Lazy native settings capture on first decode
    if (!h->nativeCaptured) {
        h->decoder->CaptureNativeSettings();
        h->adjustments.iso = h->decoder->GetNativeISO();
        h->adjustments.colorTemp = h->decoder->GetNativeColorTemp();
        h->adjustments.tint = h->decoder->GetNativeTint();
        h->adjustments.exposure = h->decoder->GetNativeExposure();
        h->nativeCaptured = true;
    }
    
    int bytesPerRow = 0;
    auto pixels = h->decoder->DecodeFrameSync(index, w, outH, &bytesPerRow, h->adjustments);
    if (pixels.empty()) return nullptr;
    uint8_t* out = (uint8_t*)malloc(pixels.size());
    memcpy(out, pixels.data(), pixels.size());
    return out;
}

uint8_t* braw_clip_decode_frame_scaled(BrawClipHandle* h, uint64_t index, int* w, int* outH, float scale) {
    if (!h || !h->decoder) return nullptr;
    
    if (!h->nativeCaptured) {
        h->decoder->CaptureNativeSettings();
        h->adjustments.iso = h->decoder->GetNativeISO();
        h->adjustments.colorTemp = h->decoder->GetNativeColorTemp();
        h->adjustments.tint = h->decoder->GetNativeTint();
        h->adjustments.exposure = h->decoder->GetNativeExposure();
        h->nativeCaptured = true;
    }
    
    int bytesPerRow = 0;
    auto pixels = h->decoder->DecodeFrameSync(index, w, outH, &bytesPerRow, h->adjustments, scale);
    if (pixels.empty()) return nullptr;
    uint8_t* out = (uint8_t*)malloc(pixels.size());
    memcpy(out, pixels.data(), pixels.size());
    return out;
}

void braw_clip_free_frame(uint8_t* data) {
    free(data);
}

// ── Project API ──────────────────────────────────

BrawProjectHandle* braw_project_create(void) {
    return new BrawProjectHandle();
}

void braw_project_destroy(BrawProjectHandle* h) {
    if (h) {
        for (auto* clip : h->clips) braw_clip_close(clip);
        delete h;
    }
}

int braw_project_import(BrawProjectHandle* h, const char* path) {
    if (!h) return -1;
    std::lock_guard<std::mutex> lock(h->mtx);
    auto* clip = braw_clip_open(path);
    if (!clip || clip->nativeWidth == 0) {
        braw_clip_close(clip);
        return -1;
    }
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

int braw_project_get_clip_count(BrawProjectHandle* h) {
    return h ? (int)h->clips.size() : 0;
}

BrawClipHandle* braw_project_get_clip(BrawProjectHandle* h, int index) {
    if (!h || index < 0 || index >= (int)h->clips.size()) return nullptr;
    return h->clips[index];
}

int braw_project_get_selected_index(BrawProjectHandle* h) {
    return h ? h->selectedIndex : -1;
}

void braw_project_set_selected_index(BrawProjectHandle* h, int index) {
    if (h) h->selectedIndex = index;
}

void braw_project_clear(BrawProjectHandle* h) {
    if (!h) return;
    std::lock_guard<std::mutex> lock(h->mtx);
    for (auto* clip : h->clips) braw_clip_close(clip);
    h->clips.clear();
    h->selectedIndex = -1;
}
