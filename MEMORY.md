# BRAW Transcoder — Architecture & Engineering Notes

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI App (BrawTranscoderApp)                        │
│  ├─ ContentView (HSplitView layout)                     │
│  │  ├─ SidebarView   (clip list + thumbnails)           │
│  │  ├─ PreviewView   (Metal-backed frame viewer)        │
│  │  ├─ InspectorView (ISO/temp/tint/exposure/LUT)       │
│  │  └─ ExportView    (codec/resolution/bitrate/export)  │
│  └─ ProjectModel + ClipModel + ExportManager            │
├─────────────────────────────────────────────────────────┤
│  C Bridge (braw_api.h — @_silgen_name to Swift)         │
│  ├─ BrawClipHandle     (per-clip state)                 │
│  ├─ BrawProjectHandle  (clip list in C++)               │
│  └─ braw_export_start / cancel / is_running             │
├─────────────────────────────────────────────────────────┤
│  C++ Core (braw_core static library)                    │
│  ├─ BrawDecoder        (wraps Blackmagic RAW SDK)       │
│  │   └─ RequestFrame() → ReadComplete → ProcessComplete │
│  │       → staging MTLBuffer (metal) or CPU copy (cpub) │
│  ├─ braw_api.cpp       (handle management)              │
│  │   └─ pendingOps atomic counter for safe destroy      │
│  └─ braw_export.mm     (AVAssetWriter + Metal pipeline) │
│      └─ requestMediaDataWhenReady + decoder reset N=10  │
└─────────────────────────────────────────────────────────┘
```

### Threading Model

| Thread | Role |
|---|---|
| **Main thread** | SwiftUI rendering, user input, inspector changes |
| **importQueue** (serial, .userInitiated) | BRAW SDK import — one at a time |
| **decodeQueue** (concurrent, semaphore=3) | Thumbnail and preview frame decodes |
| **export video** (`requestMediaDataWhenReady`) | Frame decode + writer feed (back-pressure) |
| **export audio** (`.default` QOS) | AAC encode + mux |
| **BRAW SDK internal** (managed by SDK) | `ReadComplete`, `ProcessComplete` callbacks |

---

## Data Flows

### Preview
```
ClipModel.loadPreviewFrame()
  → ClipModel.decodeQueue.async (semaphore=3 wait)
    → braw_clip_decode_frame(h, frameIdx)
      → braw_clip_ensure_decoder(h)  // lazy decoder open
      → BrawDecoder::DecodeFrameSync()
        → RequestFrame() → BRAW SDK decode
          → ReadComplete: SetResolutionScale, clone attrs, set ISO/temp/tint
          → ProcessComplete: copy SDK buffer → staging MTLBuffer
        → callback: memcpy staging → std::vector<uint8_t>
      → malloc + memcpy → uint8_t* returned to Swift
    → makeNSImage(pixels) → CGImage → NSImage
    → DispatchQueue.main: clip.preview = img
  → clip.loadRequestID check (discard stale results)
```

### Export
```
ExportManager.export()
  → braw_export_start()
    → dispatch_async(global QOS)
      → exportMOV()
        → AVAssetWriter (QuickTime .mov)
        → audio: braw_clip_extract_audio()
        → video: requestMediaDataWhenReady
          ┌─────────────────────────────────┐
          │ while readyForMoreMediaData:    │
          │   if frameIdx % 10 == 0:       │
          │     release_decoder(clip)       │
          │     cmdQ=nil; device=nil        │
          │     malloc_zone_pressure_relief │
          │     usleep(100ms)               │
          │     MTLCreateSystemDefaultDevice│
          │     CVMetalTextureCacheCreate   │
          │     ensure_decoder(clip)        │
          │                                 │
          │   braw_clip_decode_frame_gpu()  │
          │     → MTLBuffer (GPU-resident)  │
          │   CVPixelBufferPool → CVPixelBuf│
          │   CVMetalTextureCache → MTLTex  │
          │   MTLBlitCommandEncoder:        │
          │     GPU buffer → texture copy   │
          │   adaptor.appendPixelBuffer     │
          │   frameIdx++                    │
          └─────────────────────────────────┘
        → [videoInput markAsFinished]
        → [writer finishWriting]
