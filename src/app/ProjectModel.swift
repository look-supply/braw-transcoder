import Foundation
import AppKit
import CoreGraphics

// ── C API declarations ────────────────────────────
@_silgen_name("braw_project_create")        func _braw_project_create() -> OpaquePointer
@_silgen_name("braw_project_destroy")       func _braw_project_destroy(_ h: OpaquePointer)
@_silgen_name("braw_project_import")        func _braw_project_import(_ h: OpaquePointer, _ path: UnsafePointer<CChar>) -> Int32
@_silgen_name("braw_project_remove")        func _braw_project_remove(_ h: OpaquePointer, _ index: Int32)
@_silgen_name("braw_project_get_clip_count") func _braw_project_get_clip_count(_ h: OpaquePointer) -> Int32
@_silgen_name("braw_project_get_clip")       func _braw_project_get_clip(_ h: OpaquePointer, _ index: Int32) -> OpaquePointer?
@_silgen_name("braw_project_get_selected_index") func _braw_project_get_selected_index(_ h: OpaquePointer) -> Int32
@_silgen_name("braw_project_set_selected_index") func _braw_project_set_selected_index(_ h: OpaquePointer, _ index: Int32)
@_silgen_name("braw_project_clear")         func _braw_project_clear(_ h: OpaquePointer)

