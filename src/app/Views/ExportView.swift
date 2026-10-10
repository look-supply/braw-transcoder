import SwiftUI

struct ExportView: View {
    @ObservedObject var project: ProjectModel
    @StateObject private var exportMgr: ExportManager
    @State private var selectedCodec = 1
    @State private var selectedProResProfile = 3
    @State private var selectedResolution = 0
    @State private var selectedDataRate = 4
    @State private var outputDir = ""
    
    init(project: ProjectModel) {
        self.project = project
        _exportMgr = StateObject(wrappedValue: ExportManager(project: project))
    }
    
    let codecs = ["H.264", "H.265", "ProRes"]
    let proResProfiles = ["422 Proxy", "422 LT", "422", "422 HQ", "4444", "4444 XQ"]
    let resolutions = ["Passthrough", "4K DCI", "4K UHD", "2K DCI", "1080p HD"]
    let dataRates = ["30 Mbps", "50 Mbps", "100 Mbps", "150 Mbps", "200 Mbps", "250 Mbps", "300 Mbps", "400 Mbps", "500 Mbps", "600 Mbps"]
    let dataRateValues = [30, 50, 100, 150, 200, 250, 300, 400, 500, 600]
    
    var estimatedOutput: String {
        guard let clip = project.selectedClip, clip.nativeHeight > 0 else { return "—" }
        if selectedResolution == 0 {
            return "\(clip.nativeWidth) × \(clip.nativeHeight) (passthrough)"
        }
        let heights = [0, 2160, 2160, 1080, 1080]
        let targetH = heights[selectedResolution]
        let w = Int(round(Float(targetH) * Float(clip.nativeWidth) / Float(clip.nativeHeight)))
        let evenW = (w + 1) & ~1
        return "\(evenW) × \(targetH)"
    }
    
    var colorInfo: String {
        guard let clip = project.selectedClip else { return "—" }
        let parts = [clip.gamma, clip.gamut, "Gen \(clip.colorScienceGen)"]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.up").foregroundColor(.secondary)
                Text("Export").font(.headline).foregroundColor(.secondary)
                Spacer()
                if project.selectedClip != nil {
                    Text("Output: \(estimatedOutput)")
                        .font(.system(size: 11)).foregroundColor(.blue)
                    Text("·").foregroundColor(.secondary)
                    Text(colorInfo)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            
            Divider()
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codec").font(.system(size: 10)).foregroundColor(.secondary)
                    Picker("", selection: $selectedCodec) {
                        ForEach(0..<codecs.count, id: \.self) { i in Text(codecs[i]).tag(i) }
                    }.pickerStyle(.menu).frame(width: 100)
                    .disabled(exportMgr.isExporting)
                }
                
                if selectedCodec == 2 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Profile").font(.system(size: 10)).foregroundColor(.secondary)
                        Picker("", selection: $selectedProResProfile) {
                            ForEach(0..<proResProfiles.count, id: \.self) { i in Text(proResProfiles[i]).tag(i) }
                        }.pickerStyle(.menu).frame(width: 120)
                        .disabled(exportMgr.isExporting)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resolution").font(.system(size: 10)).foregroundColor(.secondary)
                    Picker("", selection: $selectedResolution) {
                        ForEach(0..<resolutions.count, id: \.self) { i in Text(resolutions[i]).tag(i) }
                    }.pickerStyle(.menu).frame(width: 140)
                    .disabled(exportMgr.isExporting)
                }
                
                if selectedCodec != 2 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Data Rate").font(.system(size: 10)).foregroundColor(.secondary)
                        Picker("", selection: $selectedDataRate) {
                            ForEach(0..<dataRates.count, id: \.self) { i in Text(dataRates[i]).tag(i) }
                        }.pickerStyle(.menu).frame(width: 120)
                        .disabled(exportMgr.isExporting)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output").font(.system(size: 10)).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        TextField("~/Movies", text: $outputDir)
                            .textFieldStyle(.roundedBorder).frame(width: 160).font(.system(size: 11))
                            .disabled(exportMgr.isExporting)
                        Button(action: pickOutputDir) {
                            Image(systemName: "folder")
                        }.buttonStyle(.borderless)
                        .disabled(exportMgr.isExporting)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .center, spacing: 4) {
                    Button(action: { exportActiveClip() }) {
                        Label("Export Selected", systemImage: "arrow.right.circle.fill").frame(width: 130)
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(project.clipCount == 0 || project.isImporting || exportMgr.isExporting)
                    
                    Button(action: { exportAllClips() }) {
                        Label("Export All", systemImage: "arrow.right.circle").frame(width: 130)
                    }.buttonStyle(.bordered).controlSize(.small)
                        .disabled(project.clipCount == 0 || project.isImporting || exportMgr.isExporting)
                }
            }
            .padding(12)
            
            if let status = exportMgr.statusMessage {
                Text(status).font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if exportMgr.isExporting {
                VStack(spacing: 4) {
                    ProgressView(value: exportMgr.progress, total: 1.0)
                        .progressViewStyle(.linear).padding(.horizontal, 12)
                    HStack {
                        Text("Clip \(exportMgr.clipIndex + 1)/\(exportMgr.totalClips)")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary)
                        Text("Frame \(exportMgr.currentFrame)/\(exportMgr.totalFrames)")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(exportMgr.progress * 100))%")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        Button(exportMgr.isCancelling ? "Cancelling…" : "Cancel") { exportMgr.cancel() }
                            .disabled(exportMgr.isCancelling)
                            .buttonStyle(.borderless).font(.system(size: 10))
                    }.padding(.horizontal, 16).padding(.bottom, 6)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    
    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Select"
        if panel.runModal() == .OK { outputDir = panel.url?.path ?? "" }
    }
    
    func startExport(selectedOnly: Bool) {
        var settings = ExportUISettings()
        settings.codec = selectedCodec
        settings.proResProfile = selectedProResProfile
        settings.resolutionMode = selectedResolution
        settings.dataRateMbps = dataRateValues[selectedDataRate]
        settings.outputDir = outputDir
        settings.selectedIndices = selectedOnly ? [project.selectedIndex] : []
        exportMgr.export(settings: settings)
    }
    
    func exportActiveClip() { startExport(selectedOnly: true) }
    func exportAllClips() { startExport(selectedOnly: false) }
}