```

---

## Key Source Files

| File | Role | Language |
|---|---|---|---|
| `src/app/BrawTranscoderApp.swift` | SwiftUI `@main` entry | Swift |
| `src/app/ProjectModel.swift` | `ClipModel`, `ProjectModel`, `ExportManager` | Swift |
| `src/app/MetalPreviewRenderer.swift` | GPU-backed NSImage from MTLBuffer (shared Metal device/cache) | Swift |
| `src/app/Views/SidebarView.swift` | Clip list, multi-select, thumbnails | Swift |
| `src/app/Views/PreviewView.swift` | Preview + jog slider | Swift |
| `src/app/Views/InspectorView.swift` | ISO/WB presets, HL recovery, LUT | Swift |
| `src/app/Views/ExportView.swift` | Codec/resolution/bitrate, progress | Swift |
| `src/bridge/braw_api.h` | C API header (extern "C") | C |
| `src/bridge/braw_api.cpp` | Handle lifecycle, `recursive_mutex`, decode | C++ |
| `src/bridge/braw_export.mm` | AVAssetWriter + Metal pipeline + decoder reset | ObjC++ |
| `src/core/BrawDecoder.h/.mm` | BRAW SDK wrapper, RequestFrame, callbacks | ObjC++ |
| `src/core/Types.h` | ClipAdjustments, ClipInfo, ExportSettings | C++ |
| `CMakeLists.txt` | Build system (Ninja + Swift) | CMake |
| `build.sh` | Build/run/clean dispatch | Bash |

---

## Persistent Issues & Crash History — Complete Log

### 1. ImGui DockBuilder Crash (RESOLVED — switched to SwiftUI)
**Symptom**: SIGSEGV at `ImGui::DockBuilderAddNode` — docking subsystem not initialized.
**Root cause**: Cloned `master` branch of ImGui without docking support.
**Fix**: Replaced ImGui with SwiftUI native macOS views.

### 2. App Init Crash (@StateObject + init, RESOLVED)
**Symptom**: SIGSEGV immediately on launch inside `ExportView.body.getter`.
**Root cause**: Custom `App.init()` called `project.importClip()` before `@StateObject` storage was wired.
**Fix**: Removed custom init. Use `.task` / `.onAppear` for startup logic.

### 3. Static Callback Race (RESOLVED)
**Symptom**: `objc_retain` crash on garbage `MTLBuffer` when importing multiple clips.
**Root cause**: `static BrawDecoderCallback` shared across decoders. Concurrent decodes overwrote `callback.impl`.
**Fix**: Each decoder allocates own callback via `new BrawDecoderCallback()`.

### 4. MTLBuffer Dangling After ProcessComplete (RESOLVED)
**Symptom**: `objc_retain` crash at `(__bridge id<MTLBuffer>)metalBuffer` in `DecodeFrameSync`'s callback lambda.
**Root cause**: SDK frees processed image after `ProcessComplete` returns, but `RequestFrame` accesses buffer after that point.
**Fix**: Immediately blit to decoder-owned `MTLStorageModeShared` buffer in `ProcessComplete`. Handles `'cpub'` and `'metb'` resource types.

### 5. CLI Resource Type Mismatch (RESOLVED)
**Symptom**: Crash when decoding from command line (no window server — GPU unavailable).
**Root cause**: SDK returns CPU buffer (`'cpub'`) but code blindly cast to `id<MTLBuffer>` (`'metb'`).
**Fix**: Check `BlackmagicRawResourceType` before casting. CPU path uses `[device newBufferWithBytes:]`.

### 6. All Decoders Open — 100GB OOM (RESOLVED)
**Symptom**: OS kills process after importing 5–10 clips. Memory hits 100GB.
**Root cause**: `ClipModel.init` called `braw_clip_get_gamma()` → `braw_clip_ensure_decoder()` → opened Metal pipeline for EVERY clip. 76 × ~1.3GB.
**Fix**:
- `braw_clip_open` reads metadata then immediately destroys decoder.
- Gamma/gamut/colorGen stored as strings on handle.
- `braw_clip_ensure_decoder()` called lazily on first decode.
- Only ONE decoder open at a time. Switching clips destroys previous.

### 7. Mutex Destroyed While In Use (RESOLVED)
**Symptom**: `libc++abi: terminating ... mutex lock failed: Invalid argument` | `Abort trap: 6`.
**Root cause**: `release_decoder` destroyed decoder (and its mutex) while background decode still held the mutex inside `condition_variable.wait()`.
**Fix**: `std::atomic<int> pendingOps` incremented before each decode, decremented after. `release_decoder` spin-waits `while (pendingOps > 0)`.

### 8. AVAssetWriter Buffers All Frames — 90GB OOM (RESOLVED)
**Symptom**: 90GB RAM during export of 2 × 519-frame 6K clips.
**Root cause**: Manual loop fed all frames to `adaptor.appendPixelBuffer:` which retains every buffer until `finishWriting`. 519 × 97MB = 50GB/clip.
**Fix**: `requestMediaDataWhenReady` provides back-pressure. In-flight frames constrained to ~3–5. Peak 90GB → ~4GB.

### 9. Preview LUT Leaked Into Export (RESOLVED)
**Symptom**: Toggling "Preview Embedded LUT" (preview-only) also applied LUT to exported files.
**Root cause**: `ReadComplete` checked `previewLUT || bakeLUT`.
**Fix**: Export saves `previewLUT`, sets it to `false` for the loop duration, restores after.

### 10. Thumbnails Simultaneous — Thread Pool Exhaustion (RESOLVED)
**Symptom**: Crashes importing many files — SDK spawns ~20 threads per decoder, 76 = 1500+.
**Root cause**: `ClipModel.init` dispatched `loadThumbnail()` on `DispatchQueue.global()` for every clip.
**Fix**:
- On-demand loading via `.onAppear` in `SidebarView`.
- Concurrent queue with `DispatchSemaphore(value: 3)` — max 3 simultaneous.
- Serial `importQueue` — one `OpenClip` at a time.

### 11. FlushJobs Hangs SDK (UNRESOLVED — MITIGATED)
**Symptom**: `IBlackmagicRaw::FlushJobs()` blocks forever on any clip.
**Root cause**: Unknown. Likely SDK internal deadlock.
**Workaround**: Removed call. `Close()` just calls `Release()` on codec/clip/factory.
**Consequence**: ~500MB per decoder lifecycle persists until process exit.
**Mitigation**: Periodic decoder reset (destroy + recreate every 10 frames) + `malloc_zone_pressure_relief()` + Metal device recreation.

### 12. Preview Not Observing ClipModel (RESOLVED)
**Symptom**: Preview shows "loading" indefinitely. Frame decodes but image never appears.
**Root cause**: `PreviewView` had `@ObservedObject var project` but not `@ObservedObject var clip`.
**Fix**: Extracted `PreviewContent` with `@ObservedObject var clip: ClipModel`. `@Published` changes now trigger re-render.

### 13. ClipModel Not Cached (RESOLVED)
**Symptom**: Thumbnail loaded on one instance, preview on another, view reads a third.
**Root cause**: `getClip(at:)` created fresh `ClipModel` each call.
**Fix**: `clipCache: [Int: ClipModel]`. Returns cached instance. Updated on remove with index shifting.

### 14. Export 8-bit Instead of 10-bit (RESOLVED)
**Symptom**: Exported HEVC shows `yuv420p`, `profile=Main` (8-bit).
**Root cause**: `AVVideoProfileLevelKey: @"HEVC_Main_AutoLevel"`.
**Fix**: Changed to `@"HEVC_Main10_AutoLevel"` → `yuv420p10le`, `Main 10`. Verified by ffprobe.

### 15. Audio Was AAC (Lossy) (RESOLVED)
**Symptom**: Audio encoded as AAC 256kbps instead of lossless original.
**Root cause**: `kAudioFormatMPEG4AAC` used in audio settings.
**Fix**: Changed to `kAudioFormatLinearPCM`, 32-bit float, original sample rate.

### 16. Frame Slider Doesn't Re-Decode (RESOLVED)
**Symptom**: Dragging jog slider updates `currentFrame` but preview doesn't change.
**Root cause**: `guard !isLoadingPreview else { return }` dropped all slider events.
**Fix**: Request ID counter. Each call increments, stale results discarded on completion.

### 17. Inspector Changes Don't Update Preview (RESOLVED)
**Symptom**: Moving ISO/Temp/Tint/Exposure sliders has no visible effect.
**Root cause**: `didSet` synced to C handle but never triggered frame re-decode with new adjustments.
**Fix**: `schedulePreviewRefresh()` — 150ms debounced `DispatchWorkItem` called from every adjustment `didSet`.

### 18. Import Not Serialized (RESOLVED)
**Symptom**: Importing multiple files crashes BRAW SDK.
**Root cause**: `importClip` called on main thread; concurrent `NSOpenPanel.allowsMultipleSelection`.
**Fix**: Serial `importQueue` (`label: "com.braw.import"`). UI updates on main thread.

### 19. Export Thread VT Crash (RESOLVED)
**Symptom**: `VTCompressionSessionCreate` crashes with ObjC exception from `std::thread`.
**Root cause**: VideoToolbox requires dispatch run loop — raw pthread lacks it.
**Fix**: `dispatch_async` on serial `dispatch_queue_t` instead of `std::thread`.

### 20. Export Moov Atom Missing (RESOLVED)
**Symptom**: `.mov` shows "moov atom not found" — unplayable.
**Root cause**: Async `finishWritingWithCompletionHandler` hadn't fired when process exited.
**Fix**: Spin-wait on `writer.status == AVAssetWriterStatusWriting` after finishWriting.

### 21. Decoder Reset Every 10 Frames (IMPLEMENTED)
**Symptom**: Long exports accumulate SDK GPU memory unboundedly (~500MB/decoder lifecycle).
**Root cause**: `FlushJobs` hangs (see #11). SDK doesn't fully release on `Close()`/`Release()`.
**Fix**: Every 10 frames: release decoder, destroy Metal objects, `malloc_zone_pressure_relief`, 100ms drain, recreate. Measured: 3–6GB vs 90GB+.

### 22. LUT State After Decoder Reset (RESOLVED)
**Symptom**: After decoder reset during export, `bakeLUT` toggle had no effect.
**Root cause**: Fresh decoder doesn't carry over LUT adjustment state.
**Fix**: Explicitly re-apply `previewLUT = false` after `braw_clip_ensure_decoder`.

### 23. Multi-Clip Decoder Race — Thread Safety (RESOLVED)
**Symptom**: Crash when switching between clips during decode. `braw_clip_release_decoder` destroyed decoder while `braw_clip_decode_frame` was still executing on background queue.
**Root cause**: `BrawClipHandle` had an unused `std::mutex decodeMutex`. `braw_clip_ensure_decoder`, `braw_clip_release_decoder`, and all decode functions accessed the decoder without synchronization. Timeline: (A) decode starts on background queue, (B) user clicks new clip → `release_decoder` on main thread destroys decoder, (C) decode resumes on destroyed decoder → use-after-free.
**Fix**: Replaced unused `std::mutex` with `std::recursive_mutex decoderMutex`. Locked in every decoder lifecycle operation: `ensure_decoder`, `release_decoder`, `decode_frame`, `decode_frame_gpu`, `extract_audio`, `capture_native`, `close`, `reset_decoder`. `release_decoder` now blocks until any in-progress decode completes before destroying.

### 24. GPU-Accelerated Thumbnails & Preview (IMPLEMENTED)
**Symptom**: Thumbnails and preview used CPU-only decode path (`braw_clip_decode_frame`), creating NSImage via software rendering. Export used GPU path (`braw_clip_decode_frame_gpu`) but preview/thumbs did not.
**Root cause**: `loadThumbnail()` and `loadPreviewFrame()` always called CPU decode + `makeNSImage()` (BGRA pixels → `CGDataProvider` → `CGImage` → `NSImage`).
**Fix**:
- Created `MetalPreviewRenderer.swift` — shared singleton managing `MTLDevice`, `MTLCommandQueue`, `CVMetalTextureCache`, `CIContext`. Provides GPU-backed NSImage creation from Metal buffers: blits MTLBuffer → CVPixelBuffer (IOSurface, zero-copy) → CIImage → NSCIImageRep → NSImage.
- `loadThumbnail()` uses `braw_clip_decode_frame_gpu_scaled(h, 0, &w, &h, 0.25)` (quarter-res GPU decode) + readback via MTLBuffer contents.
- `loadPreviewFrame()` uses `braw_clip_decode_frame_gpu(h, frameIdx, &w, &h)` (full-res GPU decode) + CVPixelBuffer blit for GPU-to-display pipeline.
- Added `braw_clip_decode_frame_gpu_scaled` C API + `DecodeFrameGPUScaled` on BrawDecoder.
- Added `braw_clip_free_frame_gpu` C API for safe MTLBuffer release from any language.

### 25. Multi-Clip Concurrent Decode Test (IMPLEMENTED)
**Symptom**: No regression test existed for concurrent multi-clip decode + release cycles.
**Root cause**: Test only covered single-clip passthrough export.
**Fix**: Rewrote `test/main.cpp` with two test phases:
- **`testMultiClipConcurrentDecode`**: Imports same file N=5 times. Spawns 5 threads, each decodes 10 frames from its clip with interleaved `release_decoder`/`ensure_decoder` every 3rd frame to trigger races. Also tests GPU scaled decode. Counts decode errors. Verifies zero errors = PASS.
- **`testPassthroughExport`**: Same single-clip export test (verifies 10-bit, PCM audio).

### 26. UI Lockdown During Export (RESOLVED)
**Symptom**: User could interact with sliders/pickers/import while export was running, causing state corruption, hangs, or crashes.
**Root cause**: No UI lockdown mechanism — all controls were enabled regardless of export state.
**Fix**: Added `@Published var isExporting` to `ProjectModel`. ExportManager sets it `true` on export start and `false` on completion/cancel. Wired into all views:
- **InspectorView**: All sliders, pickers, toggles, and reset button are `.disabled(isExporting)`.
- **SidebarView**: Import button disabled, clip selection taps guarded with `guard !project.isExporting`.
- **PreviewView**: Frame jog slider gets `.disabled(isExporting)`.
- **ExportView**: Codec/profile/resolution/bitrate/output pickers/textfields disabled during export.

### 27. Preview Embedded LUT Enabled by Default (RESOLVED)
**Symptom**: Newly imported clips had Preview LUT off. Users had to manually toggle it for every clip.
**Root cause**: `previewLUT` defaulted to `false` in `Types.h`, `braw_clip_open` zero-init, and `ClipModel` Swift property.
**Fix**: Changed default to `true` in `Types.h::ClipAdjustments.previewLUT`, `braw_api.cpp::braw_clip_open` explicitly sets `h->adjustments.previewLUT = true`, `ClipModel` Swift property defaults to `true` and reads from handle in init. `resetAdjustments` now resets to `true`.

### 28. Runaway Memory — Hard 4GB Budget with Graceful Degradation (RESOLVED)
**Symptom**: After processing several clips, RSS hit 96GB on a 24GB system, causing OOM crashes. The SDK accumulates internal GPU memory (~500MB/decoder) that `Close()`/`Release()` doesn't fully free.
**Root cause**: No memory monitoring or budget enforcement. BRAW SDK internal allocations accumulate until the OS kills the process. Decoder reset only happened in the export path (every 10 frames), not during preview/thumbnail operations.
**Fix**: Comprehensive memory management system with four layers:

1. **C API (`braw_api.h/cpp`)**:
   - `braw_get_resident_memory()` — returns RSS in bytes via `mach_task_basic_info`
   - `braw_pressure_relief()` — calls `malloc_zone_pressure_relief` on default and all zones

2. **`MemoryMonitor.swift`** — polling budget enforcer:
   - Background timer every 2s checks RSS
   - Four pressure levels: `normal` (<2GB), `warning` (2–3GB), `critical` (3–3.5GB), `hardLimit` (>3.5GB)
   - `decodeScale` property: 1.0 (normal), 0.75 (warning), 0.5 (critical+)
   - `shouldThrottleDecode`: `true` at critical+ (skips thumbnail loads, uses scaled preview)
   - On `hardLimit`: posts `Notification.Name.memoryHardLimitReached`
   - Calls `braw_pressure_relief()` automatically at critical+

3. **C-layer hard enforcement** (the critical fix):
   - `BrawClipHandle::decodeCount` — atomic counter incremented per decode operation
   - `overMemoryBudget()` — called SYNC inside every decode function (`braw_clip_decode_frame`, `_gpu`, `_scaled`, `_gpu_scaled`). Checks RSS against 3GB hard cap. If over, calls `braw_pressure_relief()` and returns `nullptr` immediately — **the decode is refused**, preventing the 1.3GB allocation from happening
   - `ensureDecoderReady()` — consolidates decoder open + native capture into one helper
   - `maybeResetDecoder()` — every 15 decodes on the same clip, forces a full decoder Close+reopen+adjustments restore+pressure relief. This proactively clears SDK internal accumulation before it grows unbounded
   - `braw_clip_release_decoder` — resets `decodeCount` to 0

4. **Per-component wiring**:
   - **`ProjectModel`**: subscribes to `hardLimit` notification → releases all decoders (preserving loaded images), flushes Metal pools, double pressure relief
   - **`ClipModel.loadPreviewFrame()`**: calls `MemoryMonitor.checkBeforeDecode()` **synchronously** before dispatching async — if over hard limit, returns immediately without scheduling a decode
   - **`ClipModel.loadThumbnail()`**: same synchronous guard — if over limit, skips thumbnail load
   - **`MetalRenderer.flushPools()`**: releases CVPixelBufferPool, forcing fresh allocation next use
   - **`ExportManager.export()`**: flushes pools + pressure relief if pressure ≥ critical before starting

5. **Export memory management**:
   - `decodeResetInterval()`: computes dynamic reset interval from RSS — every 3 frames if >3GB, 5 frames if >2GB, 10 frames normal
   - `exportMOV()`: re-evaluates interval every frame, shrinks CVPixelBufferPool to 2 buffers when >2GB
   - Between clips in `braw_export_start`: releases decoder + calls `braw_pressure_relief()`
   - After all clips: final `braw_pressure_relief()`

### 29. Subprocess-Based Export — Process Isolation (RESOLVED)
**Symptom**: Even with decoder resets, memory reached 44–82GB per clip because each decoder lifecycle leaks ~500MB of BRAW SDK internal memory (issue #11) that persists until process exit. Decoder resets create new lifecycles, accelerating the leak.
**Root cause**: The BRAW SDK's `Close()`/`Release()` does not fully free GPU memory allocated via `PreparePipeline(pipelineMetal, device, queue)`. The `MTLCreateSystemDefaultDevice()` singleton means GPU resources persist for the process lifetime. Each decoder lifecycle adds ~500MB of permanent leaked memory.
**Fix**: Three-layer defense:
1. **Subprocess isolation**: `braw_export_start` spawns a separate `export_helper` subprocess for each 50-frame segment. The helper opens the decoder once, decodes 50 frames (~5GB RSS), then exits. ALL SDK memory reclaimed by the OS.
2. **Segmented export with ffmpeg concat**: Each clip is divided into `kSegmentFrames = 50` frame segments. Each segment runs in a fresh helper. After all segments complete, `concatenateSegments()` merges them via `ffmpeg -f concat -safe 0 -i <list> -c copy -movflags faststart <output>`. Segment files are deleted after successful concat.
3. **No decoder resets inside helpers**: `exportMOV` never resets the decoder during a segment — one decoder lifecycle per helper minimizes SDK internal leak overhead.
4. **`videoDone` back-pressure fix**: The `requestMediaDataWhenReady` block only sets `videoDone = true` when all frames are decoded (`frameIdx >= frameEnd`) or cancelled. Premature back-pressure exits leave `videoDone = false` so AVFoundation calls the block again with more data. Without this fix, partial segments (e.g. 43 of 50 frames) were written and concatenated, producing truncated output.
5. **Benchmark verified**: 14 segments × 50 frames → 1 file with 685 frames, Main 10, yuv420p10le, PCM f32le, 48kHz. Parent RSS: ~2.6GB. Segment files cleaned up. Multi-clip verified.

---

### Summary Table

| # | Issue | Category | Resolved | Key Fix |
|---|---|---|---|---|
| 1 | ImGui Docking crash | UI | ✅ | SwiftUI native |
| 2 | @StateObject init crash | SwiftUI | ✅ | `.task` / `.onAppear` |
| 3 | Static callback race | SDK | ✅ | Per-decoder callback |
| 4 | MTLBuffer dangling | SDK | ✅ | Immediate blit to owned buffer |
| 5 | CLI resource type mismatch | SDK | ✅ | Check `'cpub'` vs `'metb'` |
| 6 | All decoders open — 100GB OOM | Memory | ✅ | Lazy decoder, metadata-only open |
| 7 | Mutex destroyed in use | Threading | ✅ | `pendingOps` + spin-wait |
| 8 | AVAssetWriter — 90GB OOM | Memory | ✅ | `requestMediaDataWhenReady` |
| 9 | LUT leaked to export | Logic | ✅ | Disable previewLUT during export |
| 10 | Thumbnails simultaneous | Threading | ✅ | `.onAppear` + semaphore(3) |
| 11 | FlushJobs hangs | SDK | ❌ | Removed; decoder reset every 10f |
| 12 | Preview not observing ClipModel | UI | ✅ | `PreviewContent` `@ObservedObject` |
| 13 | ClipModel cache missing | Logic | ✅ | `clipCache` dictionary |
| 14 | 8-bit HEVC export | Config | ✅ | `HEVC_Main10_AutoLevel` |
| 15 | AAC lossy audio | Config | ✅ | LinearPCM 32-bit float |
| 16 | Frame slider ignored | Logic | ✅ | Request ID counter |
| 17 | Inspector not updating preview | Logic | ✅ | Debounced `schedulePreviewRefresh` |
| 18 | Import not serialized | Threading | ✅ | Serial `importQueue` |
| 19 | Export thread VT crash | Threading | ✅ | `dispatch_async` |
| 20 | Moov atom missing | Export | ✅ | Synchronous finishWriting |
| 21 | Decoder reset every 10f | Memory | ✅ | Full destroy + recreate |
| 22 | LUT state after decoder reset | Export | ✅ | Re-apply LUT after reopen |
| 23 | Multi-clip decoder race | Threading | ✅ | `recursive_mutex` on all decoder ops |
| 24 | GPU-accelerated thumbs/preview | Performance | ✅ | Metal pipeline for decode + display |
| 25 | Multi-clip concurrent test | Testing | ✅ | 5 threads × 10 frames with release cycles |
| 26 | UI lockdown during export | UI | ✅ | `isExporting` disables all interactive controls |
| 27 | Preview LUT default on | Config | ✅ | `previewLUT` defaults to `true` everywhere |
| 28 | Runaway memory — 3GB hard cap | Memory | ✅ | Inline C-layer budget check + `decodeCount` auto-reset every 15 + 500ms polling |
| 29 | Runaway memory — SDK leak persists | Memory | ✅ | Subprocess-based export: 50-frame segments in `export_helper`, OS reclaims all on exit |

## Memory Management

### Current State

| Scenario | RSS | Notes |
|---|---|---|
| 76 clips imported (metadata only) | ~29 MB | No Metal resources, no decoders open |
| One clip selected + thumbnail decoded | ~600 MB | SDK pipeline + staging buffer + encoder init |
| 1080p export | ~3–4 GB | CVPixelBufferPool at 1620x1080 (~7 MB/buf) |
| 6K passthrough export | ~3–6 GB | CVPixelBufferPool at 6048x4032 (~97 MB/buf) |
| After project cleanup | ~4 GB | BRAW SDK global resources persist until process exit |

### Decoder Reset (Export, Every 10 Frames)

```
if (frameIdx > 0 && frameIdx % 10 == 0) {
    braw_clip_release_decoder(clip);       // close + reset unique_ptr
    cmdQ = nil; device = nil;             // release ObjC objects
    CFRelease(texCache); texCache = NULL;  // release Metal texture cache
    malloc_zone_pressure_relief(NULL, 0); // hint OS to reclaim
    usleep(100000);                       // 100ms for Metal drain
    device = MTLCreateSystemDefaultDevice();
    cmdQ = [device newCommandQueue];
    CVMetalTextureCacheCreate(...);
    braw_clip_ensure_decoder(clip);
    braw_clip_set_preview_lut(clip, false);
}
```

**Cost**: ~200ms per reset. For 519 frames (52 resets) ≈ 10s overhead. Export drops from 22 fps → 18 fps.

### 8GB System Recommendation
- Use 1080p output (CVPixelBufferPool at 1080p = ~7 MB per buffer).
- Export one clip at a time.
- Decoder reset every 10 frames keeps working set under ~3 GB for 1080p.
- ~5 GB remains for OS + other applications.

### Architecture for Hour-Long Clips (Future)
- **Temp-file segmenting**: export frames 0–9999 to `clip_part1.mov`, close decoder, create new, continue. Segment duration configurable.
- **Concat segments**: `AVMutableMovie` or `ffmpeg -f concat` after all segments complete.
- Keeps memory at ~segment-size × 97 MB regardless of clip length.

---

## Video — All Exports Must Be 10-Bit

### Video Bit Depth
```
H.265/HEVC:  HEVC_Main10_AutoLevel → yuv420p10le ✓ (verified)
H.264:       AVVideoProfileLevelH264HighAutoLevel → yuv420p (8-bit, hardware limit)
ProRes:      inherently 10-bit+ (all ProRes variants >= 10-bit)
```

Set in `exportMOV()`:
```objc
AVVideoProfileLevelKey: (codec == 0)
    ? AVVideoProfileLevelH264HighAutoLevel    // 8-bit (H.264 hardware limit)
    : @"HEVC_Main10_AutoLevel"               // 10-bit ✓
