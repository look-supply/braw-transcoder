import SwiftUI

struct ExportView: View {
    @ObservedObject var project: ProjectModel
    @StateObject private var exportMgr: ExportManager
    @State private var selectedCodec = 1
    @State private var selectedProResProfile = 3
    @State private var selectedResolution = 0
    @State private var selectedDataRate = 4
    @AppStorage("exportOutputDirectory") private var outputDir = ""
    @AppStorage("exportUseSourceDirectory") private var useSourceDirectory = true

    init(project: ProjectModel) {
        self.project = project
        _exportMgr = StateObject(wrappedValue: ExportManager(project: project))
    }

    let codecs = ["H.264", "H.265", "ProRes"]
    let proResProfiles = ["422 Proxy", "422 LT", "422", "422 HQ", "4444", "4444 XQ"]
    let resolutions: [(mode: Int, label: String)] = [
        (0, "Original resolution"), (5, "4320 pixels high (8K)"),
        (6, "3240 pixels high (6K)"), (1, "2160 pixels high (4K)"), (3, "1080 pixels high (2K)")
    ]
    let dataRates = ["30 Mbps", "50 Mbps", "100 Mbps", "150 Mbps", "200 Mbps", "250 Mbps", "300 Mbps", "400 Mbps", "500 Mbps", "600 Mbps"]
    let dataRateValues = [30, 50, 100, 150, 200, 250, 300, 400, 500, 600]

    var availableResolutionModes: [Int] {
        guard let clip = project.selectedClip else { return [0] }
        return resolutions.compactMap { option in
            if option.mode == 0 { return 0 }
            var width: Int32 = 0, height: Int32 = 0
            let downsamples = braw_export_dimensions(Int32(option.mode), clip.renderDimensions.width,
                                                     clip.renderDimensions.height, &width, &height) != 0
                && height < clip.renderDimensions.height
            return downsamples ? option.mode : nil
        }
    }

    var resolutionSelection: Binding<Int> {
        Binding(
            get: { availableResolutionModes.contains(selectedResolution) ? selectedResolution : 0 },
            set: { selectedResolution = availableResolutionModes.contains($0) ? $0 : 0 }
        )
    }

    var estimatedOutput: String {
        guard let clip = project.selectedClip, clip.renderDimensions.height > 0 else { return "—" }
        var width: Int32 = 0, height: Int32 = 0
        guard braw_export_dimensions(Int32(selectedResolution), clip.renderDimensions.width,
                                     clip.renderDimensions.height, &width, &height) != 0 else { return "—" }
        let original = width == clip.renderDimensions.width && height == clip.renderDimensions.height
        return "\(width) × \(height)" + (original ? " (original)" : "")
    }

    var colorInfo: String {
        guard let clip = project.selectedClip else { return "—" }
        let parts = [clip.renderedGamma, clip.gamut, "Gen \(clip.colorScienceGen)"]
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    encodingControls
                    Spacer(minLength: 16)
                    outputControls
                    Spacer(minLength: 16)
                    exportButtons
                }
                VStack(alignment: .leading, spacing: 12) {
                    encodingControls
                    HStack(spacing: 16) {
                        outputControls
                        Spacer(minLength: 16)
                        exportButtons
                    }
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

    private var encodingControls: some View {
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
                    Picker("", selection: resolutionSelection) {
                        ForEach(resolutions.filter { availableResolutionModes.contains($0.mode) }, id: \.mode) { option in
                            Text(option.label).tag(option.mode)
                        }
                    }.pickerStyle(.menu).frame(width: 180)
                    .help("Preserves aspect ratio. Only presets that downsample the previewed clip are available. In mixed batches, smaller clips keep their original resolution.")
                    .onChange(of: availableResolutionModes, initial: true) { _, modes in
                        if !modes.contains(selectedResolution) { selectedResolution = 0 }
                    }
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
        }
    }
    private var outputControls: some View {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output").font(.system(size: 10)).foregroundColor(.secondary).fixedSize()
                    Toggle("Same folder as BRAW", isOn: $useSourceDirectory)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 11)).fixedSize()
                        .help("Save each MOV beside its original BRAW file.")
                        .disabled(exportMgr.isExporting)
                    if !useSourceDirectory {
                        HStack(spacing: 4) {
                            TextField("Same folder as BRAW", text: $outputDir)
                                .textFieldStyle(.roundedBorder).frame(width: 160).font(.system(size: 11))
                                .disabled(exportMgr.isExporting)
                            Button(action: pickOutputDir) {
                                Image(systemName: "folder")
                            }.buttonStyle(.borderless)
                            .disabled(exportMgr.isExporting)
                        }
                    }
                }
    }
    private var exportButtons: some View {
                VStack(alignment: .center, spacing: 4) {
                    Button(action: { exportSelectedClips() }) {
                        Label("Export Selected", systemImage: "arrow.right.circle.fill").frame(width: 130)
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(project.selectedIndices.isEmpty || project.isImporting || exportMgr.isExporting)

                    Button(action: { exportAllClips() }) {
                        Label("Export All", systemImage: "arrow.right.circle").frame(width: 130)
                    }.buttonStyle(.bordered).controlSize(.small)
                        .disabled(project.clipCount == 0 || project.isImporting || exportMgr.isExporting)
                }
    }

    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Select"
        if !outputDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK { outputDir = panel.url?.path ?? "" }
    }

    func startExport(selectedOnly: Bool) {
        if selectedOnly && project.selectedIndices.isEmpty { return }
        var settings = ExportUISettings()
        settings.codec = selectedCodec
        settings.proResProfile = selectedProResProfile
        settings.resolutionMode = availableResolutionModes.contains(selectedResolution) ? selectedResolution : 0
        settings.dataRateMbps = dataRateValues[selectedDataRate]
        settings.outputDir = useSourceDirectory ? "" : outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.selectedIndices = selectedOnly ? project.selectedIndices.sorted() : []
        exportMgr.export(settings: settings)
    }

    func exportSelectedClips() { startExport(selectedOnly: true) }
    func exportAllClips() { startExport(selectedOnly: false) }
}
