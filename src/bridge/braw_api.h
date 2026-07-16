#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BrawClipHandle BrawClipHandle;
typedef struct BrawProjectHandle BrawProjectHandle;

// ── Clip API ──────────────────────────────────────
BrawClipHandle* braw_clip_open(const char* path);
void            braw_clip_close(BrawClipHandle* h);
void            braw_clip_ensure_decoder(BrawClipHandle* h);  // lazy-create decoder
void            braw_clip_release_decoder(BrawClipHandle* h); // free decoder memory
void            braw_clip_capture_native(BrawClipHandle* h);
const char*     braw_clip_get_filename(BrawClipHandle* h);
const char*     braw_clip_get_filepath(BrawClipHandle* h);
const char*     braw_clip_get_gamma(BrawClipHandle* h);
const char*     braw_clip_get_gamut(BrawClipHandle* h);
uint16_t        braw_clip_get_color_science_gen(BrawClipHandle* h);
const char*     braw_clip_get_camera_type(BrawClipHandle* h);
uint32_t        braw_clip_get_width(BrawClipHandle* h);
uint32_t        braw_clip_get_height(BrawClipHandle* h);
float           braw_clip_get_frame_rate(BrawClipHandle* h);
uint64_t        braw_clip_get_frame_count(BrawClipHandle* h);

// Native camera settings (captured on first decode)
uint32_t braw_clip_get_native_iso(BrawClipHandle* h);
uint32_t braw_clip_get_native_color_temp(BrawClipHandle* h);
int16_t  braw_clip_get_native_tint(BrawClipHandle* h);
float    braw_clip_get_native_exposure(BrawClipHandle* h);
void     braw_clip_capture_native(BrawClipHandle* h);

// Free-form metadata from BRAW file
int            braw_clip_get_metadata_count(BrawClipHandle* h);
const char*    braw_clip_get_metadata_key(BrawClipHandle* h, int index);
const char*    braw_clip_get_metadata_value(BrawClipHandle* h, int index);

// Adjustments (get/set)
uint32_t braw_clip_get_iso(BrawClipHandle* h);
void     braw_clip_set_iso(BrawClipHandle* h, uint32_t v);
uint32_t braw_clip_get_color_temp(BrawClipHandle* h);
void     braw_clip_set_color_temp(BrawClipHandle* h, uint32_t v);
int16_t  braw_clip_get_tint(BrawClipHandle* h);
void     braw_clip_set_tint(BrawClipHandle* h, int16_t v);
float    braw_clip_get_exposure(BrawClipHandle* h);
void     braw_clip_set_exposure(BrawClipHandle* h, float v);
bool     braw_clip_get_highlight_recovery(BrawClipHandle* h);
void     braw_clip_set_highlight_recovery(BrawClipHandle* h, bool v);
bool     braw_clip_get_preview_lut(BrawClipHandle* h);
void     braw_clip_set_preview_lut(BrawClipHandle* h, bool v);
bool     braw_clip_get_bake_lut(BrawClipHandle* h);
void     braw_clip_set_bake_lut(BrawClipHandle* h, bool v);

void braw_clip_copy_adjustments(BrawClipHandle* src, BrawClipHandle* dst);

// Decode a single frame to BGRA8 CPU buffer with current adjustments applied
uint8_t* braw_clip_decode_frame(BrawClipHandle* h, uint64_t index, int* w, int* outH);
uint8_t* braw_clip_decode_frame_scaled(BrawClipHandle* h, uint64_t index, int* w, int* outH, float scale);
void     braw_clip_free_frame(uint8_t* data);

// GPU decode: returns retained MTLBuffer (caller must call braw_clip_free_frame_gpu)
void*    braw_clip_decode_frame_gpu(BrawClipHandle* h, uint64_t index, int* w, int* outH);
// GPU decode at reduced scale: returns retained MTLBuffer (caller must call braw_clip_free_frame_gpu)
void*    braw_clip_decode_frame_gpu_scaled(BrawClipHandle* h, uint64_t index, int* w, int* outH, float scale);
// Free a GPU frame buffer returned by braw_clip_decode_frame_gpu / _scaled
void     braw_clip_free_frame_gpu(void* buf);

// Audio extraction: returns PCM float samples (caller frees with free())
float*   braw_clip_extract_audio(BrawClipHandle* h, uint32_t* sampleRate,
                                  uint32_t* channels, uint64_t* sampleCount);

// ── Project API ──────────────────────────────────
BrawProjectHandle* braw_project_create(void);
void               braw_project_destroy(BrawProjectHandle* h);
int                braw_project_import(BrawProjectHandle* h, const char* path);
void               braw_project_remove(BrawProjectHandle* h, int index);
int                braw_project_get_clip_count(BrawProjectHandle* h);
BrawClipHandle*    braw_project_get_clip(BrawProjectHandle* h, int index);
int                braw_project_get_selected_index(BrawProjectHandle* h);
void               braw_project_set_selected_index(BrawProjectHandle* h, int index);
void braw_project_clear(BrawProjectHandle* h);

// ── Export API ──────────────────────────────────
typedef void (*ExportProgressFn)(int clipIndex, int totalClips, int frameIndex, int totalFrames, void* ctx);

int  braw_export_start(BrawProjectHandle* proj, const int* indices, int count,
                        int codec, int proResProfile, int resolutionMode, int dataRateMbps,
                        const char* outputDir,
                        ExportProgressFn progressFn, void* ctx);
int  braw_export_start_inprocess(BrawProjectHandle* proj, const int* indices, int count,
                                  int codec, int proResProfile, int resolutionMode, int dataRateMbps,
                                  const char* outputDir,
                                  ExportProgressFn progressFn, void* ctx);
void braw_export_cancel(void);
int  braw_export_is_running(void);
void braw_export_cleanup(void);

#ifdef __cplusplus
}
#endif
