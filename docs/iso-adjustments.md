# Clip-specific ISO adjustments

The inspector previously offered ISO 100–25,600 for every clip, while the worker ignored the result of setting ISO. Unsupported choices could therefore appear selected without changing pixels.

`IBlackmagicRawFrameProcessingAttributes::GetISOList` provides the supported values for the frame's recorded analog gain, plus a read-only flag. See the [Blackmagic RAW SDK reference](https://documents.blackmagicdesign.com/DeveloperManuals/BlackmagicRAW-SDK.pdf), GetISOList. The worker captures these capabilities from the first frame and sends them in its open response. The decoder, bridge, and inspector use that list instead of a camera-name or generation-based range.

The ISO picker contains discrete supported values and an As Shot entry; read-only recordings disable it. Unsupported programmatic, pasted, or copied ISO settings normalize to the destination clip's as-shot ISO. Paste/Apply to All show a notice when that happens. Exposure remains available for brightness adjustment outside the supported ISO list.

The decoder rejects unsupported ISO requests explicitly, and the worker checks the SDK return value when setting ISO. This applies to preview BGRA and export RGB16 processing.

Checks on all seven sample-folder clips confirmed supported minimum/maximum ISO values change preview pixels and a supported alternative changes RGB16 pixels. Ranges included 100–1,000, 125–3,200, and 200–3,200. The one-frame SDK fixture additionally checks saved MOV pixel differences between two ISO exports. Model tests cover ISO thumbnail/main-preview refresh, As Shot restoration, invalid-setting normalization, and notice clearing.
