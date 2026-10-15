# BRAW Transcoder

**Turn large Blackmagic RAW recordings into practical MOV files for delivery, editing, or a smaller footage library.**

BRAW is a great format when you need the flexibility of the original camera recording. But that flexibility comes with a storage cost. For a casual shoot, personal project, or finished job you are unlikely to revisit, keeping every large BRAW file may be more than you need. And when an editor or client asks for ProRes, you need a way to deliver it without handing over BRAW.

BRAW Transcoder is a macOS app for those situations. Review your footage, adjust the image before conversion, and export ProRes, 10-bit H.265, or 8-bit H.264 in a QuickTime `.mov` file. Convert selected clips or an entire batch with the same export settings.

**For a critical project where maximum image flexibility matters, keep the BRAW originals.** A transcode is a rendered version of the footage, not a replacement for RAW. This app is most useful when you deliberately choose easier delivery or lower storage needs over retaining every option for future post-production.

## When it makes sense

| Your situation | What the app helps you do |
| --- | --- |
| An editor, client, or production partner needs ProRes | Deliver MOV files in the requested ProRes profile. |
| Casual footage is taking up too much space | Create smaller H.265 or H.264 copies at a data rate and resolution you choose. |
| You want to keep usable footage after a project ends | Make rendered copies after settling white balance, exposure, and other adjustments. |
| Your next workflow works better with MOV than BRAW | Convert footage into a supported video codec and check it in the destination software. |
| You need maximum latitude for grading, recovery, or future revisions | Retain BRAW; make additional transcodes only as needed. |

ProRes delivery and storage reduction are different goals. **ProRes is not guaranteed to save space:** depending on the profile, resolution, frame rate, and original BRAW compression, it can be larger than the source. H.265 and H.264 give you direct control over the target video data rate, making them useful for reducing storage.

## What you can do

- **Review before converting.** Play, scrub, zoom, and inspect clips with audio, an RGB waveform, and false color.
- **Inspect source metadata.** Switch the Inspector to Metadata to search and copy readable camera, lens, recording, production, and color information. Binary LUT payloads and internal calibration data are omitted. Frame metadata reflects the first frame; image adjustments leave the recorded values intact.
- **Set the image while you still have RAW access.** Adjust supported ISO values, white balance, tint, exposure, highlight recovery, and gamut compression before export.
- **Prepare the frame.** Rotate, flip, and apply anamorphic desqueeze, including a custom ratio.
- **Refine supported footage.** Use optional tone-curve and lens-correction controls when the source and SDK support them.
- **Handle batches efficiently.** Copy adjustments between clips, apply them to all clips, and export a selection or the full list.
- **Reuse export settings.** Save named presets for recurring delivery or storage workflows.
- **Retain source audio.** Export uncompressed PCM audio with its source sample rate, supported bit depth, channel count, and channel order.
- **Save an embedded LUT separately.** Extract the selected clip's original embedded LUT as a `.cube` file.

Adjustments are used to render the output; the app does not modify the original BRAW or its sidecar files. Removing a clip from the app's list does not delete it from disk.

## Getting started

The app requires **macOS 14 or later**. Installer distribution is planned; an installer download is not yet linked here. The current implementation uses Blackmagic RAW SDK 6.0 for decoding. Supported export combinations also depend on the Mac's encoding capabilities.

Once the app is installed:

1. **Import your footage.** Choose **File → Import BRAW…**, press **Command–O**, use the sidebar import button, or drag BRAW files into the sidebar.
2. **Review a clip.** Select it in the sidebar, play or scrub through it, and check focus, exposure, and audio.
3. **Make any adjustments.** Use the Inspector to settle the image and framing you want in the converted file. Use **Apply to All Clips** only when those adjustments suit the whole batch.
4. **Open Export Settings…** Choose the format, resolution, profile or data rate, and output folder. Save a preset if you will reuse the settings.
5. **Export.** Choose **Export Selected** or **Export All**. Progress shows the current clip and frame counts; **Cancel** stops the operation.
6. **Check the result.** Open the MOV in the software you intend to use. Confirm the picture, color interpretation, audio, duration, and file size before relying on the converted footage.

## Choosing an export format

All three formats are written as `.mov` files. The codec determines how the video is compressed; MOV is the container.

| Format | Useful for | Available settings | Main tradeoff |
| --- | --- | --- | --- |
| **ProRes (10 bit)** | Requested ProRes deliveries and editing copies | 422 Proxy, 422 LT, 422, 422 HQ, 4444, 4444 XQ | File sizes can be substantial and may exceed the original BRAW. |
| **H.265 / HEVC (10 bit)** | Smaller rendered copies with 10-bit precision | Long GOP or All Intra; 4:2:0 or 4:2:2; target data rate | Playback and editing support vary with the codec settings and destination hardware. |
| **H.264 (8 bit)** | Workflows that require H.264 | 4:2:0 or 4:2:2; target data rate | Less precision for later image adjustments than the app's 10-bit options. |

