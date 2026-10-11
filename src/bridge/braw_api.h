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
void            braw_clip_retain(BrawClipHandle* h);
const char*     braw_clip_last_error(BrawClipHandle* h);
void            braw_clip_close(BrawClipHandle* h);
void            braw_clip_ensure_decoder(BrawClipHandle* h);
void            braw_clip_release_decoder(BrawClipHandle* h);
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

void braw_clip_copy_adjustments(BrawClipHandle* src, BrawClipHandle* dst);

typedef struct {
    uint32_t iso, temperature;
    int16_t tint;
    float exposure;
    bool highlightRecovery, previewLUT;
} BrawClipSettings;
BrawClipSettings braw_clip_get_settings(BrawClipHandle* h);

// Decode a single frame to BGRA8 CPU buffer with current adjustments applied.
// Caller must free the returned buffer with braw_clip_free_frame().
uint8_t* braw_clip_decode_frame(BrawClipHandle* h, uint64_t index, int* w, int* outH);
uint8_t* braw_clip_decode_frame_scaled(BrawClipHandle* h, uint64_t index, int* w, int* outH, float scale);
void     braw_clip_free_frame(uint8_t* data);

// Audio extraction: returns PCM float samples (caller frees with free())
float*   braw_clip_extract_audio(BrawClipHandle* h, uint32_t* sampleRate,
                                  uint32_t* channels, uint64_t* sampleCount);
// Audio format query without extracting.
bool     braw_clip_get_audio_format(BrawClipHandle* h, uint32_t* sampleRate,
                                     uint32_t* channels);

// ── Project API ──────────────────────────────────
BrawProjectHandle* braw_project_create(void);
void               braw_project_destroy(BrawProjectHandle* h);
// Returns the new index, -1 on failure, or -2 when the same file is already imported.
int                braw_project_import(BrawProjectHandle* h, const char* path);
void               braw_project_remove(BrawProjectHandle* h, int index);
int                braw_project_get_clip_count(BrawProjectHandle* h);
BrawClipHandle*    braw_project_get_clip(BrawProjectHandle* h, int index);
// Returns a retained handle, safe to keep across asynchronous operations.
BrawClipHandle*    braw_project_get_clip_retained(BrawProjectHandle* h, int index);
int                braw_project_get_selected_index(BrawProjectHandle* h);
void               braw_project_set_selected_index(BrawProjectHandle* h, int index);
void               braw_project_clear(BrawProjectHandle* h);

// ── Export API ──────────────────────────────────
typedef void (*ExportProgressFn)(int clipIndex, int totalClips,
                                  int frameIndex, int totalFrames, void* ctx);

// Export one or more clips through an isolated decoder and streaming encoder.
// Blocks until completion, failure, or cancellation. Call on a background thread.
// Returns 0 on success, -1 on failure, -2 on cancellation.
// Reserve an export before scheduling background work, so immediate cancellation is honored.
int  braw_export_prepare(void);
int  braw_export_start(BrawProjectHandle* proj, const int* indices, int count,
                        int codec, int proResProfile, int resolutionMode, int dataRateMbps,
                        const char* outputDir,
                        ExportProgressFn progressFn, void* ctx);
int  braw_export_is_running(void);
void braw_export_cancel(void);
void braw_export_reset(void);  // No-op while an export is active.
const char* braw_export_last_error(void);
void braw_diag_log(const char* msg);
int64_t braw_get_resident_memory(void);

// ── Gyro Data API ──────────────────────────────
void braw_set_export_gyro(int enabled);
int  braw_get_export_gyro(void);
void braw_kill_stale_processes(void);
int  braw_clip_write_gyroflow_sidecar(BrawClipHandle* h, const char* outputMovPath);

#ifdef __cplusplus
}
#endif
