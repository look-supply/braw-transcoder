# Highlight recovery and export quality

Frame 0 of `A003_02171447_C055.braw` (17,520 × 8,040) shows colored
speckling in the bottom-right shadows when SDK 6.0 highlight recovery is
combined with the Eighth sensor decode mode. This was reproduced on both
CPU and Metal, with the embedded LUT on and off. Native-resolution recovery
followed by an image resize removes the speckling seen in the reduced
sensor decode. No custom denoising or shadow masking is applied.

The worker now decodes highlight-recovery BGRA previews at native resolution
and uses Accelerate's high-quality resampling for the final preview size.
`IBlackmagicRawFrameEx::GetProcessedImageResolution` preserves the SDK's
camera-specific reduced output dimensions. The preview and waveform use
that resized, adjusted image. Recovery is opt-in on import and reset.

Exports always decode native-resolution RGBU16 frames, regardless of preview
size or output preset. The first export frame must match the source's native
dimensions, and subsequent frames must match it. FFmpeg resizes only when a
smaller output preset is requested. The preview image is never an encoder
input, and the embedded preview LUT remains disabled in exports. Smaller
exports may take longer because SDK sensor reduction is no longer used.

Regression check: `braw_reliability_test --highlight-preview <clip>` compares
the worker's recovered preview byte-for-byte with a high-quality resize of
its native-resolution recovered image. This passes for the supplied 17K
clip on Metal and the SDK's one-frame sample on CPU. The 8 GiB child memory
budget and 1 GiB per-frame payload cap remain enforced.

End-to-end check: all 331 frames of the supplied 17K clip exported to HEVC
at 2354 × 1080 from native RGB16 input, in 129 seconds. All 331 encoded
frames were decoded back successfully. Highest sampled child footprint
was 5969 MiB, below the 8 GiB budget.
