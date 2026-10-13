# Native 17K exports

Native output wider or taller than 16,384 pixels is currently skipped. Export All continues with the remaining clips and names skipped clips in its completion message. Selecting only unsupported clips reports “No clips exported”; it does not report success. Skipped outputs are never created or overwritten.

This is an output restriction. Previewing a 17K source and explicitly exporting it using a smaller height preset remain available. All exports decode native-resolution RGB16 source frames; resizing happens afterward in the encoder. GPU decoding remains the default, and the processing-worker budget remains capped at 8 GiB.

On the URSA Cine 17K sample `A003_02171447_C055.braw` (17,520 × 8,040), macOS HEVC encoding failed with `Cannot prepare encoder: -12902`. A separate bounded software-HEVC experiment with GPU decoding reached 12.43 GiB in child processes / 13.30 GiB including its parent before the test's temporary 12 GiB child limit stopped it. No sufficient memory allowance for a complete native software export was established. The experimental encoder fallback and temporary memory allowance are not enabled in the application.

Verified Export All on the six original sample-folder clips: five native-resolution HEVC exports completed in 87.7 seconds; the 17K clip was skipped. Peak sampled child-process footprint was 3,662 MiB. Output dimensions, complete packet/frame counts, and first-frame decoding were checked. A separate regression check covers all-skipped selection, skips before/after a supported clip, existing-output preservation, temporary-file cleanup, and warning reset between runs.

## Downsampling presets

The menu offers Original resolution, 4320 pixels high (8K), 3240 pixels high (6K), 2160 pixels high (4K), and 1080 pixels high (2K). These are height ceilings, not fixed-width delivery canvases. Width follows the source raster aspect ratio, rounded to the nearest even pixel. A source at or below the chosen height keeps its original dimensions; no preset upscales either dimension. For example, 12288 × 6480 becomes 8192 × 4320 with the 8K preset, while 7680 × 3204 remains unchanged.

The output-size display and every codec use the same dimension calculation. ProRes, HEVC, and H.264 all resize only after full-resolution RGB16 decoding. Actual hardware encoder support still depends on the resulting dimensions. These presets do not introduce anamorphic desqueeze.

The menu shows only height presets that downsample the clip in the main preview. Changing clips resets an unavailable preset to Original resolution. The picker also rejects unavailable selections. Mixed export batches still clamp each source independently so no clip is upscaled.