@_silgen_name("braw_clip_open")             func _braw_clip_open(_ path: UnsafePointer<CChar>) -> OpaquePointer?
@_silgen_name("braw_clip_close")            func _braw_clip_close(_ h: OpaquePointer)
@_silgen_name("braw_clip_get_filename")     func _braw_clip_get_filename(_ h: OpaquePointer) -> UnsafePointer<CChar>
@_silgen_name("braw_clip_get_filepath")     func _braw_clip_get_filepath(_ h: OpaquePointer) -> UnsafePointer<CChar>
@_silgen_name("braw_clip_get_gamma")        func _braw_clip_get_gamma(_ h: OpaquePointer) -> UnsafePointer<CChar>
@_silgen_name("braw_clip_get_gamut")        func _braw_clip_get_gamut(_ h: OpaquePointer) -> UnsafePointer<CChar>
@_silgen_name("braw_clip_get_color_science_gen") func _braw_clip_get_color_science_gen(_ h: OpaquePointer) -> UInt16
@_silgen_name("braw_clip_get_width")        func _braw_clip_get_width(_ h: OpaquePointer) -> UInt32
@_silgen_name("braw_clip_get_height")       func _braw_clip_get_height(_ h: OpaquePointer) -> UInt32
@_silgen_name("braw_clip_get_frame_rate")   func _braw_clip_get_frame_rate(_ h: OpaquePointer) -> Float
@_silgen_name("braw_clip_get_frame_count")  func _braw_clip_get_frame_count(_ h: OpaquePointer) -> UInt64
@_silgen_name("braw_clip_get_iso")          func _braw_clip_get_iso(_ h: OpaquePointer) -> UInt32
@_silgen_name("braw_clip_set_iso")          func _braw_clip_set_iso(_ h: OpaquePointer, _ v: UInt32)
@_silgen_name("braw_clip_get_color_temp")   func _braw_clip_get_color_temp(_ h: OpaquePointer) -> UInt32
@_silgen_name("braw_clip_set_color_temp")   func _braw_clip_set_color_temp(_ h: OpaquePointer, _ v: UInt32)
@_silgen_name("braw_clip_get_tint")         func _braw_clip_get_tint(_ h: OpaquePointer) -> Int16
@_silgen_name("braw_clip_set_tint")         func _braw_clip_set_tint(_ h: OpaquePointer, _ v: Int16)
@_silgen_name("braw_clip_get_exposure")     func _braw_clip_get_exposure(_ h: OpaquePointer) -> Float
@_silgen_name("braw_clip_set_exposure")     func _braw_clip_set_exposure(_ h: OpaquePointer, _ v: Float)
@_silgen_name("braw_clip_get_highlight_recovery") func _braw_clip_get_highlight_recovery(_ h: OpaquePointer) -> Bool
@_silgen_name("braw_clip_set_highlight_recovery") func _braw_clip_set_highlight_recovery(_ h: OpaquePointer, _ v: Bool)
@_silgen_name("braw_clip_get_preview_lut")  func _braw_clip_get_preview_lut(_ h: OpaquePointer) -> Bool
@_silgen_name("braw_clip_set_preview_lut")  func _braw_clip_set_preview_lut(_ h: OpaquePointer, _ v: Bool)
@_silgen_name("braw_clip_get_bake_lut")     func _braw_clip_get_bake_lut(_ h: OpaquePointer) -> Bool
@_silgen_name("braw_clip_set_bake_lut")     func _braw_clip_set_bake_lut(_ h: OpaquePointer, _ v: Bool)
@_silgen_name("braw_clip_decode_frame")     func _braw_clip_decode_frame(_ h: OpaquePointer, _ index: UInt64, _ w: UnsafeMutablePointer<Int32>, _ outH: UnsafeMutablePointer<Int32>) -> UnsafeMutablePointer<UInt8>?
@_silgen_name("braw_clip_free_frame")        func _braw_clip_free_frame(_ data: UnsafeMutablePointer<UInt8>)
@_silgen_name("braw_clip_copy_adjustments")  func _braw_clip_copy_adjustments(_ src: OpaquePointer, _ dst: OpaquePointer)
@_silgen_name("braw_export_start")            func _braw_export_start(_ proj: OpaquePointer, _ indices: UnsafePointer<Int32>, _ count: Int32, _ codec: Int32, _ proResProfile: Int32, _ resolutionMode: Int32, _ dataRateMbps: Int32, _ outputDir: UnsafePointer<CChar>, _ progressFn: @convention(c) (Int32, Int32, Int32, Int32, UnsafeMutableRawPointer?) -> Void, _ ctx: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("braw_export_cancel")           func _braw_export_cancel()
@_silgen_name("braw_export_is_running")       func _braw_export_is_running() -> Int32

// ── Image data holder (bridge-safe) ────────────────
struct FrameImage {
    let cgImage: CGImage
    let nsImage: NSImage
}

// ── Swift model ──────────────────────────────────

final class ClipModel: Identifiable, ObservableObject {
    let id: Int
    private var handle: OpaquePointer?
    
    @Published var iso: UInt32 = 800 {
        didSet { if let h = handle { _braw_clip_set_iso(h, iso) }; schedulePreviewRefresh() }
    }
    @Published var colorTemp: UInt32 = 5600 {
        didSet { if let h = handle { _braw_clip_set_color_temp(h, colorTemp) }; schedulePreviewRefresh() }
    }
    @Published var tint: Int16 = 0 {
        didSet { if let h = handle { _braw_clip_set_tint(h, tint) }; schedulePreviewRefresh() }
    }
    @Published var exposure: Float = 0 {
        didSet { if let h = handle { _braw_clip_set_exposure(h, exposure) }; schedulePreviewRefresh() }
    }
    @Published var highlightRecovery = false {
        didSet { if let h = handle { _braw_clip_set_highlight_recovery(h, highlightRecovery) }; schedulePreviewRefresh() }
    }
    @Published var previewLUT = false {
        didSet { if let h = handle { _braw_clip_set_preview_lut(h, previewLUT) }; schedulePreviewRefresh() }
    }
    @Published var bakeLUT = false {
        didSet { if let h = handle { _braw_clip_set_bake_lut(h, bakeLUT) } }
    }
    @Published var currentFrame: UInt64 = 0 {
        didSet { loadPreviewFrame() }
    }
    
    @Published var thumbnail: NSImage? = nil
    @Published var preview: NSImage? = nil
    @Published var isLoadingPreview = false
    
    private var loadRequestID: UInt64 = 0
    private var pendingRefresh: DispatchWorkItem?
    
    private var _fileName: String = ""
    var fileName: String { _fileName }
    
    private var _dirPath: String = ""
    var directoryPath: String { _dirPath }
    
    private var _gamma: String = ""
    var gamma: String { _gamma }
    private var _gamut: String = ""
    var gamut: String { _gamut }
    var colorScienceGen: UInt16 = 0
    
    // Presets
    @Published var isoPresetIndex: Int = -1  // -1 = custom
    @Published var colorPresetIndex: Int = -1 // -1 = custom

    // ISO presets (standard BRAW increments)
    static let isoPresets: [UInt32] = [
        100, 125, 160, 200, 250, 320, 400, 500, 640,
        800, 1000, 1250, 1600, 2000, 2500, 3200, 4000,
        5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600
    ]
    static let isoPresetLabels: [String] = isoPresets.map { "\($0)" } + ["Custom"]
    
    // Color temp presets
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
    static let colorPresetLabels: [String] = colorPresets.map { $0.name } + ["Custom"]
    
    init(id: Int, handle: OpaquePointer?) {
        self.id = id
        self.handle = handle
        if let h = handle {
            _fileName = String(cString: _braw_clip_get_filename(h))
            let fullPath = String(cString: _braw_clip_get_filepath(h))
            if let lastSlash = fullPath.lastIndex(of: "/") {
                _dirPath = String(fullPath[..<lastSlash])
            }
            _gamma = String(cString: _braw_clip_get_gamma(h))
            _gamut = String(cString: _braw_clip_get_gamut(h))
            colorScienceGen = _braw_clip_get_color_science_gen(h)
            iso = _braw_clip_get_iso(h)
            colorTemp = _braw_clip_get_color_temp(h)
            tint = _braw_clip_get_tint(h)
            exposure = _braw_clip_get_exposure(h)
            highlightRecovery = _braw_clip_get_highlight_recovery(h)
        }
        if handle != nil {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.loadThumbnail()
            }
        }
    }
    
    var nativeWidth: UInt32  { handle.map { _braw_clip_get_width($0) } ?? 0 }
    var nativeHeight: UInt32 { handle.map { _braw_clip_get_height($0) } ?? 0 }
    var frameRate: Float     { handle.map { _braw_clip_get_frame_rate($0) } ?? 0 }
    var frameCount: UInt64   { handle.map { _braw_clip_get_frame_count($0) } ?? 0 }
    
    func applyToEngine() {
        guard let h = handle else { return }
        _braw_clip_set_iso(h, iso)
        _braw_clip_set_color_temp(h, colorTemp)
        _braw_clip_set_tint(h, tint)
        _braw_clip_set_exposure(h, exposure)
        _braw_clip_set_highlight_recovery(h, highlightRecovery)
        _braw_clip_set_preview_lut(h, previewLUT)
        _braw_clip_set_bake_lut(h, bakeLUT)
    }
    
    func loadThumbnail() {
        guard let h = handle else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var w: Int32 = 0, outH: Int32 = 0
            guard let pixels = _braw_clip_decode_frame(h, 0, &w, &outH) else { return }
            defer { _braw_clip_free_frame(pixels) }
            
            if let img = makeNSImage(pixels: pixels, width: Int(w), height: Int(outH)) {
                let thumb = resize(img, to: NSSize(width: 200, height: 112))
                DispatchQueue.main.async {
                    self.thumbnail = thumb
                    self.refreshAdjustmentsFromEngine()
                }
            }
        }
    }
    
    func refreshAdjustmentsFromEngine() {
        guard let h = handle else { return }
        iso = _braw_clip_get_iso(h)
        colorTemp = _braw_clip_get_color_temp(h)
        tint = _braw_clip_get_tint(h)
        exposure = _braw_clip_get_exposure(h)
        highlightRecovery = _braw_clip_get_highlight_recovery(h)
    }
    
    func applyISOPreset(_ index: Int) {
        if index >= 0 && index < Self.isoPresets.count {
            iso = Self.isoPresets[index]
        }
        isoPresetIndex = index
        schedulePreviewRefresh()
    }
    
    func applyColorPreset(_ index: Int) {
        if index >= 0 && index < Self.colorPresets.count {
            let preset = Self.colorPresets[index]
            colorTemp = preset.temp
            tint = preset.tint
        }
        colorPresetIndex = index
        schedulePreviewRefresh()
    }
    
    func resetAdjustments() {
        guard let h = handle else { return }
        iso = 800
        colorTemp = 5600
        tint = 0
        exposure = 0
        highlightRecovery = false
        previewLUT = false
        bakeLUT = false
        // Write defaults to engine
        _braw_clip_set_iso(h, iso)
        _braw_clip_set_color_temp(h, colorTemp)
        _braw_clip_set_tint(h, tint)
        _braw_clip_set_exposure(h, exposure)
        _braw_clip_set_highlight_recovery(h, false)
        _braw_clip_set_preview_lut(h, false)
        _braw_clip_set_bake_lut(h, false)
        schedulePreviewRefresh()
    }
    
    func schedulePreviewRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.loadPreviewFrame()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    
    func loadPreviewFrame() {
        guard let h = handle else { return }
        isLoadingPreview = true
        loadRequestID += 1
        let requestID = loadRequestID
        let frameIdx = currentFrame
        
        DispatchQueue.global(qos: .default).async { [weak self] in
            guard let self = self else { return }
            var w: Int32 = 0, outH: Int32 = 0
            guard let pixels = _braw_clip_decode_frame(h, frameIdx, &w, &outH) else {
                DispatchQueue.main.async {
                    if self.loadRequestID == requestID { self.isLoadingPreview = false }
                }
                return
            }
            defer { _braw_clip_free_frame(pixels) }
            
            let img = makeNSImage(pixels: pixels, width: Int(w), height: Int(outH))
            DispatchQueue.main.async {
                guard self.loadRequestID == requestID else { return }
                self.preview = img
                self.isLoadingPreview = false
            }
        }
    }
}

