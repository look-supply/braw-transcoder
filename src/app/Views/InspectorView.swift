import SwiftUI

enum InspectorPanel: CaseIterable { case raw, anamorphic, tone, lens }

private struct CustomDesqueezeField: View {
    @ObservedObject var clip: ClipModel
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var isEditing: Bool

    private func syncDraft() {
        draft = clip.customDesqueeze.formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
    }
    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let ratio = Float(text), ratio.isFinite, (1...4).contains(ratio) else {
            invalid = true
            return
        }
        invalid = false
        if ratio != clip.customDesqueeze { clip.customDesqueeze = ratio }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ResettableSettingLabel(title: "Custom ratio") {
                clip.customDesqueeze = 2
                syncDraft()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                // Keep partial input such as "1." local until editing finishes.
                // Updating decode settings per keystroke can redraw the field.
                TextField("e.g. 1.33", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isEditing)
                    .onSubmit { commit() }
                    .accessibilityLabel("Custom desqueeze ratio")
                    .help("Enter a desqueeze ratio from 1 to 4, such as 1.33 or 1.5.")
                Text(":1").foregroundStyle(.secondary)
            }
            if invalid {
                Text("Enter a ratio from 1 to 4.").font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { syncDraft() }
        .onChange(of: draft) { _, _ in invalid = false }
        .onChange(of: isEditing) { _, editing in if !editing { commit() } }
        .onChange(of: clip.customDesqueeze) { _, _ in if !isEditing { syncDraft() } }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    let summary: String
    var showsDivider = true
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        // Match the 16pt spacing before the next section across the divider.
        VStack(spacing: 16) {
            DisclosureGroup(isExpanded: $isExpanded) {
                content().padding(.top, 8)
            } label: {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack {
                        Text(title).font(.headline)
                        Spacer(minLength: 8)
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }
            if showsDivider { Divider() }
        }
    }
}

struct InspectorView: View {
    @ObservedObject var project: ProjectModel
    @State private var expandedPanels: Set<InspectorPanel> = [.raw]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundColor(.secondary)
                Text("Inspector").font(.headline).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: PanelLayout.headerHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
            if let clip = project.selectedClip {
                InspectorContent(clip: clip, project: project, expandedPanels: $expandedPanels)
                    .frame(minHeight: 0, maxHeight: .infinity)
                Divider()
                InspectorFooter(clip: clip, project: project)
                    .fixedSize(horizontal: false, vertical: true)
                if project.waveformVisible {
                    Divider()
                    RGBWaveformView(clip: clip) { project.waveformVisible = false }
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No clip selected").font(.callout).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InspectorContent: View {
    @ObservedObject var clip: ClipModel
    @ObservedObject var project: ProjectModel
    @Binding var expandedPanels: Set<InspectorPanel>
    var isExporting: Bool { project.isExporting }
    
    private let anamorphicLabels = ["As shot", "Off", "1.33×", "1.5×", "1.6×", "1.66×", "1.8×", "2×", "Custom"]
    private let toneLabels = ["Contrast", "Saturation", "Midpoint", "Highlight rolloff", "Shadow rolloff", "Black level", "White level"]
    private var rawSummary: String {
        clip.iso == clip.nativeISO && clip.colorTemp == clip.nativeColorTemp && clip.tint == clip.nativeTint &&
            clip.exposure == 0 && !clip.highlightRecovery && !clip.gamutCompression ? "As shot" : "Adjusted"
    }
    private var lensSummary: String {
        clip.lensCorrections == 0 ? "Off" : "\(clip.lensCorrections.nonzeroBitCount) enabled"
    }
    private func expansion(_ panel: InspectorPanel) -> Binding<Bool> {
        Binding(get: { expandedPanels.contains(panel) }, set: { expanded in
            if expanded { expandedPanels.insert(panel) } else { expandedPanels.remove(panel) }
        })
    }
    private func switchRow(_ title: String, isOn: Binding<Bool>, initialValue: Bool = false) -> some View {
        HStack {
            ResettableSettingLabel(title: title) { isOn.wrappedValue = initialValue }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(title)
        }
    }
    private var geometryButtons: some View {
        GroupBox {
            HStack(spacing: 10) {
                Button { clip.rotation = (clip.rotation + 1) % 4 } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate 90° clockwise").accessibilityLabel("Rotate clockwise")
                Toggle(isOn: $clip.flipHorizontal) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }.toggleStyle(.button).help("Flip horizontally").accessibilityLabel("Flip horizontally")
                Toggle(isOn: $clip.flipVertical) {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }.toggleStyle(.button).help("Flip vertically").accessibilityLabel("Flip vertically")
                Spacer(minLength: 4)
                Text("\(clip.rotation * 90)°").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(isExporting)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                geometryButtons
                InspectorSection(title: "RAW adjustments", summary: rawSummary, isExpanded: expansion(.raw)) {
                    VStack(alignment: .leading, spacing: 12) {
                        // ── ISO Preset Dropdown ──────────────
                        VStack(alignment: .leading, spacing: 4) {
                            ResettableSettingLabel(title: "ISO") { clip.applyISOPreset(0) }
                                .font(.system(size: 11, weight: .medium))
                                .disabled(isExporting || clip.isoReadOnly)
                            FullWidthDropdown(title: "ISO", options:
                                [.init(title: "\(clip.nativeISO) (As Shot)", value: 0)] +
                                clip.isoPresets.enumerated().map { .init(title: "\($0.element)", value: $0.offset + 1) },
                                selection: Binding<Int>(
                                get: { clip.isoPresetIndex },
                                set: { clip.applyISOPreset($0) }
                            ))
                            .frame(maxWidth: .infinity)
                            .disabled(isExporting || clip.isoReadOnly)
                            .help("ISO cannot switch the sensor gain used during recording. Use Exposure for brightness changes outside this range.")
                            
                            if let notice = clip.isoAdjustmentNotice {
                                Text(notice).font(.caption).foregroundColor(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        
                        // ── Color Temp Preset Dropdown ───────
                        VStack(alignment: .leading, spacing: 4) {
                            ResettableSettingLabel(title: "White Balance") { clip.applyColorPreset(0) }
                                .font(.system(size: 11, weight: .medium))
                                .disabled(isExporting)
                            FullWidthDropdown(title: "White Balance", options:
                                ClipModel.colorPresetLabels.enumerated().map { .init(title: $0.element, value: $0.offset) },
                                selection: Binding<Int>(
                                get: { clip.colorPresetIndex },
                                set: { clip.applyColorPreset($0) }
                            ))
                            .frame(maxWidth: .infinity)
                            .disabled(isExporting)
                            
                            let isAsShot = clip.colorPresetIndex == 0
                            let isCustomWB = clip.colorPresetIndex == ClipModel.colorPresetLabels.count - 1
                            
                            if isAsShot || isCustomWB {
                                VStack(alignment: .leading, spacing: 12) {
                                    NumericSlider(title: "Temp", value: Binding(
                                        get: { Double(clip.colorTemp) },
                                        set: { clip.colorTemp = UInt32($0) }
                                    ), range: 2000...50000, initialValue: Double(clip.nativeColorTemp),
                                      step: 1, scrubStep: 10, precision: 0, suffix: "K")
                                        .id("\(clip.id)-temperature")
                                    NumericSlider(title: "Tint", value: Binding(
                                        get: { Double(clip.tint) },
                                        set: { clip.tint = Int16($0) }
                                    ), range: -50...50, initialValue: Double(clip.nativeTint),
                                      step: 1, scrubStep: 0.2, precision: 0)
                                        .id("\(clip.id)-tint")
                                }
                                .padding(.top, 8)
                                .disabled(isExporting)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        
                        // ── Exposure ─────────────────────────
                        NumericSlider(title: "Exposure", value: Binding(
                            get: { Double(clip.exposure) },
                            set: { clip.exposure = Float($0) }
                        ), range: -5...5, initialValue: 0, step: 0.01, scrubStep: 0.01, precision: 2)
                        .id("\(clip.id)-exposure")
                        .disabled(isExporting)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            switchRow("Highlight recovery", isOn: $clip.highlightRecovery)
                                .help("Reconstruct clipped highlights. Compare with it off to judge whether recovery improves this shot.")
                            switchRow("Gamut compression", isOn: $clip.gamutCompression)
                                .help("Apply Blackmagic RAW gamut compression before rendering previews and exports. The source BRAW is unchanged.")
                        }
                        .toggleStyle(.switch)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(isExporting)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity)

                InspectorSection(title: "Anamorphic", summary: anamorphicLabels[clip.anamorphicMode], isExpanded: expansion(.anamorphic)) {
                    VStack(alignment: .leading, spacing: 4) {
                        ResettableSettingLabel(title: "Desqueeze") { clip.anamorphicMode = 0 }
                            .font(.system(size: 11, weight: .medium))
                            .disabled(isExporting)
                        FullWidthDropdown(title: "Desqueeze", options:
                            anamorphicLabels.enumerated().map { .init(title: $0.element, value: $0.offset) },
                            selection: $clip.anamorphicMode)
                        .frame(maxWidth: .infinity)
                        .disabled(isExporting)
                    }
                    if clip.anamorphicMode == 8 {
                        CustomDesqueezeField(clip: clip)
                            .id(clip.id)
                            .disabled(isExporting)
                    }
                }
                InspectorSection(title: "Tone curve", summary: clip.toneCurveEnabled ? "Custom" : "Off", isExpanded: expansion(.tone)) {
                    switchRow("Custom tone curve", isOn: $clip.toneCurveEnabled)
                        .toggleStyle(.switch)
                        .disabled(isExporting || !clip.toneCurveSupported)
                    if clip.toneCurveSupported {
                        VStack(spacing: 12) {
                            ForEach(0..<toneLabels.count, id: \.self) { index in
                                NumericSlider(title: toneLabels[index], value: Binding(
                                    get: { Double(clip.toneValues[index]) },
                                    set: { clip.toneValues[index] = Float($0) }
                                ), range: Double(clip.toneRanges[index].minimum)...Double(clip.toneRanges[index].maximum),
                                  initialValue: Double(clip.toneDefaults[index]), step: 0.001, scrubStep: 0.005, precision: 3)
                                    .id("\(clip.id)-tone-\(index)")
                            }
                            switchRow("Video black level", isOn: $clip.videoBlack, initialValue: clip.defaultVideoBlack)
                                .toggleStyle(.switch).disabled(!clip.videoBlackSupported)
                            Button("Reset Tone Curve") {
                                clip.toneValues = clip.toneDefaults
                                clip.videoBlack = clip.defaultVideoBlack
                            }.controlSize(.small)
                        }
                        .disabled(isExporting || !clip.toneCurveEnabled)
                    }
                }
                InspectorSection(title: "Lens correction", summary: lensSummary, showsDivider: false, isExpanded: expansion(.lens)) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<3) { index in
                            let flag = UInt32(1) << index
                            let supported = clip.lensCorrectionSupport & flag != 0
                            switchRow(["Distortion correction", "Shading correction", "Chromatic aberration"][index],
                                   isOn: Binding(
                                    get: { clip.lensCorrections & flag != 0 },
                                    set: { enabled in
                                        clip.lensCorrections = enabled ? clip.lensCorrections | flag : clip.lensCorrections & ~flag
                                    }
                                   ))
                                .disabled(isExporting || !supported)
                                .help(supported ? "Apply the source clip’s lens correction during decoding and export." : "The source clip does not provide an adjustable correction for this setting.")
                        }
                    }
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(12)
        }
    }
}

struct InspectorFooter: View {
    @ObservedObject var clip: ClipModel
    @ObservedObject var project: ProjectModel

    var body: some View {
        VStack(spacing: 12) {
            Button { project.applyClipSettingsToAll(from: project.selectedIndex) } label: {
                Label("Apply to All Clips", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            Button { clip.resetAdjustments() } label: {
                Label("Reset Adjustments", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }

        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(project.isExporting)
        .padding(12)
    }
}