```

### Verify Video Bit Depth
```bash
ffprobe -v error -show_entries stream=pix_fmt,profile <file.mov>
# PASS: pix_fmt=yuv420p10le | profile=Main 10
# FAIL: pix_fmt=yuv420p | profile=Main
```

---

## Audio — Lossless Passthrough at Original Sample Rate

### Audio Configuration
```
Codec:      LinearPCM (uncompressed, lossless)
Bit depth:  32-bit float (matching BRAW SDK output)
Sample rate: original clip rate (typically 48000 Hz)
Channels:   original clip channel count (typically 2 stereo)
Interleave: packed (non-interleaved = NO)
Endian:     little (native for Apple Silicon)
```

Set in `exportMOV()`:
```objc
AVFormatIDKey:              @(kAudioFormatLinearPCM)
AVLinearPCMBitDepthKey:     @(32)
AVLinearPCMIsFloatKey:      @YES
AVLinearPCMIsNonInterleaved:@NO
AVLinearPCMIsBigEndianKey:  @NO
```

### Why Not AAC
- AAC is lossy — discarded detail that DaVinci Resolve workflows need.
- PCM at original sample rate means re-wraps/conforms are lossless.
- File size for audio is small relative to video (at 48kHz/32-bit stereo = ~3.1 Mbps vs video at ~200 Mbps).

### Verify Audio Format
```bash
ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,codec_tag_string <file.mov>
# PASS: codec_name=pcm_f32le (or similar PCM codec)
# PASS: sample_rate=48000 (matches original)
# FAIL: codec_name=aac (lossy compression)
```

### If No Audio Track in Output
The source BRAW file simply had no audio. Cinema cameras (BMCC 6K, etc.) often record video-only. No audio track is written when the source has none — this is correct behavior, not a regression.

---

## Recommended Tests

### Primary: Passthrough (the most common use case)
```bash
./build/braw_test <file.braw>
```
Expected output:
```
  Source: 6K 6048x4032
  Frames:   519
  Speed:    ~9 fps
  Memory:   <5 GB (fits 8GB systems)
  10-bit:   YES ✓
