import Foundation
import AppKit
import CoreGraphics
import Metal
import Metal

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
@_silgen_name("braw_clip_decode_frame_gpu")  func _braw_clip_decode_frame_gpu(_ h: OpaquePointer, _ index: UInt64, _ w: UnsafeMutablePointer<Int32>, _ outH: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer?
@_silgen_name("braw_clip_decode_frame_gpu_scaled") func _braw_clip_decode_frame_gpu_scaled(_ h: OpaquePointer, _ index: UInt64, _ w: UnsafeMutablePointer<Int32>, _ outH: UnsafeMutablePointer<Int32>, _ scale: Float) -> UnsafeMutableRawPointer?
@_silgen_name("braw_clip_free_frame_gpu")    func _braw_clip_free_frame_gpu(_ ptr: UnsafeMutableRawPointer?)
@_silgen_name("braw_clip_copy_adjustments")  func _braw_clip_copy_adjustments(_ src: OpaquePointer, _ dst: OpaquePointer)
@_silgen_name("braw_clip_ensure_decoder")    func _braw_clip_ensure_decoder(_ h: OpaquePointer)
@_silgen_name("braw_clip_release_decoder")   func _braw_clip_release_decoder(_ h: OpaquePointer)
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
    @Published var previewLUT = true {
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
    private var _filePath: String = ""
    var filePath: String { _filePath }
    
    private var _gamma: String = ""
    var gamma: String { _gamma }
    private var _gamut: String = ""
    var gamut: String { _gamut }
    var colorScienceGen: UInt16 = 0
    
    // Global decode queue — allow 3 concurrent decodes
    private static let decodeQueue = DispatchQueue(label: "com.braw.decode", qos: .userInitiated,
                                                    attributes: .concurrent)
    private static let decodeSem = DispatchSemaphore(value: 3)
    private var thumbnailLoaded = false
    
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
            _filePath = fullPath
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
            previewLUT = _braw_clip_get_preview_lut(h)
        }
        // Don't auto-load thumbnail — loaded on-demand when visible in sidebar
    }
    
    func ensureDecoder() {
        if let h = handle { _braw_clip_ensure_decoder(h) }
    }
    
    func releaseDecoder() {
        if let h = handle { _braw_clip_release_decoder(h) }
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
        guard let h = handle, !thumbnailLoaded else { return }
        thumbnailLoaded = true
        Self.decodeQueue.async { [weak self] in
            guard self != nil else { return }
            Self.decodeSem.wait()
            defer { Self.decodeSem.signal() }
            
            var w: Int32 = 0, outH: Int32 = 0
            guard let mtlBufRaw = _braw_clip_decode_frame_gpu_scaled(h, 0, &w, &outH, 0.25) else { return }
            let mtlBuf = unsafeBitCast(mtlBufRaw, to: MTLBuffer.self)
            
            let img = MetalRenderer.shared.makeNSImageFromMetalBufferReadback(mtlBuf, width: Int(w), height: Int(outH))
            let thumb = img.flatMap { resize($0, to: NSSize(width: 200, height: 112)) }
            _braw_clip_free_frame_gpu(mtlBufRaw)
            
            DispatchQueue.main.async { [weak self] in
                self?.thumbnail = thumb
                self?.refreshAdjustmentsFromEngine()
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
        previewLUT = true
        bakeLUT = false
        // Write defaults to engine
        _braw_clip_set_iso(h, iso)
        _braw_clip_set_color_temp(h, colorTemp)
        _braw_clip_set_tint(h, tint)
        _braw_clip_set_exposure(h, exposure)
        _braw_clip_set_highlight_recovery(h, false)
        _braw_clip_set_preview_lut(h, true)
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
        
        Self.decodeQueue.async { [weak self] in
            guard let self = self else { return }
            Self.decodeSem.wait()
            defer { Self.decodeSem.signal() }
            
            var w: Int32 = 0, outH: Int32 = 0
            guard let mtlBufRaw = _braw_clip_decode_frame_gpu(h, frameIdx, &w, &outH) else {
                DispatchQueue.main.async {
                    if self.loadRequestID == requestID { self.isLoadingPreview = false }
                }
                return
            }
            let mtlBuf = unsafeBitCast(mtlBufRaw, to: MTLBuffer.self)
            
            let img = MetalRenderer.shared.makeNSImageFromMetalBuffer(mtlBuf, width: Int(w), height: Int(outH))
            _braw_clip_free_frame_gpu(mtlBufRaw)
            
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
    @Published var isExporting = false
    private var clipCache: [Int: ClipModel] = [:]
    private let importQueue = DispatchQueue(label: "com.braw.import", qos: .userInitiated)
    
    init() {
        projectHandle = _braw_project_create()
    }
    
    deinit {
        clipCache.removeAll()
        if let h = projectHandle { _braw_project_destroy(h) }
    }
    
    func importClip(path: String) -> Int {
        guard let h = projectHandle else { return -1 }
        importQueue.async { [weak self] in
            guard let self = self else { return }
            let idx = _braw_project_import(h, path)
            DispatchQueue.main.async {
                let count = Int(_braw_project_get_clip_count(h))
                self.clipCount = count
                let finalIdx = Int(idx)
                if finalIdx >= 0 {
                    if self.selectedIndex < 0 { self.selectedIndex = finalIdx }
                    self.selectClip(finalIdx)
                }
            }
        }
        return 0
    }
    
    func removeClip(at index: Int) {
        guard let h = projectHandle else { return }
        // Release decoder before removing
        if let clip = getClip(at: index) {
            clip.releaseDecoder()
        }
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
        
        if let prevClip = getClip(at: selectedIndex) {
            prevClip.releaseDecoder()
        }
        
        _braw_project_set_selected_index(h, Int32(index))
        selectedIndex = index
        
        if let clip = getClip(at: index) {
            clip.ensureDecoder()
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
        projectModel.isExporting = true
        progress = 0
        
        let indices = settings.selectedIndices.isEmpty
            ? Array(0..<projectModel.clipCount)
            : settings.selectedIndices.sorted()
        totalClips = indices.count
        
        guard !indices.isEmpty else { isExporting = false; return }
        
        let cIndices = indices.map { Int32($0) }
        let codec = Int32(settings.codec)
        let profile = Int32(settings.proResProfile)
        let resMode = Int32(settings.resolutionMode)
        let rate = Int32(settings.dataRateMbps)
        let outDir = settings.outputDir
        let mgrPtr = Unmanaged.passUnretained(self).toOpaque()
        let mgrVal = UInt(bitPattern: mgrPtr)
        let hVal = UInt(bitPattern: h)
        
        DispatchQueue.global(qos: .userInitiated).async { [mgrVal, hVal, cIndices, codec, profile, resMode, rate, outDir] in
            var mutableIndices = cIndices
            let projH = OpaquePointer(bitPattern: hVal)!
            let ctx = UnsafeMutableRawPointer(bitPattern: mgrVal)!
            _ = _braw_export_start(
                projH,
                &mutableIndices, Int32(mutableIndices.count),
                codec, profile, resMode, rate,
                outDir,
                { (clipIdx, totalC, frameIdx, totalF, rawCtx) in
                    guard let rawCtx = rawCtx else { return }
                    let mgr = Unmanaged<ExportManager>.fromOpaque(rawCtx).takeUnretainedValue()
                    DispatchQueue.main.async {
                        if frameIdx < 0 {
                            mgr.isExporting = false
                            mgr.projectModel.isExporting = false
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
                ctx
            )
        }
    }
    
    func cancel() {
        _braw_export_cancel()
        isExporting = false
        projectModel.isExporting = false
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