For a ProRes handoff, match the recipient's requested profile and resolution. A Proxy file is intended for a proxy workflow; it should not be substituted for a requested finishing master. Selecting 4444 or 4444 XQ does not restore RAW flexibility. All ProRes profiles currently use a 10-bit encoder input path in this app.

For storage reduction, start by testing H.265 on a representative clip. Compare the converted file against the source at the resolution you will actually use, including detailed textures, motion, shadows, and highlights. Decide whether its size and image quality meet your needs before converting the whole shoot.

### Compression and chroma subsampling

H.265 offers two compression modes:

- **Long GOP** compresses across multiple frames and is the natural starting point when smaller files are the priority.
- **All Intra** encodes each frame independently. It generally needs more data for comparable quality; selecting it changes the app's suggested data rate to 600 Mbps.

For H.264 and H.265, **4:2:0** stores less color detail, while **4:2:2** retains more color detail. Confirm that your intended player or editor supports the exact combination you choose. H.264 4:2:2 uses software encoding; H.264 4:2:0 and H.265 use macOS hardware encoding. ProRes uses software encoding. Processing time depends on the source, adjustments, export settings, storage, and Mac.

### Data rate and file size

H.264 and H.265 offer target video data rates of **30, 50, 100, 150, 200, 250, 300, 400, 500, 600, and 800 Mbps**. A lower target reduces the storage budget but leaves less data to describe the image. The appropriate rate depends on resolution, frame rate, motion, and image detail.

A rough video-only size estimate is:

```text
Size in decimal GB ≈ data rate in Mbps × duration in seconds ÷ 8,000
```

For example, ten minutes at 100 Mbps is approximately **7.5 GB of video**, before audio and container overhead. Actual output size varies because the selected data rate is a target. Audio remains uncompressed, so it adds to the final size, particularly with many channels.

ProRes uses a profile rather than the data-rate picker. Compare a sample export's actual size against your BRAW source instead of assuming a particular saving.

## Resolution and framing

Keep **Original resolution**, or choose a smaller height preset:

| Preset shown in the app | Maximum output height |
| --- | --- |
| 4320 pixels high (8K) | 4,320 pixels |
| 3240 pixels high (6K) | 3,240 pixels |
| 2160 pixels high (4K) | 2,160 pixels |
| 1080 pixels high (2K) | 1,080 pixels |

These are height limits, not fixed-width delivery canvases. The app preserves the rendered aspect ratio and rounds output width to an even pixel value. For example, a 12,288 × 6,480 image becomes 8,192 × 4,320 with the 8K height preset.

The menu shows presets that reduce the current preview clip. In a mixed batch, smaller clips retain their original dimensions rather than being upscaled. Check the displayed output dimensions when an exact delivery raster is required.

Rotation, flips, and anamorphic settings affect the rendered frame before export sizing. **As shot** retains the SDK's original clip geometry. Explicit desqueeze settings replace the recorded setting; custom ratios accept 1–4×. Desqueeze preserves width and reduces height.

Exports process native-resolution RGB16 frames before final output downsampling. Reducing playback resolution does not reduce export quality.

## Color, monitoring, and baked adjustments

The distinction between the preview and the exported image matters when preparing a delivery.

**The embedded LUT is for previewing and is not baked into the MOV.** With the custom tone curve disabled, exports retain the source gamma and gamut reported by the Blackmagic RAW SDK—typically a log encoding for Film footage. They are not automatically converted into a finished Rec.709 image. A file may look flat in a player that does not apply the appropriate color transform.

The preview's **Log** mode temporarily shows the source generation's default log gamma without the embedded LUT or custom display tone curve. Switching monitoring modes does not change export rendering. **False color** and the **RGB waveform** analyze the adjusted preview signal; false color is never included in the export. Its bands describe rendered signal levels, not a definitive sensor clipping threshold.

Inspector adjustments, including white balance, exposure, supported ISO changes, highlight recovery, gamut compression, geometry, enabled tone curves, and supported lens corrections, **are baked into the converted image**. You can continue grading the MOV, but you cannot return to its original RAW controls. ISO choices are constrained by the recording and cannot change the sensor gain used during capture.

If the clip contains an embedded LUT, use **File → Save Embedded LUT…** to save its original `.cube` file for a downstream workflow. This saves the LUT itself, without incorporating your Inspector adjustments.

