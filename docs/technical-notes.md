# Technical notes

The [README](../README.md) describes the user workflow and export tradeoffs. This document retains implementation constraints and compatibility findings that matter when maintaining the app.

## Project layout

| Path | Purpose |
| --- | --- |
| `src/app/` | SwiftUI interface, clip state, monitoring, and audio/video playback |
| `src/bridge/` | C interface between Swift and the decoding/export core |
| `src/core/` | Decoder client, child-process handling, encoding helpers, and MOV metadata finalization |
| `src/worker/` | Isolated Blackmagic RAW SDK worker and IPC protocol |
| `test/` | Native regression and integration checks registered in CMake |
| `scripts/make_icon.py` | Recreates icon assets using Pillow and macOS `iconutil` |
| `scripts/check_resolve_color_detection.py` | Optional Resolve integration check for color assignment, recording metadata, and timecode |
| `third_party/ffmpeg/` | Encoder executable used by the app and integration tests |

`CMakeLists.txt` and `build.sh` remain the development entry points. The SDK is supplied by the installed Blackmagic RAW SDK, not a vendored header copy. Its default location is configured in CMake. The SDK framework is linked into the worker only. The app bundle includes the worker, encoder, and compiled `.icns` icon; the current packaging does not bundle the SDK framework or produce an installer.

## Decode, playback, and export

- Main still previews use native-resolution BGRA8. Playback can use Full, 1/2, 1/4, or 1/8 decode resolution. Sidebar thumbnails use a separate reduced decode.
- Playback uses a bounded read-ahead queue and PCM audio buffering. The audio clock drives video timing; late frames may be skipped during playback.
- Exports decode native-resolution RGB16 before any output resizing. Preview LUTs and false color do not enter the encoder. Inspector processing adjustments do.
- Height presets preserve the rendered aspect ratio and never upscale. Geometry changes precede output sizing.
- Highlight recovery at reduced SDK sensor decode can produce shadow artifacts on the tested 17K source. Recovery previews therefore decode at full resolution before resampling.
- Native exports of sources with either dimension over 16,384 pixels are skipped. Reduced output presets remain available. Hardware encoder support can impose additional restrictions below that limit.
- Child-process memory is bounded to 8 GiB, and IPC frame payloads to 1 GiB. These bounds do not guarantee every source/encoder combination will succeed.
- Each output is encoded into a temporary directory on its destination volume, finalized, and atomically renamed over the destination. Failure or cancellation preserves an existing destination for that clip. Completed earlier clips remain when a batch stops.

## Source capabilities and audio

ISO values come from the SDK's recorded-gain-specific `GetISOList`, including its read-only flag. Unsupported copied values normalize to the destination's as-shot ISO with a notice. Changing ISO cannot change the analog gain used during recording.

Custom tone curves and lens corrections are gated by SDK capabilities. Lens controls are off by default. Writable lens controls were found on some available Cinema Camera 6K clips, but off/on processing produced identical pixels; visible correction remains unverified with those fixtures.

Audio is extracted in bounded chunks and written as one multichannel PCM MOV track. Sample rate, channel order, channel count, and supported 16/24/32-bit depth are retained. Channel-layout guessing is disabled. Regression coverage includes synthetic 1/2/4/8/16-channel PCM round trips and SDK audio comparisons; a real four-channel BRAW capture has not yet been verified.

## Resolve color metadata

Automatic Film Gen 5 recognition was verified in Resolve 21.1 with fresh H.264, HEVC, and ProRes imports. These results describe tested fixtures and do not guarantee recognition of every camera encoding.

Two details are required by the tested Resolve workflow:

1. Blackmagic camera color metadata must be placed in `moov/meta`. FFmpeg initially writes it in `moov/udta/meta`; `QuickTimeMetadata.cpp` promotes it before publishing the output without changing media bytes or chunk offsets.
2. The actual Cinema Camera 6K name in the `colorScience` descriptor was not recognized. Confirmed Gen 5 Film/Blackmagic Design exports use the recognized URSA Mini Pro 12K Gen 5 profile descriptor while preserving actual camera identity in separate metadata fields. This normalization is limited to Gen 5.

Gen 6 DaVinci Wide Gamut/Intermediate automatic detection was not established with the tested processing fixture. Custom tone curves are tagged as Custom and are not assigned a Film marker. Other encodings retain descriptive source tags rather than being mapped to unrelated standard color codes.

The optional Resolve script requires a running Resolve instance with local external scripting enabled. It saves the current project, creates a temporary managed test project, imports the supplied files, and restores the original project before deleting its own test project. It is an integration tool and is not part of normal app operation.

## Gyro compatibility

The app does not export gyro/accelerometer motion tracks or sidecars. Ordinary camera metadata cannot substitute for timed motion samples. No working route was demonstrated for enabling Resolve's native Camera Gyro stabilizer on these MOV exports.

Gyroflow GCSV sidecars and embedded CAMM tracks are possible future investigations, not implemented features. Any motion export would need validated timestamps, axis orientation, sensor readout, lens calibration, and coordination with transformed image geometry.

Primary references for future work:

- [Blackmagic RAW SDK reference](https://documents.blackmagicdesign.com/DeveloperManuals/BlackmagicRAW-SDK.pdf)
- [Gyroflow BRAW telemetry parser](https://github.com/AdrianEddy/telemetry-parser/blob/master/src/blackmagic/mod.rs)
- [Gyroflow Resolve OpenFX workflow](https://docs.gyroflow.xyz/app/video-editor-plugins/davinci-resolve-openfx)
- [GCSV motion format](https://docs.gyroflow.xyz/app/technical-details/gcsv-format)
- [CAMM specification](https://developers.google.com/streetview/publish/camm-spec)

## Verification scope

CMake registers regression checks for process failures, metadata, waveform behavior, numeric controls, playback, preview monitoring, export UI, LUT extraction, geometry/tone processing, lens corrections, gamut compression, audio, resolution, ISO, highlight recovery, and adjusted thumbnails. SDK-dependent tests are registered when the installed SDK sample is available. Passing a one-frame SDK fixture is not a long-clip endurance or performance guarantee.

The CLI integration tools use real footage and can create output files. Check their arguments and destination behavior before running them against recordings with existing exports. The runtime encoder must remain available beside the integration executables.
