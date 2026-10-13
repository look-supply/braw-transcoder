import Foundation
import AppKit
import CoreGraphics

// Native ownership is confined to these wrappers. The bridge serializes access
// with native mutexes, and queued work retains its wrapper until completion.
private struct DecodedPixels: Sendable {
    let data: Data
    let width: Int
    let height: Int
}
private struct DecodeResult: Sendable {
    var pixels: DecodedPixels?
    var waveform: RGBWaveform?
    var error: String = ""
}
private final class NativeClip: @unchecked Sendable {
    let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.braw.clip", qos: .userInitiated)
    private let lock = NSLock()
    private var latestRequest: UInt64 = 0
    private var latestThumbnailRequest: UInt64 = 0
    init(retainedHandle: OpaquePointer) { handle = retainedHandle }
    deinit { braw_clip_close(handle) }
    func setLatest(_ request: UInt64) { lock.withLock { latestRequest = request } }
    func setLatestThumbnail(_ request: UInt64) { lock.withLock { latestThumbnailRequest = request } }
    func decode(index: UInt64, scale: Float, request: UInt64? = nil, thumbnailRequest: UInt64? = nil, analyzeWaveform: Bool = false) async -> DecodeResult {
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
                guard let pixels = braw_clip_decode_frame_scaled(handle, index, &width, &height, scale) else {
                    continuation.resume(returning: DecodeResult(error: String(cString: braw_clip_last_error(handle)))); return
                }
                defer { braw_clip_free_frame(pixels) }
                guard width > 0, height > 0 else {
                    continuation.resume(returning: DecodeResult(error: "Decoder returned an invalid image.")); return
                }
                let frame = DecodedPixels(data: Data(bytes: pixels, count: Int(width) * Int(height) * 4),
                                          width: Int(width), height: Int(height))
                if isStale() {
                    continuation.resume(returning: DecodeResult()); return
                }
                let waveform = analyzeWaveform
                    ? RGBWaveform.analyze(bgra: frame.data, width: frame.width, height: frame.height) : nil
                continuation.resume(returning: DecodeResult(pixels: frame, waveform: waveform))
            }
        }
    }
    func releaseDecoder() {
        queue.async { [self] in braw_clip_release_decoder(handle) }
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
        didSet { if let h = handle { braw_clip_set_preview_lut(h, previewLUT) }; schedulePreviewRefresh() }
    }
    @Published var currentFrame: UInt64 = 0 {
        didSet { loadPreviewFrame() }
    }

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
    var frameCount: UInt64   { handle.map { braw_clip_get_frame_count($0) } ?? 0 }

    func releaseDecoder() {
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
        isPreviewActive = true
        isLoadingPreview = true
        previewError = nil
        loadRequestID += 1
        let requestID = loadRequestID
        let frameIndex = currentFrame
        // Display previews need screen-sized pixels, especially for 12K/17K
        // sources. Export resolution remains independent of this SDK reduction.
        let longestEdge = max(nativeWidth, nativeHeight)
        let previewScale: Float = longestEdge > 10240 ? 0.125
            : longestEdge > 5120 ? 0.25 : longestEdge > 2560 ? 0.5 : 1
        native.setLatest(requestID)
        Task { [weak self, native] in
            let result = await native.decode(index: frameIndex, scale: previewScale, request: requestID, analyzeWaveform: true)
            guard let self, self.loadRequestID == requestID else { return }
            self.isLoadingPreview = false
            self.waveform = result.waveform
            if let pixels = result.pixels { self.preview = makeNSImageBGRA(frame: pixels) }
            else if !result.error.isEmpty { self.previewError = result.error }
        }
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
    fileprivate var nativeOwner: NativeProject { native }
    func releaseDecoders() { for clip in clipCache.values { clip.releaseDecoder() } }
    var projectHandle: OpaquePointer? { native.handle }
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

    private func updatePreviewSelection() {
        let first = selectedIndices.min() ?? -1
        guard first != selectedIndex, let h = projectHandle else { return }
        getClip(at: selectedIndex)?.releaseDecoder()
        braw_project_set_selected_index(h, Int32(first))
        selectedIndex = first
        getClip(at: first)?.loadPreviewFrame()
    }

    func getClip(at index: Int) -> ClipModel? {
        guard let h = projectHandle, index >= 0, index < clipCount else { return nil }
        if let cached = clipCache[index] { return cached }
        guard let ch = braw_project_get_clip_retained(h, Int32(index)) else { return nil }
        let model = ClipModel(id: index, handle: ch)
        clipCache[index] = model
        return model
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
            braw_export_start(native.handle, buffer.baseAddress, Int32(buffer.count),
                Int32(settings.codec), Int32(settings.proResProfile), Int32(settings.resolutionMode),
                Int32(settings.dataRateMbps), settings.outputDir, { ci, tc, frame, total, raw in
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
    var outputDir = ""
    var selectedIndices: [Int] = []
}

// ── Image helpers (CPU decode → NSImage) ──────────

@MainActor
private func makeNSImageBGRA(frame: DecodedPixels) -> NSImage? {
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