final class ProjectModel: ObservableObject {
    var projectHandle: OpaquePointer?
    @Published var clipCount = 0
    @Published var selectedIndex = -1
    private var clipCache: [Int: ClipModel] = [:]
    
    init() {
        projectHandle = _braw_project_create()
    }
    
    deinit {
        clipCache.removeAll()
        if let h = projectHandle { _braw_project_destroy(h) }
    }
    
    func importClip(path: String) -> Int {
        guard let h = projectHandle else { return -1 }
        let idx = _braw_project_import(h, path)
        let count = Int(_braw_project_get_clip_count(h))
        clipCount = count
        if idx >= 0 && selectedIndex < 0 { selectedIndex = Int(idx) }
        let finalIdx = Int(idx)
        if finalIdx >= 0 {
            selectClip(finalIdx)
        }
        return finalIdx
    }
    
    func removeClip(at index: Int) {
        guard let h = projectHandle else { return }
        clipCache.removeValue(forKey: index)
        _braw_project_remove(h, Int32(index))
        clipCount = Int(_braw_project_get_clip_count(h))
        selectedIndex = Int(_braw_project_get_selected_index(h))
        // Rebuild cache with shifted indices
        var newCache: [Int: ClipModel] = [:]
        for (oldIdx, model) in clipCache {
            if oldIdx > index { newCache[oldIdx - 1] = model }
            else { newCache[oldIdx] = model }
        }
        clipCache = newCache
    }
    