### Using the files in DaVinci Resolve

Exports carry descriptive source and render color metadata, plus supported Blackmagic camera color tags. Automatic Film Gen 5 input-color recognition has been verified with tested H.264, H.265, and ProRes exports in Resolve 21.1. Gen 6 automatic recognition has not been established, and custom tone curves are identified as Custom rather than Film.

Check the imported clip's input color space and gamma in your Resolve project. Metadata does not guarantee correct automatic interpretation in every application or project configuration. See the [color metadata notes](docs/technical-notes.md#resolve-color-metadata) for tested behavior and limits.

## Playback and inspection

- Press **Space** to play or pause. The playback bar also provides reverse playback, Stop, previous/next clip, and Loop Clip.
- With looping off, playback advances through the clip list. Stop pauses and returns to frame zero.
- Scroll over the preview or press **Command–Plus / Command–Minus** to zoom. Press **Z** to return to fit.
- Choose **Playback → Resolution** to use Full, 1/2, 1/4, or 1/8 resolution while playing. Pausing and seeking restore the native-resolution still preview.
- Use **Window → Show Waveform** to inspect the RGB waveform.

For high-resolution footage that struggles to play smoothly, lower the playback resolution. Playback may skip video frames to maintain timing; export processes every source frame.

## Audio, metadata, and output files

**Audio:** Source audio is retained as one multichannel, uncompressed PCM track, preserving sample rate, channel order, and supported 16-, 24-, or 32-bit depth. It is not downmixed to stereo. Confirm how your destination editor assigns discrete channels.

**Metadata:** Available camera, lens, recording, and slate fields are written to MOV metadata, along with source timecode when provided and details of the applied rendering settings. These fields do not reproduce every capability of the BRAW original or guarantee that every editor will display them.

**Naming:** Each export uses the source filename with a `.mov` extension. Choose **Same as source** to write beside each BRAW, or select a custom output folder.

**Existing outputs:** A successful export replaces an existing MOV with the same name in the destination folder. Use separate folders for alternate versions and for sources that share a filename. The app writes a temporary output and publishes it only after encoding and metadata finalization succeed. Cancellation or failure preserves the existing destination for that clip; previously completed clips in a batch remain exported.

**Working space:** The destination needs room for the output and temporary audio files. Converting footage does not itself free space: the original BRAW remains on disk. Reclaiming storage requires a separate decision about which originals to retain.

## Before replacing originals with smaller copies

For casual footage where you have chosen to keep only rendered copies, verify that those copies meet your needs first:

1. Play the exports in your intended application and check the beginning, middle, and end, including audio synchronization.
2. Inspect representative detailed, moving, bright, and dark scenes for compression artifacts and unwanted baked adjustments.
3. Confirm resolution, frame rate, duration, audio channels, and any timecode or metadata you rely on.
4. Confirm the files are actually smaller and keep a backup of the copies you intend to retain.

Keep BRAW for important projects, footage that may need substantial regrading, or workflows that rely on RAW-specific features. A smaller log MOV can still offer grading room, but it cannot restore the original RAW processing options after the BRAW is gone.

## Current limitations

- **Native 17K export:** Original-resolution sources wider or taller than 16,384 pixels are currently skipped, with a message naming the skipped clips. Select a smaller height preset to export them. A batch containing only unsupported clips reports that no clips were exported.
- **Encoder support:** Even below that limit, macOS hardware encoding support depends on dimensions, codec, chroma mode, and hardware. If an export cannot initialize its encoder, try a smaller resolution or another supported format.
- **Gyro stabilization:** Exports do not currently preserve a working motion-data workflow for Resolve's native Camera Gyro stabilizer. Gyroflow motion export is also not implemented. Keep BRAW if you need the source gyro data. See the [gyro compatibility research](docs/technical-notes.md#gyro-compatibility).
- **Lens correction:** Controls appear only where the SDK reports support. A visible correction has not yet been confirmed with the available test footage; do not assume a lens control will change every supported clip. See the [lens correction notes](docs/technical-notes.md#source-capabilities-and-audio).
- **Finished-look delivery:** Preview LUTs are not baked in, and the app does not automatically create a Rec.709 viewing master. Confirm whether your recipient expects log media or a finished look before handing over files.

## Further details

See the [technical notes](docs/technical-notes.md) for implementation constraints, compatibility findings, and verification scope, and the [third-party component notes](third_party/README.md) for dependency and release-packaging status.

## License

The project's source code is licensed under the [GNU Affero General Public License version 3](LICENSE). Third-party components retain their applicable licenses.
