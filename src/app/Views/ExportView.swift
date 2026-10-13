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

    init(project: ProjectModel, manager: ExportManager? = nil) {
        self.project = project
        _exportMgr = StateObject(wrappedValue: manager ?? ExportManager(project: project))
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

    var effectiveResolution: Int { availableResolutionModes.contains(selectedResolution) ? selectedResolution : 0 }

    var estimatedOutput: String {
        guard let clip = project.selectedClip, clip.renderDimensions.height > 0 else { return "—" }
        var width: Int32 = 0, height: Int32 = 0
        guard braw_export_dimensions(Int32(effectiveResolution), clip.renderDimensions.width,
                                     clip.renderDimensions.height, &width, &height) != 0 else { return "—" }
        let original = width == clip.renderDimensions.width && height == clip.renderDimensions.height
        return "\(width) × \(height)" + (original ? " (original)" : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Export")
                        .font(.headline).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !exportMgr.isExporting, project.selectedClip != nil {
                        Text("Output: \(estimatedOutput)")
                            .font(.system(size: 11)).foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if exportMgr.isExporting {
                ExportProgressView(manager: exportMgr).padding(12)
            } else {
                ExportControlsLayout {
                    ExportField(title: "Codec") {
                        FullWidthDropdown(title: "Codec", options: codecs.enumerated().map {
                            .init(title: $0.element, value: $0.offset)
                        }, selection: $selectedCodec)
                    }.layoutValue(key: ExportFieldWidth.self, value: 112)

                    ExportField(title: "Resolution") {
                        FullWidthDropdown(title: "Resolution", options: resolutions
                            .filter { availableResolutionModes.contains($0.mode) }
                            .map { .init(title: $0.label, value: $0.mode) }, selection: resolutionSelection)
                            .help("Preserves aspect ratio and only downsamples. Smaller clips in a batch retain their original resolution.")
                    }.layoutValue(key: ExportFieldWidth.self, value: 208)

                    ExportField(title: selectedCodec == 2 ? "Profile" : "Data Rate") {
                        if selectedCodec == 2 {
                            FullWidthDropdown(title: "Profile", options: proResProfiles.enumerated().map {
                                .init(title: $0.element, value: $0.offset)
                            }, selection: $selectedProResProfile)
                        } else {
                            FullWidthDropdown(title: "Data Rate", options: dataRates.enumerated().map {
                                .init(title: $0.element, value: $0.offset)
                            }, selection: $selectedDataRate)
                        }
                    }.layoutValue(key: ExportFieldWidth.self, value: 124)

                    ExportField(title: "Output") {
                        HStack(spacing: 8) {
                            Text("Same as source").font(.system(size: 11)).fixedSize()
                            Toggle("Same as source", isOn: $useSourceDirectory)
                                .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                                .accessibilityLabel("Same as source")
                            if useSourceDirectory {
                                Spacer(minLength: 0)
                            } else {
                                TextField("Choose output folder", text: $outputDir)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                                    .lineLimit(1)
                                    .accessibilityLabel("Output folder")
                                Button(action: pickOutputDir) { Image(systemName: "folder") }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .fixedSize()
                                    .accessibilityLabel("Choose output folder")
                            }
                        }.frame(minHeight: 22)
                    }.layoutValue(key: ExportFieldWidth.self, value: useSourceDirectory ? 208 : 310)

                    VStack(spacing: 4) {
                        Text("Export actions").font(.system(size: 11, weight: .medium)).hidden()
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { exportSelectedButton; exportAllButton }
                            VStack(spacing: 6) { exportSelectedButton; exportAllButton }
                        }
                    }.layoutValue(key: ExportFieldWidth.self, value: 156)
                }
                .padding(12)
                if let status = exportMgr.statusMessage {
                    Text(status).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onChange(of: availableResolutionModes, initial: true) { _, modes in
            if !modes.contains(selectedResolution) { selectedResolution = 0 }
        }
    }

    private var exportSelectedButton: some View {
        Button(action: exportSelectedClips) {
            Label("Export Selected", systemImage: "arrow.right.circle.fill")
                .font(.system(size: 11)).lineLimit(1).frame(minWidth: 136, maxWidth: .infinity)
        }.buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(project.selectedIndices.isEmpty || project.isImporting)
    }
    private var exportAllButton: some View {
        Button(action: exportAllClips) {
            Label("Export All", systemImage: "arrow.right.circle")
                .font(.system(size: 11)).lineLimit(1).frame(minWidth: 136, maxWidth: .infinity)
        }.buttonStyle(.bordered).controlSize(.small)
            .disabled(project.clipCount == 0 || project.isImporting)
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

private struct ExportField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExportProgressView: View {
    @ObservedObject var manager: ExportManager
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(manager.currentClipName.isEmpty ? "Preparing export…" : manager.currentClipName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(Int(max(0, min(1, manager.progress)) * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                }
                ProgressView(value: manager.progress, total: 1).progressViewStyle(.linear)
                HStack(spacing: 8) {
                    Text("Clip \(manager.clipIndex + 1) of \(max(1, manager.totalClips))")
                    if manager.totalFrames > 0 {
                        Text("·")
                        Text("Frame \(manager.currentFrame) of \(manager.totalFrames)")
                    }
                }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            Button(manager.isCancelling ? "Cancelling…" : "Cancel") { manager.cancel() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(manager.isCancelling)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancel-export")
        }
    }
}
