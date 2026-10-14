import Foundation
import AppKit
import CoreGraphics

// Native ownership is confined to these wrappers. The bridge serializes access
// with native mutexes, and queued work retains its wrapper until completion.
struct DecodedPixels: Sendable {
    let data: Data
    let width: Int
    let height: Int
}
private struct DecodeResult: Sendable {
    var pixels: DecodedPixels?
    var waveform: RGBWaveform?
    var falseColorPixels: DecodedPixels?
    var error: String = ""
    var usesMetal = false
}
private final class NativeFrameBuffer: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { braw_frame_buffer_free(handle) }
}

private struct BufferedPlaybackFrame: Sendable {
    let index: UInt64
    let result: DecodeResult
}

/// A bounded read-ahead queue separates variable decode times from presentation.
@MainActor private final class PlaybackFrameQueue {
    private var frames: [BufferedPlaybackFrame] = []
    private var reader: CheckedContinuation<BufferedPlaybackFrame?, Never>?
    private var writer: CheckedContinuation<Void, Never>?
    private var prefill: CheckedContinuation<Void, Never>?
    private var closed = false
    private let initialCount: Int
    init(remaining: UInt64) { initialCount = Int(min(3, remaining)) }
    var firstIndex: UInt64? { frames.first?.index }

    func waitForPrefill() async {
        if closed || frames.count >= initialCount { return }
        await withCheckedContinuation { prefill = $0 }
    }
    func push(_ frame: BufferedPlaybackFrame) async -> Bool {
        while !closed && frames.count >= 3 {
            await withCheckedContinuation { writer = $0 }
        }
        guard !closed else { return false }
        if let reader {
            self.reader = nil
            reader.resume(returning: frame)
        } else { frames.append(frame) }
        if frames.count >= initialCount {
            prefill?.resume(); prefill = nil
        }
        return true
    }
    func pop() async -> BufferedPlaybackFrame? {
        if !frames.isEmpty {
            let frame = frames.removeFirst()
            writer?.resume(); writer = nil
            return frame
        }
        guard !closed else { return nil }
        return await withCheckedContinuation { reader = $0 }
    }
    func finish(discard: Bool = false) {
        closed = true
        if discard { frames.removeAll() }
        reader?.resume(returning: nil); reader = nil
        writer?.resume(); writer = nil
        prefill?.resume(); prefill = nil
    }
}
private final class NativeClip: @unchecked Sendable {
    let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.braw.clip", qos: .userInitiated)
    private let lock = NSLock()
    private var latestRequest: UInt64 = 0
    private var latestThumbnailRequest: UInt64 = 0
    private let profilesPlayback = ProcessInfo.processInfo.environment["BRAW_PROFILE_PLAYBACK"] == "1"
    init(retainedHandle: OpaquePointer) { handle = retainedHandle }
    deinit { braw_clip_close(handle) }
    func setLatest(_ request: UInt64) { lock.withLock { latestRequest = request } }
    func setLatestThumbnail(_ request: UInt64) { lock.withLock { latestThumbnailRequest = request } }
    func decode(index: UInt64, scale: Float, request: UInt64? = nil, thumbnailRequest: UInt64? = nil, analyzeWaveform: Bool = false, mode: PreviewMode? = nil, falseColor: Bool = false) async -> DecodeResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let isStale = { [self] in
                    lock.withLock {
                        if let request, latestRequest != request { return true }
                        if let thumbnailRequest, latestThumbnailRequest != thumbnailRequest { return true }
                        return false
                    }
                }
                if isStale() {
                    continuation.resume(returning: DecodeResult()); return
                }
                var width: Int32 = 0, height: Int32 = 0
                let profileStart = ProcessInfo.processInfo.systemUptime
                let buffer = mode.flatMap { braw_clip_decode_monitor_buffer(handle, index, &width, &height, scale, $0 != .embeddedLUT) }
                let owner = buffer.map { NativeFrameBuffer($0) }
                let decoded = mode == nil
                    ? braw_clip_decode_frame_scaled(handle, index, &width, &height, scale)
                    : buffer.flatMap { braw_frame_buffer_data($0).map { UnsafeMutablePointer(mutating: $0) } }
                guard let pixels = decoded else {
                    continuation.resume(returning: DecodeResult(error: String(cString: braw_clip_last_error(handle)))); return
                }
                let decodeFinished = ProcessInfo.processInfo.systemUptime
                defer { if mode == nil { braw_clip_free_frame(pixels) } }
                guard width > 0, height > 0 else {
                    continuation.resume(returning: DecodeResult(error: "Decoder returned an invalid image.")); return
                }
                let count = Int(width) * Int(height) * 4
                let data: Data
                if let owner {
                    data = Data(bytesNoCopy: pixels, count: count, deallocator: .custom { [owner] _, _ in
                        withExtendedLifetime(owner) {}
                    })
                } else { data = Data(bytes: pixels, count: count) }
                let frame = DecodedPixels(data: data, width: Int(width), height: Int(height))
                if profilesPlayback, index % 24 == 0 {
                    print("Playback profile frame \(index): decode/IPC \((decodeFinished - profileStart) * 1000) ms; frame wrapping \((ProcessInfo.processInfo.systemUptime - decodeFinished) * 1000) ms")
                }
                if isStale() {
                    continuation.resume(returning: DecodeResult()); return
                }
                let waveform = analyzeWaveform
                    ? RGBWaveform.analyze(bgra: frame.data, width: frame.width, height: frame.height) : nil
                let falsePixels = falseColor
                    ? FalseColor.render(bgra: frame.data, width: frame.width, height: frame.height)
                        .map { DecodedPixels(data: $0, width: frame.width, height: frame.height) } : nil
                continuation.resume(returning: DecodeResult(pixels: frame, waveform: waveform,
                    falseColorPixels: falsePixels, usesMetal: braw_clip_using_metal(handle)))
            }
        }
    }
    func releaseDecoder() {
        queue.async { [self] in braw_clip_release_decoder(handle) }
    }
    func audioInfo() async -> PlaybackAudioFormat? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let info = braw_clip_get_audio_info(handle)
                continuation.resume(returning: info.rate > 0 && info.channels > 0 && info.samples > 0
                    ? PlaybackAudioFormat(rate: info.rate, channels: info.channels, bits: info.bits, samples: info.samples) : nil)
            }
        }
    }
    func audioSamples(start: UInt64, count: UInt32, bits: UInt32) async -> [Float]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var byteCount: UInt32 = 0
                guard let bytes = braw_clip_read_audio(handle, start, count, &byteCount) else {
                    continuation.resume(returning: nil); return
                }
                defer { braw_clip_free_frame(bytes) }
                let data = Data(bytes: bytes, count: Int(byteCount))
                continuation.resume(returning: PlaybackPCM.floats(data, bits: bits))
            }
        }
    }
    func saveEmbeddedLUT(to path: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if braw_clip_save_embedded_lut(handle, path) == 0 {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: String(cString: braw_clip_last_error(handle)))
                }
            }
        }
    }
}
private final class NativeProject: @unchecked Sendable {
    let handle: OpaquePointer
    let queue = DispatchQueue(label: "com.braw.import", qos: .userInitiated)
    init() { handle = braw_project_create()! }
    deinit { braw_project_destroy(handle) }
    func importClip(_ path: String) async -> Int32 {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: braw_project_import(handle, path)) }
        }
    }
}