    func selectClip(_ index: Int) {
        guard let h = projectHandle else { return }
        _braw_project_set_selected_index(h, Int32(index))
        selectedIndex = index
        
        if let clip = getClip(at: index) {
            clip.loadPreviewFrame()
        }
    }
    
    func getClip(at index: Int) -> ClipModel? {
        guard let h = projectHandle, index >= 0, index < clipCount else { return nil }
        if let cached = clipCache[index] {
            return cached
        }
        guard let ch = _braw_project_get_clip(h, Int32(index)) else { return nil }
        let model = ClipModel(id: index, handle: ch)
        clipCache[index] = model
        return model
    }
    
    func copySettings(from index: Int) {}
    
    func pasteSettings(to index: Int) {
        guard let h = projectHandle, index >= 0, index < clipCount else { return }
        guard let targetHandle = _braw_project_get_clip(h, Int32(index)) else { return }
        let srcIdx = selectedIndex
        guard srcIdx >= 0, srcIdx < clipCount, srcIdx != index else { return }
        guard let sourceHandle = _braw_project_get_clip(h, Int32(srcIdx)) else { return }
        _braw_clip_copy_adjustments(sourceHandle, targetHandle)
    }
    
    var selectedClip: ClipModel? {
        getClip(at: selectedIndex)
    }
}

