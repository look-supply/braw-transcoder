import SwiftUI

struct ExportView: View {
    @ObservedObject var project: ProjectModel
    @StateObject private var exportMgr: ExportManager
    @State private var showingSettings = false
    @AppStorage("exportLastCodec") private var selectedCodec = 1
    @AppStorage("exportLastProResProfile") private var selectedProResProfile = 3
    @AppStorage("exportLastResolution") private var selectedResolution = 0
    @AppStorage("exportLastDataRate") private var selectedDataRate = 4
    @AppStorage("exportLastGOPMode") private var selectedGOPMode = 0
    @AppStorage("exportLastChroma") private var selectedChroma = 1
    @AppStorage("exportLastPreset") private var selectedPreset = 0
    @State private var presetName = ""
    @State private var showingSavePreset = false
    @AppStorage("exportPresetsJSON") private var savedPresetsJSON = "[]"
    @AppStorage("exportOutputDirectory") private var outputDir = Self.defaultOutputDirectory
    @AppStorage("exportUseSourceDirectory") private var useSourceDirectory = true

    private static var defaultOutputDirectory: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    }

    private var resolvedOutputDirectory: String {
        let path = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? Self.defaultOutputDirectory : path
    }

    init(project: ProjectModel, manager: ExportManager? = nil) {
        self.project = project
        _exportMgr = StateObject(wrappedValue: manager ?? ExportManager(project: project))
    }

    let codecs = ["H.264 (8 bit)", "H.265 (10 bit)", "ProRes (10 bit)"]
    let gopModes = ["Long GOP", "All Intra"]
    let chromaModes = ["4:2:0", "4:2:2"]
    let proResProfiles = ["422 Proxy", "422 LT", "422", "422 HQ", "4444", "4444 XQ"]
    let resolutions: [(mode: Int, label: String)] = [
        (0, "Original resolution"), (5, "4320 pixels high (8K)"),
        (6, "3240 pixels high (6K)"), (1, "2160 pixels high (4K)"), (3, "1080 pixels high (2K)")
    ]
    let dataRates = ["30 Mbps", "50 Mbps", "100 Mbps", "150 Mbps", "200 Mbps", "250 Mbps", "300 Mbps", "400 Mbps", "500 Mbps", "600 Mbps", "800 Mbps"]
    let dataRateValues = [30, 50, 100, 150, 200, 250, 300, 400, 500, 600, 800]

    var availableResolutionModes: [Int] {
        guard let clip = project.selectedClip else { return resolutions.map(\.mode) }
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
            Text("Export")
                .font(.headline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if exportMgr.isExporting {
                ExportProgressView(manager: exportMgr).padding(12)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        formatSummary
                        Spacer(minLength: 0)
                        settingsButton
                        exportAllButton
                        exportSelectedButton
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            formatSummary
                            Spacer(minLength: 0)
                            settingsButton
                        }
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            exportAllButton
                            exportSelectedButton
                        }
                    }
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
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .onChange(of: useSourceDirectory, initial: true) { _, sameAsSource in
            if !sameAsSource && outputDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outputDir = Self.defaultOutputDirectory
            }
        }
    }

    private var selectedFormat: String {
        selectedCodec == 2
            ? "ProRes \(proResProfiles[selectedProResProfile]) (10 bit)"
            : codecs[selectedCodec]
    }

    private var settingsSummaryAttributes: [String] {
        let outputFolder = useSourceDirectory ? "Same as source" : resolvedOutputDirectory
        let dimensions = project.selectedClip == nil
            ? (resolutions.first { $0.mode == effectiveResolution }?.label ?? "Original resolution")
            : estimatedOutput
        if selectedCodec == 2 {
            return [selectedFormat, dimensions, outputFolder]
        }
        let chroma = chromaModes[selectedChroma]
        var attributes = [selectedFormat]
        if selectedCodec == 1 { attributes.append(gopModes[selectedGOPMode]) }
        attributes += [chroma, dataRates[selectedDataRate], dimensions, outputFolder]
        return attributes
    }

    private var settingsSummary: String {
        let settings = settingsSummaryAttributes.joined(separator: ", ")
        let presetIndex = presetSelection.wrappedValue
        guard presetIndex > 0 else { return settings }
        return "\(savedPresets[presetIndex - 1].name): \(settings)"
    }

    private var formatSummary: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                let presetIndex = presetSelection.wrappedValue
                if presetIndex > 0 {
                    Text(savedPresets[presetIndex - 1].name)
                        .font(.system(size: 11, weight: .medium))
                }
                ForEach(Array(settingsSummaryAttributes.enumerated()), id: \.offset) { _, attribute in
                    MetadataBadge(name: attribute, fontSize: 11)
                        .fixedSize()
                }
            }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(settingsSummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Export settings: \(settingsSummary)")
        .accessibilityIdentifier("export-format-summary")
    }

    private var settingsButton: some View {
        Button("Export Settings…") { showingSettings = true }
            .buttonStyle(.bordered).controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("export-settings")
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Export Settings").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 16) {
                ExportField(title: "Saved preset") {
                    HStack(spacing: 8) {
                        if savedPresets.isEmpty {
                            Text("No saved presets").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            FullWidthDropdown(title: "Saved preset", options: [
                                .init(title: "Choose preset…", value: 0)
                            ] + savedPresets.enumerated().map {
                                .init(title: $0.element.name, value: $0.offset + 1)
                            }, selection: presetSelection)
                        }
                        Button("Save Preset…") {
                            presetName = ""
                            showingSavePreset = true
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                    }
                }

                ExportField(title: "Format") {
                    FullWidthDropdown(title: "Format", options: codecs.enumerated().map {
                        .init(title: $0.element, value: $0.offset)
                    }, selection: $selectedCodec)
                }

                if selectedCodec == 1 {
                    ExportField(title: "Compression") {
                        FullWidthDropdown(title: "Compression", options: gopModes.enumerated().map {
                            .init(title: $0.element, value: $0.offset)
                        }, selection: gopModeSelection)
                    }
                }

                if selectedCodec < 2 {
                    ExportField(title: "Chroma subsampling") {
                        FullWidthDropdown(title: "Chroma subsampling", options: chromaModes.enumerated().map {
                            .init(title: $0.element, value: $0.offset)
                        }, selection: $selectedChroma)
                    }
                }

                ExportField(title: "Resolution") {
                    FullWidthDropdown(title: "Resolution", options: resolutions
                        .filter { availableResolutionModes.contains($0.mode) }
                        .map { .init(title: $0.label, value: $0.mode) }, selection: resolutionSelection)
                        .help("Preserves aspect ratio and only downsamples. Smaller clips in a batch retain their original resolution.")
                    if project.selectedClip != nil {
                        Text("Output: \(estimatedOutput)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

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
                }

                ExportField(title: "Output folder") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Same as source", isOn: $useSourceDirectory)
                            .toggleStyle(.switch).controlSize(.small)
                        if !useSourceDirectory {
                            HStack(spacing: 8) {
                                TextField("Choose output folder", text: $outputDir)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Output folder")
                                Button(action: pickOutputDir) { Image(systemName: "folder") }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel("Choose output folder")
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { showingSettings = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("export-settings-done")
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { showingSettings = false }
        .alert("Save Export Preset", isPresented: $showingSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { savePreset() }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Save the current format, compression, resolution, and quality settings.")
        }
    }

    private var exportSelectedButton: some View {
        Button(action: exportSelectedClips) {
            Label("Export Selected", systemImage: "arrow.right.circle.fill")
                .font(.system(size: 11)).lineLimit(1).fixedSize()
        }.buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(project.selectedIndices.isEmpty || project.isImporting)
    }
    private var exportAllButton: some View {
        Button(action: exportAllClips) {
            Label("Export All", systemImage: "arrow.right.circle")
                .font(.system(size: 11)).lineLimit(1).fixedSize()
        }.buttonStyle(.bordered).controlSize(.small)
            .disabled(project.clipCount == 0 || project.isImporting)
    }

    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: (resolvedOutputDirectory as NSString).expandingTildeInPath)
        if panel.runModal() == .OK { outputDir = panel.url?.path ?? "" }
    }

    func startExport(selectedOnly: Bool) {
        if selectedOnly && project.selectedIndices.isEmpty { return }
        var settings = ExportUISettings()
        settings.codec = selectedCodec
        settings.proResProfile = selectedProResProfile
        settings.resolutionMode = availableResolutionModes.contains(selectedResolution) ? selectedResolution : 0
        settings.dataRateMbps = dataRateValues[selectedDataRate]
        settings.gopMode = selectedGOPMode
        settings.chromaMode = selectedChroma
        settings.outputDir = useSourceDirectory ? "" : resolvedOutputDirectory
        settings.selectedIndices = selectedOnly ? project.selectedIndices.sorted() : []
        exportMgr.export(settings: settings)
    }

    private var savedPresets: [ExportPreset] {
        guard let data = savedPresetsJSON.data(using: .utf8),
              let presets = try? JSONDecoder().decode([ExportPreset].self, from: data) else { return [] }
        return presets
    }

    private var gopModeSelection: Binding<Int> {
        Binding(get: { selectedGOPMode }, set: { mode in
            selectedGOPMode = mode
            selectedDataRate = mode == 1 ? 9 : 4
            if mode == 0 { selectedChroma = 1 }
        })
    }

    private var presetSelection: Binding<Int> {
        Binding(get: {
            guard selectedPreset > 0, savedPresets.indices.contains(selectedPreset - 1),
                  savedPresets[selectedPreset - 1].matches(codec: selectedCodec,
                    profile: selectedProResProfile, resolution: selectedResolution,
                    dataRate: selectedDataRate, gopMode: selectedGOPMode, chroma: selectedChroma) else { return 0 }
            return selectedPreset
        }, set: { value in
            guard value > 0, savedPresets.indices.contains(value - 1) else { selectedPreset = 0; return }
            apply(savedPresets[value - 1])
            selectedPreset = value
        })
    }

    private func apply(_ preset: ExportPreset) {
        selectedCodec = preset.codec
        selectedProResProfile = preset.proResProfile
        selectedResolution = preset.resolution
        selectedDataRate = preset.dataRate
        selectedGOPMode = preset.gopMode
        selectedChroma = preset.chroma
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var presets = savedPresets
        let preset = ExportPreset(name: name, codec: selectedCodec,
            proResProfile: selectedProResProfile, resolution: selectedResolution,
            dataRate: selectedDataRate, gopMode: selectedGOPMode, chroma: selectedChroma)
        if let index = presets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            presets[index] = preset
            selectedPreset = index + 1
        } else {
            presets.append(preset)
            selectedPreset = presets.count
        }
        if let data = try? JSONEncoder().encode(presets), let json = String(data: data, encoding: .utf8) {
            savedPresetsJSON = json
        }
    }

    func exportSelectedClips() { startExport(selectedOnly: true) }
    func exportAllClips() { startExport(selectedOnly: false) }
}

private struct ExportPreset: Codable {
    var name: String
    var codec: Int
    var proResProfile: Int
    var resolution: Int
    var dataRate: Int
    var gopMode: Int
    var chroma: Int

    func matches(codec: Int, profile: Int, resolution: Int, dataRate: Int, gopMode: Int, chroma: Int) -> Bool {
        self.codec == codec && proResProfile == profile && self.resolution == resolution
            && self.dataRate == dataRate && self.gopMode == gopMode && self.chroma == chroma
    }
}

private struct ExportField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
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