// ── Swift model ──────────────────────────────────

@MainActor
final class ClipModel: Identifiable, ObservableObject {
    nonisolated let id = UUID()
    private let native: NativeClip
    private var handle: OpaquePointer? { native.handle }

    @Published var iso: UInt32 = 800 {
        didSet {
            let requestedISO = iso
            if let h = handle {
                braw_clip_set_iso(h, iso)
                let appliedISO = braw_clip_get_iso(h)
                if appliedISO != iso { iso = appliedISO }
            }
            isoAdjustmentNotice = requestedISO == iso ? nil : "ISO \(requestedISO) is unavailable for this recording. Using \(iso) (As Shot)."
            isoPresetIndex = iso == nativeISO ? 0 : (isoPresets.firstIndex(of: iso).map { $0 + 1 } ?? -1)
            schedulePreviewRefresh()
        }
    }
    @Published var colorTemp: UInt32 = 5600 {
        didSet { if let h = handle { braw_clip_set_color_temp(h, colorTemp) }; schedulePreviewRefresh() }
    }
    @Published var tint: Int16 = 0 {
        didSet { if let h = handle { braw_clip_set_tint(h, tint) }; schedulePreviewRefresh() }
    }
    @Published var exposure: Float = 0 {
        didSet { if let h = handle { braw_clip_set_exposure(h, exposure) }; schedulePreviewRefresh() }
    }
    @Published var highlightRecovery = false {
        didSet { if let h = handle { braw_clip_set_highlight_recovery(h, highlightRecovery) }; schedulePreviewRefresh() }
    }
    @Published var gamutCompression = false {
        didSet { if let h = handle { braw_clip_set_gamut_compression(h, gamutCompression) }; schedulePreviewRefresh() }
    }
    private(set) var lensCorrectionSupport: UInt32 = 0
    @Published var lensCorrections: UInt32 = 0 {
        didSet {
            if let h = handle {
                braw_clip_set_lens_corrections(h, lensCorrections)
                let applied = braw_clip_get_lens_corrections(h)
                if applied != lensCorrections { lensCorrections = applied }
            }
            schedulePreviewRefresh()
        }
    }
    @Published var anamorphicMode = 0 { didSet { applyGeometry(); schedulePreviewRefresh() } }
    @Published var customDesqueeze: Float = 2 {
        didSet {
            if let h = handle {
                braw_clip_set_custom_desqueeze(h, customDesqueeze)
                let applied = braw_clip_get_settings(h).customDesqueeze
                if applied != customDesqueeze { customDesqueeze = applied }
            }
            schedulePreviewRefresh()
        }
    }
    @Published var rotation = 0 { didSet { applyGeometry(); schedulePreviewRefresh() } }
    @Published var flipHorizontal = false { didSet { applyGeometry(); schedulePreviewRefresh() } }
    @Published var flipVertical = false { didSet { applyGeometry(); schedulePreviewRefresh() } }
    private(set) var toneCurveSupported = false
    private(set) var videoBlackSupported = false
    private(set) var toneRanges: [BrawToneRange] = []
    private(set) var toneDefaults: [Float] = []
    private(set) var defaultVideoBlack = false
    @Published var toneCurveEnabled = false {
        didSet {
            if let h = handle {
                braw_clip_set_tone_enabled(h, toneCurveEnabled)
                let applied = braw_clip_get_settings(h).toneCurveEnabled
                if toneCurveEnabled != applied { toneCurveEnabled = applied }
            }
            schedulePreviewRefresh()
        }
    }
    @Published var toneValues: [Float] = Array(repeating: 0, count: 7) {
        didSet {
            if let h = handle, toneValues.count == 7 {
                for index in 0..<7 { braw_clip_set_tone_value(h, Int32(index), toneValues[index]) }
                let applied = (0..<7).map { braw_clip_get_tone_value(h, Int32($0)) }
                if applied != toneValues { toneValues = applied }
            }
            schedulePreviewRefresh()
        }
    }
    @Published var videoBlack = false {
        didSet {
            if let h = handle {
                braw_clip_set_video_black(h, videoBlack)
                let applied = braw_clip_get_settings(h).videoBlack
                if videoBlack != applied { videoBlack = applied }
            }
            schedulePreviewRefresh()
        }
    }
    @Published var previewLUT = true {
        didSet {
            if let h = handle { braw_clip_set_preview_lut(h, previewLUT) }
            schedulePreviewRefresh()
        }
    }
    @Published var falseColorEnabled = false {
        didSet {
            if oldValue != falseColorEnabled, isPreviewActive { loadPreviewFrame() }
        }
    }
    var previewMode: PreviewMode {
        get { previewLUT ? .embeddedLUT : .log }
        set { if newValue != previewMode { previewLUT = newValue == .embeddedLUT } }
    }
    @Published var currentFrame: UInt64 = 0 {
        didSet {
            guard !isPresentingPlaybackFrame else { return }
            stopPlayback(refreshPreview: false)
            loadPreviewFrame()
        }
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var previewZoom: CGFloat = 1
    // Image-relative translation; positive X/Y moves the picture right/down.
    @Published private(set) var previewPan: CGSize = .zero
    private var previewViewport: CGSize = .zero
    private var previewViewportAspect: CGFloat = 0
    func setPreviewViewport(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let aspect = renderAspectRatio
        guard previewViewport != size || previewViewportAspect != aspect else { return }
        previewViewport = size
        previewViewportAspect = aspect
        clampPreviewPan()
    }
    func fittedPreviewSize(in viewport: CGSize) -> CGSize {
        let aspect = renderAspectRatio
        return CGSize(width: min(viewport.width, viewport.height * aspect),
                      height: min(viewport.height, viewport.width / aspect))
    }
    func panPreview(by translation: CGSize) {
        guard previewZoom > 1, translation.width.isFinite, translation.height.isFinite,
              previewViewport.width > 0, previewViewport.height > 0 else { return }
        let fitted = fittedPreviewSize(in: previewViewport)
        clampPreviewPan(CGSize(width: previewPan.width + translation.width / (fitted.width * previewZoom),
                              height: previewPan.height + translation.height / (fitted.height * previewZoom)))
    }
    private func clampPreviewPan(_ proposed: CGSize? = nil) {
        guard previewZoom > 1, previewViewport.width > 0, previewViewport.height > 0 else {
            if previewPan != .zero { previewPan = .zero }
            return
        }
        let fitted = fittedPreviewSize(in: previewViewport)
        let xLimit = max(0, (1 - previewViewport.width / (fitted.width * previewZoom)) / 2)
        let yLimit = max(0, (1 - previewViewport.height / (fitted.height * previewZoom)) / 2)
        let offset = proposed ?? previewPan
        let clamped = CGSize(width: min(xLimit, max(-xLimit, offset.width)),
                             height: min(yLimit, max(-yLimit, offset.height)))
        if previewPan != clamped { previewPan = clamped }
    }
    func zoomPreview(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        previewZoom = min(8, max(0.25, previewZoom * factor))
        clampPreviewPan()
    }
    func zoomIn() { zoomPreview(by: 1.25) }
    func zoomOut() { zoomPreview(by: 0.8) }
    func resetZoom() { previewZoom = 1; previewPan = .zero }
    @Published private(set) var playbackDirection: PlaybackDirection = .forward
    var onPlaybackFinished: ((ClipModel, PlaybackDirection) -> Void)?
    @Published private(set) var playbackFrame: DecodedPixels?
    @Published private(set) var playbackUsesMetal = false
    private var playbackTask: Task<Void, Never>?
    private var playbackProducer: Task<Void, Never>?
    private var playbackFrames: PlaybackFrameQueue?
    private var playbackAudio: PlaybackAudio?
    var playbackAudioIsPlaying: Bool { playbackAudio?.isPlaying == true }
    var playbackAudioElapsed: Double? { playbackAudio?.elapsed }
    var playbackWaveformEnabled = false
    var playbackResolution: PlaybackResolution = .full {
        didSet {
            guard playbackResolution != oldValue, isPlaying else { return }
            stopPlayback(refreshPreview: false)
            startPlayback()
        }
    }
    private var playbackGeneration: UInt64 = 0
    private var isPresentingPlaybackFrame = false

    @Published var thumbnail: NSImage? = nil
    @Published private(set) var isLoadingThumbnail = false
    @Published var preview: NSImage? = nil
    @Published var waveform: RGBWaveform?
    @Published var isLoadingPreview = false
    @Published var previewError: String?

    private var loadRequestID: UInt64 = 0
    private var pendingRefresh: DispatchWorkItem?
    private var thumbnailRequestID: UInt64 = 0
    private var isPreviewActive = false

    private var _fileName: String = ""
    var fileName: String { _fileName }
    private(set) var cameraName: String = ""
    var fileNameWithCamera: String {
        cameraName.isEmpty ? fileName : "\(fileName) \(cameraName)"
    }
    private(set) var hasEmbeddedLUT = false
    private(set) var embeddedLUTName = ""
    func saveEmbeddedLUT(to url: URL) async -> String? {
        await native.saveEmbeddedLUT(to: url.path)
    }

    private var _dirPath: String = ""
    var directoryPath: String { _dirPath }
    private var _filePath: String = ""
    var filePath: String { _filePath }

    private var _gamma: String = ""
    var gamma: String { _gamma }
    private var _gamut: String = ""
    var gamut: String { _gamut }
    var colorScienceGen: UInt16 = 0

    // Native camera metadata (read once on init)
    var nativeISO: UInt32 = 0
    var nativeColorTemp: UInt32 = 5600
    var nativeTint: Int16 = 0

    private var thumbnailLoaded = false

    // Presets
    @Published var isoPresetIndex: Int = -1
    @Published var colorPresetIndex: Int = 0

    var isoPresets: [UInt32] = []
    var isoReadOnly = true
    @Published var isoAdjustmentNotice: String?

    struct ColorPreset: Identifiable {
        let id: Int
        let name: String
        let temp: UInt32
        let tint: Int16
    }
    static let colorPresets: [ColorPreset] = [
        ColorPreset(id: 0, name: "Daylight",    temp: 5500, tint: 10),
        ColorPreset(id: 1, name: "Cloudy",      temp: 6500, tint: 10),
        ColorPreset(id: 2, name: "Shade",       temp: 7500, tint: 10),
        ColorPreset(id: 3, name: "Tungsten",    temp: 2850, tint: 0),
        ColorPreset(id: 4, name: "Fluorescent", temp: 3800, tint: 21),
    ]
    static let colorPresetLabels: [String] = ["As Shot"] + colorPresets.map { $0.name } + ["Custom"]

    init(id: Int, handle: OpaquePointer) {
        self.native = NativeClip(retainedHandle: handle)
        if let h = self.handle {
            _fileName = String(cString: braw_clip_get_filename(h))
            cameraName = String(cString: braw_clip_get_camera_type(h)).trimmingCharacters(in: .whitespacesAndNewlines)
            hasEmbeddedLUT = braw_clip_has_embedded_lut(h)
            embeddedLUTName = String(cString: braw_clip_embedded_lut_name(h))
            let fullPath = String(cString: braw_clip_get_filepath(h))
            _filePath = fullPath
            if let lastSlash = fullPath.lastIndex(of: "/") {
                _dirPath = String(fullPath[..<lastSlash])
            }
            _gamma = String(cString: braw_clip_get_gamma(h))
            _gamut = String(cString: braw_clip_get_gamut(h))
            colorScienceGen = braw_clip_get_color_science_gen(h)
            isoPresets = (0..<Int(braw_clip_get_iso_count(h))).map { braw_clip_get_iso_at(h, Int32($0)) }
            isoReadOnly = braw_clip_iso_is_read_only(h) != 0
            lensCorrectionSupport = braw_clip_get_lens_correction_support(h)
            let processing = braw_clip_get_settings(h)
            toneCurveSupported = braw_clip_tone_curve_supported(h)
            videoBlackSupported = braw_clip_video_black_supported(h)
            defaultVideoBlack = braw_clip_default_video_black(h)
            toneRanges = (0..<7).map { braw_clip_get_tone_range(h, Int32($0)) }
            toneDefaults = toneRanges.map { $0.value }
            toneValues = (0..<7).map { braw_clip_get_tone_value(h, Int32($0)) }
            toneCurveEnabled = processing.toneCurveEnabled
            videoBlack = processing.videoBlack
            customDesqueeze = processing.customDesqueeze
            anamorphicMode = Int(processing.anamorphic)
            rotation = Int(processing.rotation)
            flipHorizontal = processing.flips & 1 != 0
            flipVertical = processing.flips & 2 != 0
            iso = braw_clip_get_iso(h)
            colorTemp = braw_clip_get_color_temp(h)
            tint = braw_clip_get_tint(h)
            exposure = braw_clip_get_exposure(h)
            highlightRecovery = braw_clip_get_highlight_recovery(h)
            gamutCompression = braw_clip_get_gamut_compression(h)
            lensCorrections = braw_clip_get_lens_corrections(h)
            previewLUT = braw_clip_get_preview_lut(h)
            // Read native camera metadata
            nativeISO = braw_clip_get_native_iso(h)
            nativeColorTemp = braw_clip_get_native_color_temp(h)
            nativeTint = braw_clip_get_native_tint(h)
            // Match current ISO to dropdown index
            if iso == nativeISO {
                isoPresetIndex = 0
            } else if let presetIdx = isoPresets.firstIndex(of: iso) {
                isoPresetIndex = presetIdx + 1
            } else {
                isoPresetIndex = -1
            }
        }
        // Default to As Shot white balance
        if let h = self.handle {
            colorTemp = braw_clip_get_native_color_temp(h)
            tint = braw_clip_get_native_tint(h)
            braw_clip_set_color_temp(h, colorTemp)
            braw_clip_set_tint(h, tint)
        }
        // Keep recovery opt-in: SDK recovery can introduce shadow color
        // artifacts, so model creation must not force it on.
    }

    var nativeWidth: UInt32  { handle.map { braw_clip_get_width($0) } ?? 0 }
    var nativeHeight: UInt32 { handle.map { braw_clip_get_height($0) } ?? 0 }
    var frameRate: Float     { handle.map { braw_clip_get_frame_rate($0) } ?? 0 }
    var durationTimecode: String { Self.durationTimecode(frames: frameCount, fps: frameRate) }
    static func durationTimecode(frames: UInt64, fps: Float) -> String {
        guard fps.isFinite, fps > 0,
              let rate = UInt64(exactly: max(1, Double(fps).rounded())) else { return "--:--:--:--" }
        let seconds = frames / rate
        return String(format: "%02llu:%02llu:%02llu:%02llu",
                      seconds / 3600, (seconds / 60) % 60, seconds % 60, frames % rate)
    }

    var frameCount: UInt64   { handle.map { braw_clip_get_frame_count($0) } ?? 0 }

    func releaseDecoder() {
        stopPlayback(refreshPreview: false)
        playbackFrame = nil
        isPreviewActive = false
        loadRequestID += 1
        native.setLatest(loadRequestID)
        pendingRefresh?.cancel()
        if pendingRefresh != nil {
            pendingRefresh = nil
            loadThumbnail(force: true)
        }
        native.releaseDecoder()
        isLoadingPreview = false
    }
    
    var renderDimensions: (width: Int32, height: Int32) {
        var width: Int32 = 0, height: Int32 = 0
        if let h = handle { braw_clip_get_render_dimensions(h, &width, &height) }
        return (width, height)
    }
    var renderAspectRatio: CGFloat {
        let size = renderDimensions
        return size.height > 0 ? CGFloat(size.width) / CGFloat(size.height) : 16.0 / 9.0
    }
    var renderedGamma: String { toneCurveEnabled ? "Blackmagic Design Custom" : gamma }
    func applyGeometry() {
        if let h = handle {
            braw_clip_set_custom_desqueeze(h, customDesqueeze)
            braw_clip_set_geometry(h, UInt32(clamping: anamorphicMode), UInt32(clamping: rotation),
                                   (flipHorizontal ? 1 : 0) | (flipVertical ? 2 : 0))
        }
    }
    func refreshProcessing() {
        guard let h = handle else { return }
        let settings = braw_clip_get_settings(h)
        customDesqueeze = settings.customDesqueeze
        anamorphicMode = Int(settings.anamorphic); rotation = Int(settings.rotation)
        flipHorizontal = settings.flips & 1 != 0; flipVertical = settings.flips & 2 != 0
        toneValues = (0..<7).map { braw_clip_get_tone_value(h, Int32($0)) }
        toneCurveEnabled = settings.toneCurveEnabled; videoBlack = settings.videoBlack
    }
    func applyToEngine() {
        guard let h = handle else { return }
        braw_clip_set_iso(h, iso)
        braw_clip_set_color_temp(h, colorTemp)
        braw_clip_set_tint(h, tint)
        braw_clip_set_exposure(h, exposure)
        braw_clip_set_highlight_recovery(h, highlightRecovery)
        braw_clip_set_gamut_compression(h, gamutCompression)
        braw_clip_set_lens_corrections(h, lensCorrections)
        braw_clip_set_preview_lut(h, previewLUT)
        applyGeometry()
        braw_clip_set_tone_enabled(h, toneCurveEnabled)
        braw_clip_set_video_black(h, videoBlack)
        for index in 0..<toneValues.count { braw_clip_set_tone_value(h, Int32(index), toneValues[index]) }
    }

    func loadThumbnail(force: Bool = false) {
        guard force || !thumbnailLoaded else { return }
        thumbnailLoaded = true
        isLoadingThumbnail = true
        thumbnailRequestID += 1
        let requestID = thumbnailRequestID
        native.setLatestThumbnail(requestID)
        Task { [weak self, native] in
            let result = await native.decode(index: 0, scale: 0.25, thumbnailRequest: requestID)
            guard let self, self.thumbnailRequestID == requestID else { return }
            self.isLoadingThumbnail = false
            if let pixels = result.pixels {
                self.thumbnail = makeNSImageBGRA(frame: pixels)
            } else { self.thumbnailLoaded = false }
            // Thumbnails do not need a persistent SDK process.
            if !self.isPreviewActive { native.releaseDecoder() }
        }
    }

    func refreshAdjustmentsFromEngine() {
        guard let h = handle else { return }
        iso = braw_clip_get_iso(h)
        colorTemp = braw_clip_get_color_temp(h)
        tint = braw_clip_get_tint(h)
        exposure = braw_clip_get_exposure(h)
        highlightRecovery = braw_clip_get_highlight_recovery(h)
        gamutCompression = braw_clip_get_gamut_compression(h)
        lensCorrections = braw_clip_get_lens_corrections(h)
        previewLUT = braw_clip_get_preview_lut(h)
        refreshProcessing()
        synchronizePresetLabels()
    }

    func synchronizePresetLabels() {
        if iso == nativeISO { isoPresetIndex = 0 }
        else if let index = isoPresets.firstIndex(of: iso) { isoPresetIndex = index + 1 }
        else { isoPresetIndex = -1 }

        if colorTemp == nativeColorTemp && tint == nativeTint { colorPresetIndex = 0 }
        else if let index = Self.colorPresets.firstIndex(where: { $0.temp == colorTemp && $0.tint == tint }) {
            colorPresetIndex = index + 1
        } else { colorPresetIndex = Self.colorPresetLabels.count - 1 }
    }

    func applyISOPreset(_ index: Int) {
        if index == 0 {
            iso = nativeISO
        } else if index >= 1 && index <= isoPresets.count {
            iso = isoPresets[index - 1]
        }
        synchronizePresetLabels()
    }

    func applyColorPreset(_ index: Int) {
        guard let h = handle else { return }
        if index == 0 {
            colorTemp = nativeColorTemp
            tint = nativeTint
            braw_clip_set_color_temp(h, colorTemp)
            braw_clip_set_tint(h, tint)
        } else if index >= 1 && index <= Self.colorPresets.count {
            let preset = Self.colorPresets[index - 1]
            colorTemp = preset.temp
            tint = preset.tint
        }
        colorPresetIndex = index
        schedulePreviewRefresh()
    }

    func resetAdjustments() {
        guard let h = handle else { return }
        iso = nativeISO
        isoPresetIndex = 0
        exposure = 0
        highlightRecovery = false
        gamutCompression = false
        lensCorrections = 0
        anamorphicMode = 0; customDesqueeze = 2; rotation = 0; flipHorizontal = false; flipVertical = false
        toneCurveEnabled = false; toneValues = toneDefaults; videoBlack = defaultVideoBlack
        previewLUT = true
        colorTemp = nativeColorTemp
        tint = nativeTint
        colorPresetIndex = 0
        braw_clip_set_iso(h, iso)
        braw_clip_set_color_temp(h, colorTemp)
        braw_clip_set_tint(h, tint)
        braw_clip_set_exposure(h, exposure)
        braw_clip_set_highlight_recovery(h, false)
        braw_clip_set_preview_lut(h, true)
        schedulePreviewRefresh()
    }

    func schedulePreviewRefresh() {
        stopPlayback(refreshPreview: false)
        isLoadingPreview = isPreviewActive
        loadRequestID += 1
        native.setLatest(loadRequestID)
        thumbnailRequestID += 1
        native.setLatestThumbnail(thumbnailRequestID)
        isLoadingThumbnail = true
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            if self.isPreviewActive { self.loadPreviewFrame() }
            self.loadThumbnail(force: true)
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func loadPreviewFrame() {
        stopPlayback(refreshPreview: false)
        isPreviewActive = true
        isLoadingPreview = true
        previewError = nil
        loadRequestID += 1
        let requestID = loadRequestID
        let frameIndex = currentFrame
        let mode = previewMode
        let falseColor = falseColorEnabled
        // Decode the main preview at native resolution for detail inspection.
        // Sidebar thumbnails retain their separate reduced-resolution path.
        let previewScale: Float = 1
        native.setLatest(requestID)
        Task { [weak self, native] in
            let result = await native.decode(index: frameIndex, scale: previewScale, request: requestID, analyzeWaveform: true, mode: mode, falseColor: falseColor)
            guard let self, self.loadRequestID == requestID else { return }
            self.isLoadingPreview = false
            self.waveform = result.waveform
            if let pixels = result.falseColorPixels ?? result.pixels {
                self.preview = makeNSImageBGRA(frame: pixels)
                self.playbackFrame = nil
            }
            else if !result.error.isEmpty { self.previewError = result.error }
        }
    }

    func togglePlayback(direction: PlaybackDirection? = nil) {
        let desired = direction ?? playbackDirection
        if isPlaying && desired == playbackDirection { stopPlayback() }
        else {
            stopPlayback(refreshPreview: false)
            startPlayback(direction: desired)
        }
    }

    func startPlayback(direction desired: PlaybackDirection? = nil) {
        guard !isPlaying, frameCount > 0, frameRate.isFinite, frameRate > 0 else { return }
        let direction = desired ?? playbackDirection
        playbackDirection = direction
        let refreshThumbnail = pendingRefresh != nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        if refreshThumbnail { loadThumbnail(force: true) }
        loadRequestID += 1
        let requestID = loadRequestID
        native.setLatest(requestID)
        playbackGeneration += 1
        let generation = playbackGeneration
        isPresentingPlaybackFrame = true
        if direction == .forward && currentFrame >= frameCount - 1 { currentFrame = 0 }
        if direction == .reverse && currentFrame == 0 { currentFrame = frameCount - 1 }
        isPresentingPlaybackFrame = false
        let firstFrame = currentFrame
        let count = frameCount
        let remaining = direction == .forward ? count - firstFrame : firstFrame + 1
        let fps = Double(frameRate)
        let scale = playbackResolution.scale
        let mode = previewMode
        let falseColor = falseColorEnabled
        isPreviewActive = true
        isPlaying = true
        isLoadingPreview = false
        previewError = nil
        playbackTask = Task { [weak self, native] in
            let audioFormat = await native.audioInfo()
            guard let self, self.isPlaying, self.playbackGeneration == generation, !Task.isCancelled else { return }
            do {
                if let audioFormat {
                    self.playbackAudio = try PlaybackAudio(source: audioFormat, firstFrame: firstFrame, fps: fps, direction: direction)
                }
            } catch {
                self.stopPlayback(refreshPreview: false)
                self.previewError = "Could not start audio playback: \(error.localizedDescription)"
                return
            }
            let frames = PlaybackFrameQueue(remaining: remaining)
            self.playbackFrames = frames
            self.playbackProducer = Task { [weak self, native] in
                var lastWaveformTime = -Double.infinity
                for offset in 0..<remaining {
                    let next = direction == .forward ? firstFrame + offset : firstFrame - offset
                    guard let self, self.isPlaying, self.playbackGeneration == generation, !Task.isCancelled else { return }
                    do {
                        if let interruption = self.playbackAudio?.interruption { throw interruption }
                        while let audio = self.playbackAudio, audio.needsBuffer {
                            let samples = await native.audioSamples(start: audio.readStart, count: audio.nextCount, bits: audio.source.bits)
                            guard self.isPlaying, self.playbackGeneration == generation, !Task.isCancelled else { return }
                            if let interruption = audio.interruption { throw interruption }
                            guard let samples else { throw PlaybackAudio.AudioError.readFailed }
                            try audio.schedule(samples)
                        }
                    } catch {
                        _ = await frames.push(BufferedPlaybackFrame(index: next, result: DecodeResult(error: error.localizedDescription)))
                        frames.finish()
                        return
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    let analyze = self.playbackWaveformEnabled && now - lastWaveformTime >= 0.2
                    let result = await native.decode(index: next, scale: scale, request: requestID,
                                                     analyzeWaveform: analyze, mode: mode, falseColor: falseColor)
                    guard self.isPlaying, self.playbackGeneration == generation, !Task.isCancelled else { return }
                    if analyze { lastWaveformTime = ProcessInfo.processInfo.systemUptime }
                    guard await frames.push(BufferedPlaybackFrame(index: next, result: result)) else { return }
                    if result.pixels == nil { break }
                }
                frames.finish()
            }
            await frames.waitForPrefill()
            let timeline = PlaybackTimeline(firstFrame: firstFrame, frameCount: count, fps: fps, direction: direction)
            var startedAt: Double?
            while var frame = await frames.pop() {
                guard self.isPlaying, self.playbackGeneration == generation, !Task.isCancelled else { return }
                if let startedAt {
                    let elapsed = self.playbackAudio?.elapsed ?? (ProcessInfo.processInfo.systemUptime - startedAt)
                    let due = timeline.frame(at: elapsed)
                    while (direction == .forward ? frame.index < due : frame.index > due),
                          let next = frames.firstIndex, (direction == .forward ? next <= due : next >= due),
                          let newer = await frames.pop() { frame = newer }
                }
                if let interruption = self.playbackAudio?.interruption {
                    self.stopPlayback(refreshPreview: false)
                    self.previewError = interruption.localizedDescription
                    return
                }
                let result = frame.result
                let next = frame.index
                let offset = direction == .forward ? next - firstFrame : firstFrame - next
                guard let pixels = result.falseColorPixels ?? result.pixels else {
                    self.stopPlayback(refreshPreview: false)
                    self.previewError = result.error.isEmpty ? "Could not decode playback frame." : result.error
                    return
                }
                // Decode ahead of the presentation deadline, then wait for the
                // audio clock. Decoder work must not add latency to every frame.
                if let startedAt {
                    let elapsed = self.playbackAudio?.elapsed ?? (ProcessInfo.processInfo.systemUptime - startedAt)
                    let delay = max(0, Double(offset) / fps - elapsed)
                    if delay > 0 {
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    }
                    guard self.isPlaying, self.playbackGeneration == generation else { return }
                }
                let presentedAt = ProcessInfo.processInfo.systemUptime
                if startedAt == nil {
                    startedAt = presentedAt
                    self.playbackAudio?.play()
                }
                self.playbackFrame = pixels
                self.playbackUsesMetal = result.usesMetal
                self.isPresentingPlaybackFrame = true
                self.currentFrame = next
                self.isPresentingPlaybackFrame = false
                if let waveform = result.waveform { self.waveform = waveform }
                if offset == remaining - 1 {
                    let elapsed = self.playbackAudio?.elapsed ?? (ProcessInfo.processInfo.systemUptime - startedAt!)
                    let delay = max(0, Double(offset + 1) / fps - elapsed)
                    if delay > 0 {
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    }
                    guard self.isPlaying, self.playbackGeneration == generation else { return }
                    self.stopPlayback(refreshPreview: false)
                    if let finished = self.onPlaybackFinished { finished(self, direction) }
                    else { self.loadPreviewFrame() }
                    return
                }
            }
        }
    }

    func stopPlayback(refreshPreview: Bool = true) {
        guard isPlaying else { return }
        isPlaying = false
        playbackGeneration += 1
        playbackTask?.cancel()
        playbackTask = nil
        playbackProducer?.cancel()
        playbackProducer = nil
        playbackFrames?.finish(discard: true)
        playbackFrames = nil
        playbackAudio?.stop()
        playbackAudio = nil
        loadRequestID += 1
        native.setLatest(loadRequestID)
        if let playbackFrame { preview = makeNSImageBGRA(frame: playbackFrame) }
        if refreshPreview { loadPreviewFrame() }
    }
}

// ── Clipboard ──────────────────────────────────────
struct StoredAdjustments {
    var iso: UInt32
    var colorTemp: UInt32
    var tint: Int16
    var exposure: Float
    var highlightRecovery: Bool
    var gamutCompression: Bool
    var lensCorrections: UInt32
    var anamorphicMode: Int
    var customDesqueeze: Float
    var rotation: Int
    var flipHorizontal: Bool
    var flipVertical: Bool
    var toneCurveSupported: Bool
    var toneCurveEnabled: Bool
    var toneValues: [Float]
    var videoBlack: Bool
    var previewLUT: Bool
    var isoPresetIndex: Int
    var colorPresetIndex: Int
}

@MainActor
final class ProjectModel: ObservableObject {
    private let native = NativeProject()
    private let preferences: UserDefaults
    @Published var playbackLoopEnabled: Bool {
        didSet { preferences.set(playbackLoopEnabled, forKey: "playbackLoopEnabled") }
    }
    @Published var playbackResolution: PlaybackResolution {
        didSet {
            guard playbackResolution != oldValue else { return }
            preferences.set(playbackResolution.rawValue, forKey: "playbackResolution")
            for clip in clipCache.values { clip.playbackResolution = playbackResolution }
        }
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        playbackLoopEnabled = preferences.bool(forKey: "playbackLoopEnabled")
        playbackResolution = PlaybackResolution(rawValue: preferences.string(forKey: "playbackResolution") ?? "") ?? .full
    }
    fileprivate var nativeOwner: NativeProject { native }
    func releaseDecoders() { for clip in clipCache.values { clip.releaseDecoder() } }
    var projectHandle: OpaquePointer? { native.handle }
    @Published var waveformVisible = UserDefaults.standard.bool(forKey: "waveformVisible") {
        didSet {
            UserDefaults.standard.set(waveformVisible, forKey: "waveformVisible")
            selectedClip?.playbackWaveformEnabled = waveformVisible
        }
    }
    @Published var clipCount = 0
    @Published var selectedIndex = -1
    @Published private(set) var selectedIndices: Set<Int> = []
    private var selectionAnchor: Int?
    @Published var isExporting = false
    @Published var copiedSettings: StoredAdjustments?
    private var clipCache: [Int: ClipModel] = [:]
    @Published private(set) var importCount = 0
    @Published var importError: String?
    var isImporting: Bool { importCount > 0 }

    func importClip(path: String) -> Int {
        guard !isExporting else { return -1 }
        importCount += 1
        Task { [weak self, native] in
            let index = await native.importClip(path)
            guard let self else { return }
            self.importCount -= 1
            self.clipCount = Int(braw_project_get_clip_count(native.handle))
            if index >= 0 { self.selectClip(Int(index)) }
            else if index != -2 { self.importError = "Could not import \(URL(fileURLWithPath: path).lastPathComponent). The file may be damaged, unsupported, or exceed the processing memory limit." }
        }
        return 0
    }

    func removeClip(at index: Int) {
        guard !isExporting, !isImporting, index >= 0, index < clipCount,
              let h = projectHandle else { return }
        selectedClip?.releaseDecoder()
        clipCache.removeValue(forKey: index)
        braw_project_remove(h, Int32(index))
        clipCount = Int(braw_project_get_clip_count(h))
        selectedIndices = Set(selectedIndices.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 })
        if let anchor = selectionAnchor {
            selectionAnchor = anchor == index ? selectedIndices.min() : (anchor > index ? anchor - 1 : anchor)
        }
        var newCache: [Int: ClipModel] = [:]
        for (oldIdx, model) in clipCache {
            newCache[oldIdx > index ? oldIdx - 1 : oldIdx] = model
        }
        clipCache = newCache
        selectedIndex = -1
        braw_project_set_selected_index(h, -1)
        updatePreviewSelection()
    }

    func selectClip(_ index: Int, extendingRange: Bool = false, toggling: Bool = false) {
        guard !isExporting, index >= 0, index < clipCount else { return }
        if extendingRange, let anchor = selectionAnchor {
            let range = Set(min(anchor, index)...max(anchor, index))
            selectedIndices = toggling ? selectedIndices.union(range) : range
        } else if toggling {
            if selectedIndices.contains(index) { selectedIndices.remove(index) }
            else { selectedIndices.insert(index) }
            selectionAnchor = index
        } else {
            selectedIndices = [index]
            selectionAnchor = index
        }
        updatePreviewSelection()
    }

    func selectAllClips() {
        guard !isExporting, !isImporting, clipCount > 0 else { return }
        selectedIndices = Set(0..<clipCount)
        selectionAnchor = 0
        updatePreviewSelection()
    }

    private func updatePreviewSelection() {
        let first = selectedIndices.min() ?? -1
        guard first != selectedIndex, let h = projectHandle else { return }
        getClip(at: selectedIndex)?.releaseDecoder()
        braw_project_set_selected_index(h, Int32(first))
        selectedIndex = first
        getClip(at: first)?.playbackWaveformEnabled = waveformVisible
        getClip(at: first)?.loadPreviewFrame()
    }

    func getClip(at index: Int) -> ClipModel? {
        guard let h = projectHandle, index >= 0, index < clipCount else { return nil }
        if let cached = clipCache[index] { return cached }
        guard let ch = braw_project_get_clip_retained(h, Int32(index)) else { return nil }
        let model = ClipModel(id: index, handle: ch)
        model.playbackResolution = playbackResolution
        model.onPlaybackFinished = { [weak self] clip, direction in
            self?.playbackDidFinish(clip, direction: direction)
        }
        clipCache[index] = model
        return model
    }

    func navigatePlaybackClip(by offset: Int) {
        guard !isExporting, !isImporting, let current = selectedClip else { return }
        let next = selectedIndex + offset
        guard next >= 0, next < clipCount else { return }
        let wasPlaying = current.isPlaying
        let direction = current.playbackDirection
        selectClip(next)
        guard let clip = selectedClip else { return }
        clip.currentFrame = direction == .forward ? 0 : max(clip.frameCount, 1) - 1
        if wasPlaying { clip.startPlayback(direction: direction) }
    }

    func stopAndRewindPlayback() {
        guard !isExporting, !isImporting, let clip = selectedClip else { return }
        clip.stopPlayback(refreshPreview: false)
        clip.currentFrame = 0
    }

    private func playbackDidFinish(_ finished: ClipModel, direction: PlaybackDirection) {
        guard selectedClip === finished, !isExporting, !isImporting else { return }
        if playbackLoopEnabled {
            finished.startPlayback(direction: direction)
            return
        }
        let next = selectedIndex + (direction == .forward ? 1 : -1)
        if next >= 0 && next < clipCount {
            selectClip(next)
            if let clip = selectedClip {
                clip.currentFrame = direction == .forward ? 0 : max(clip.frameCount, 1) - 1
                clip.startPlayback(direction: direction)
            }
        } else { finished.loadPreviewFrame() }
    }

    func copySettings(from index: Int) {
        guard let clip = getClip(at: index) else { return }
        copiedSettings = StoredAdjustments(
            iso: clip.iso,
            colorTemp: clip.colorTemp,
            tint: clip.tint,
            exposure: clip.exposure,
            highlightRecovery: clip.highlightRecovery,
            gamutCompression: clip.gamutCompression,
            lensCorrections: clip.lensCorrections,
            anamorphicMode: clip.anamorphicMode, customDesqueeze: clip.customDesqueeze, rotation: clip.rotation,
            flipHorizontal: clip.flipHorizontal, flipVertical: clip.flipVertical,
            toneCurveSupported: clip.toneCurveSupported, toneCurveEnabled: clip.toneCurveEnabled, toneValues: clip.toneValues, videoBlack: clip.videoBlack,
            previewLUT: clip.previewLUT,
            isoPresetIndex: clip.isoPresetIndex,
            colorPresetIndex: clip.colorPresetIndex
        )
    }

    func pasteSettings(to index: Int) {
        guard !isExporting else { return }
        guard let settings = copiedSettings else { return }
        guard let clip = getClip(at: index) else { return }
        clip.iso = settings.iso
        clip.colorTemp = settings.colorTemp
        clip.tint = settings.tint
        clip.exposure = settings.exposure
        clip.highlightRecovery = settings.highlightRecovery
        clip.gamutCompression = settings.gamutCompression
        clip.lensCorrections = settings.lensCorrections
        clip.customDesqueeze = settings.customDesqueeze
        clip.anamorphicMode = settings.anamorphicMode; clip.rotation = settings.rotation
        clip.flipHorizontal = settings.flipHorizontal; clip.flipVertical = settings.flipVertical
        clip.toneValues = settings.toneCurveSupported ? settings.toneValues : clip.toneDefaults; clip.videoBlack = settings.toneCurveSupported ? settings.videoBlack : clip.defaultVideoBlack
        clip.toneCurveEnabled = settings.toneCurveEnabled
        clip.previewLUT = settings.previewLUT
        clip.synchronizePresetLabels()
    }

    func clearAllClips() {
        guard !isExporting, !isImporting else { return }
        guard let h = projectHandle else { return }
        clipCache.removeAll()
        braw_project_clear(h)
        clipCount = 0
        selectedIndex = -1
        selectedIndices = []
        selectionAnchor = nil
    }

    func applyClipSettingsToAll(from sourceIndex: Int) {
        guard !isExporting else { return }
        guard let h = projectHandle else { return }
        guard let srcHandle = braw_project_get_clip(h, Int32(sourceIndex)) else { return }
        for i in 0..<clipCount {
            guard i != sourceIndex else { continue }
            // Construct the model before copying: initialization applies native
            // WB/highlight defaults and must not overwrite the copied values.
            if let target = getClip(at: i), let dstHandle = braw_project_get_clip(h, Int32(i)) {
                braw_clip_copy_adjustments(srcHandle, dstHandle)
                target.refreshAdjustmentsFromEngine()
                let sourceISO = braw_clip_get_iso(srcHandle)
                if target.iso != sourceISO {
                    target.isoAdjustmentNotice = "ISO \(sourceISO) is unavailable for this recording. Using \(target.iso) (As Shot)."
                }
            }
        }
    }

    var selectedClip: ClipModel? {
        getClip(at: selectedIndex)
    }
}

// ── Export Manager ────────────────────────────────

private final class ExportOperation: @unchecked Sendable {
    let native: NativeProject
    let settings: ExportUISettings
    let progress: @Sendable (Int32, Int32, Int32, Int32) -> Void
    init(native: NativeProject, settings: ExportUISettings,
         progress: @escaping @Sendable (Int32, Int32, Int32, Int32) -> Void) {
        self.native = native; self.settings = settings; self.progress = progress
    }
    func run() -> (Int32, String, String) {
        let indices = settings.selectedIndices.map { Int32($0) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = indices.withUnsafeBufferPointer { buffer in
            braw_export_start_with_options(native.handle, buffer.baseAddress, Int32(buffer.count),
                Int32(settings.codec), Int32(settings.proResProfile), Int32(settings.resolutionMode),
                Int32(settings.dataRateMbps), Int32(settings.gopMode), Int32(settings.chromaMode), settings.outputDir, { ci, tc, frame, total, raw in
                    guard let raw else { return }
                    Unmanaged<ExportOperation>.fromOpaque(raw).takeUnretainedValue().progress(ci, tc, frame, total)
                }, context)
        }
        return (result, String(cString: braw_export_last_error()), String(cString: braw_export_last_warning()))
    }
}

@MainActor
final class ExportManager: ObservableObject {
    @Published var isExporting = false
    @Published var isCancelling = false
    @Published var progress: Double = 0
    @Published var currentClipName = ""
    @Published var currentFrame = 0
    @Published var totalFrames = 0
    @Published var clipIndex = 0
    @Published var totalClips = 0
    @Published var statusMessage: String?
    private let projectModel: ProjectModel
    private var exportID = UUID()
    init(project: ProjectModel) { projectModel = project }

    func export(settings original: ExportUISettings) {
        guard !isExporting, !projectModel.isImporting else { return }
        var settings = original
        if settings.selectedIndices.isEmpty { settings.selectedIndices = Array(0..<projectModel.clipCount) }
        guard !settings.selectedIndices.isEmpty else { return }
        settings.outputDir = (settings.outputDir as NSString).expandingTildeInPath
        guard braw_export_prepare() == 0 else { statusMessage = "Another export is already running."; return }
        isExporting = true; projectModel.isExporting = true; isCancelling = false
        statusMessage = nil; progress = 0; currentFrame = 0; totalFrames = 0
        totalClips = settings.selectedIndices.count
        let runID = UUID()
        exportID = runID
        let clipNames = settings.selectedIndices.map { projectModel.getClip(at: $0)?.fileName ?? "" }
        currentClipName = clipNames.first ?? ""
        projectModel.releaseDecoders()
        let operation = ExportOperation(native: projectModel.nativeOwner, settings: settings) { [weak self] ci, tc, frame, total in
            Task { @MainActor [weak self] in
                guard let self, self.isExporting, self.exportID == runID else { return }
                self.clipIndex = Int(ci); self.totalClips = Int(tc)
                if clipNames.indices.contains(Int(ci)) { self.currentClipName = clipNames[Int(ci)] }
                self.currentFrame = Int(frame); self.totalFrames = Int(total)
                let clipProgress = Double(frame) / Double(max(total, 1))
                self.progress = min(0.99, (Double(ci) + clipProgress) / Double(max(tc, 1)))
            }
        }
        Task { [self, operation] in
            let (result, error, warning) = await Task.detached(priority: .userInitiated) { operation.run() }.value
            isExporting = false; projectModel.isExporting = false; isCancelling = false
            // Export suspends every preview decoder. Resume the visible clip
            // on success, cancellation, or failure so edits refresh it again.
            projectModel.selectedClip?.loadPreviewFrame()
            if result == 0 { progress = 1; statusMessage = warning.isEmpty ? "Export complete." : "Export complete.\n" + warning }
            else if result == -2 { statusMessage = "Export cancelled." }
            else {
                statusMessage = error.isEmpty ? "Export failed." : error
                if !warning.isEmpty && result != -3 { statusMessage = (statusMessage ?? "") + "\n" + warning }
            }
        }
    }
    func cancel() {
        guard isExporting, !isCancelling else { return }
        isCancelling = true
        braw_export_cancel()
    }
}

struct ExportUISettings: Sendable {
    var codec = 1
    var proResProfile = 3
    var resolutionMode = 0
    var dataRateMbps = 200
    var gopMode = 0
    var chromaMode = 0
    var outputDir = ""
    var selectedIndices: [Int] = []
}

// ── Image helpers (CPU decode → NSImage) ──────────

@MainActor
func makeNSImageBGRA(frame: DecodedPixels) -> NSImage? {
    let bytesPerRow = frame.width * 4
    guard let provider = CGDataProvider(data: frame.data as CFData) else { return nil }
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let image = CGImage(width: frame.width, height: frame.height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo, provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: frame.width, height: frame.height))
}
