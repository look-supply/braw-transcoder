# Gamut compression

The Inspector’s Color Processing group includes Gamut Compression, unchecked by default. It explicitly sets the Blackmagic RAW SDK clip processing attribute `blackmagicRawClipProcessingAttributeGamutCompressionEnable` before frame processing. This uses Blackmagic’s native operator rather than a separate ACES or display-gamut transform.

The same adjustment reaches previews, thumbnails and native RGB16 export frames through the worker protocol. Waveforms follow the adjusted preview. Copy/Paste and Apply to All preserve it; Reset Adjustments disables it. Export uses it independently of the preview-only embedded LUT and records `com.brawtranscoder.render.gamut_compression` in MOV metadata. The source BRAW and sidecar files are not modified.

Checks cover off/on/off decoding, restoration of original pixels, both preview and export formats, exported MOV completion, model refresh, copying and resetting. Pixel changes depend on the clip and output precision; some BGRA8 previews can remain identical while RGB16 pixels differ. Seven real clips were checked on the default Metal path, and the regression suite uses the SDK sample on CPU.