// ── Export Manager ────────────────────────────────

final class ExportManager: ObservableObject, @unchecked Sendable {
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var currentClipName = ""
    @Published var currentFrame: Int = 0
    @Published var totalFrames: Int = 0
    @Published var clipIndex: Int = 0
    @Published var totalClips: Int = 0
    
    private var projectModel: ProjectModel
    
    init(project: ProjectModel) {
        self.projectModel = project
    }
    
    func export(settings: ExportUISettings) {
        guard !isExporting, let h = projectModel.projectHandle else { return }
        isExporting = true
        progress = 0
        
        // Build clip indices
        let indices = settings.selectedIndices.isEmpty
            ? Array(0..<projectModel.clipCount)
            : settings.selectedIndices.sorted()
        totalClips = indices.count
        
        guard !indices.isEmpty else { isExporting = false; return }
        
        var cIndices = indices.map { Int32($0) }
        let rawPtr = Unmanaged.passUnretained(self).toOpaque()
        
        DispatchQueue.global(qos: .userInitiated).async {
            _ = _braw_export_start(
                h,
                &cIndices, Int32(cIndices.count),
                Int32(settings.codec), Int32(settings.proResProfile),
                Int32(settings.resolutionMode), Int32(settings.dataRateMbps),
                settings.outputDir,
                { (clipIdx, totalC, frameIdx, totalF, ctx) in
                    guard let ctx = ctx else { return }
                    let mgr = Unmanaged<ExportManager>.fromOpaque(ctx).takeUnretainedValue()
                    DispatchQueue.main.async {
                        if frameIdx < 0 {
                            mgr.isExporting = false
                            mgr.progress = 1.0
                        } else {
                            mgr.clipIndex = Int(clipIdx)
                            mgr.totalClips = Int(totalC)
                            mgr.currentFrame = Int(frameIdx)
                            mgr.totalFrames = Int(totalF)
                            let clipProgress = Double(frameIdx + 1) / Double(max(totalF, 1))
                            let overall = (Double(clipIdx) + clipProgress) / Double(max(totalC, 1))
                            mgr.progress = overall
                        }
                    }
                },
                rawPtr
            )
        }
    }
    
    func cancel() {
        _braw_export_cancel()
    }
}

struct ExportUISettings {
    var codec = 1           // 0=H264, 1=H265, 2=ProRes
    var proResProfile = 3   // 0-5
    var resolutionMode = 0  // 0=passthrough
    var dataRateMbps = 200
    var outputDir = ""
    var selectedIndices: [Int] = []
}

// ── Image helpers ─────────────────────────────────

private func makeNSImage(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> NSImage? {
    let bytesPerRow = width * 4
    let data = Data(bytes: pixels, count: bytesPerRow * height)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    
    let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    
    guard let cg = CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ) else { return nil }
    
    return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
}

private func resize(_ image: NSImage, to size: NSSize) -> NSImage {
    let result = NSImage(size: size)
    result.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: size),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy,
               fraction: 1.0)
    result.unlockFocus()
    return result
}