```

### Secondary: 1080p export
```bash
./build/braw_test <file.braw>
# Checks ~17 fps for scaled encode
```

### Regression Checklist
- [ ] App launches without crash
- [ ] Import one clip → thumbnail loads, preview loads
- [ ] Import 10 clips simultaneously → no crash, thumbnails appear over time
- [ ] Inspect -> ISO/Color Temp presets adjust sliders
- [ ] Frame jog slider scrubs preview
- [ ] Preview LUT toggle affects preview but NOT export
- [ ] Bake LUT toggle affects export
- [ ] **Passthrough 6K export → ffprobe shows `Main 10` / `yuv420p10le`**
- [ ] 1080p export → ffprobe shows `Main 10` / `yuv420p10le`
- [ ] Export .mov has AAC audio track
- [ ] Switch between 5 clips → no crash, old decoder destroyed
- [ ] Cmd+C / Cmd+V copy/paste settings between clips
- [ ] Export two clips sequentially → no OOM, memory stays bounded
- [ ] Reset Adjustments button restores all values to defaults

---

## Build & Run
```bash
./build.sh run          # Debug build + launch
./build.sh release      # Release build
./build.sh clean        # Wipe build directory
./build/braw_test <file.braw>   # CLI metadata/decode test
./build/braw_test <file.braw> 2>&1  # Export benchmark
```
