import SwiftUI

struct InspectorView: View {
    @ObservedObject var project: ProjectModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundColor(.secondary)
                Text("Inspector").font(.headline).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: PanelLayout.headerHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
            if let clip = project.selectedClip {
                InspectorContent(clip: clip, project: project)
                Divider()
                RGBWaveformView(clip: clip)
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
    var isExporting: Bool { project.isExporting }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Text("RAW Adjustments").font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        // ── ISO Preset Dropdown ──────────────
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ISO").font(.system(size: 10)).foregroundColor(.secondary)
                            Picker(selection: Binding<Int>(
                                get: { clip.isoPresetIndex },
                                set: { clip.applyISOPreset($0) }
                            )) {
                                Text("\(clip.nativeISO) (As Shot)").tag(0)
                                ForEach(0..<clip.isoPresets.count, id: \.self) { i in
                                    Text("\(clip.isoPresets[i])").tag(i + 1)
                                }
                            } label: { EmptyView() }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)
                            .disabled(isExporting || clip.isoReadOnly)
                            .help("ISO cannot switch the sensor gain used during recording. Use Exposure for brightness changes outside this range.")
                            
                            Text(clip.isoReadOnly ? "ISO is fixed for this recording." : "Available ISO values follow the recorded sensor gain.")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                            if let notice = clip.isoAdjustmentNotice {
                                Text(notice).font(.caption).foregroundColor(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        
                        // ── Color Temp Preset Dropdown ───────
                        VStack(alignment: .leading, spacing: 4) {
                            Text("White Balance").font(.system(size: 10)).foregroundColor(.secondary)
                            Picker(selection: Binding<Int>(
                                get: { clip.colorPresetIndex },
                                set: { clip.applyColorPreset($0) }
                            )) {
                                ForEach(0..<ClipModel.colorPresetLabels.count, id: \.self) { i in
                                    Text(ClipModel.colorPresetLabels[i]).tag(i)
                                }
                            } label: { EmptyView() }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)
                            .disabled(isExporting)
                            
                            let isAsShot = clip.colorPresetIndex == 0
                            let isCustomWB = clip.colorPresetIndex == ClipModel.colorPresetLabels.count - 1
                            
                            if isAsShot || isCustomWB {
                                VStack(spacing: 4) {
                                    HStack {
                                        Text("Temp").font(.system(size: 10)).foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(clip.colorTemp)K")
                                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                    }
                                    Slider(value: Binding<Double>(
                                        get: { Double(clip.colorTemp) },
                                        set: { clip.colorTemp = UInt32($0) }
                                    ), in: 2000...50000).controlSize(.small)
                                    .disabled(isExporting)
                                    
                                    HStack {
                                        Text("Tint").font(.system(size: 10)).foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(clip.tint)")
                                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                    }
                                    Slider(value: Binding<Double>(
                                        get: { Double(clip.tint) },
                                        set: { clip.tint = Int16($0) }
                                    ), in: -50...50).controlSize(.small)
                                    .disabled(isExporting)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        
                        // ── Exposure ─────────────────────────
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Exposure").font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(String(format: "%.2f", clip.exposure))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding<Double>(
                                get: { Double(clip.exposure) },
                                set: { clip.exposure = Float($0) }
                            ), in: -5...5).controlSize(.small)
                            .disabled(isExporting)
                        }
                        
                        Divider()
                        
                        Button(action: { project.applyClipSettingsToAll(from: project.selectedIndex) }) {
                            Label("Apply to All Clips", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                        .disabled(isExporting)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity)
                
                GroupBox(label: Text("Highlight Recovery").font(.headline)) {
                    Toggle("Enable", isOn: $clip.highlightRecovery)
                        .help("Reconstruct clipped highlights. Compare with it off to judge whether recovery improves this shot.")
                        .padding(.vertical, 2)
                        .disabled(isExporting)
                }
                
                GroupBox(label: Text("LUT").font(.headline)) {
                    Toggle("Preview Embedded LUT", isOn: $clip.previewLUT)
                        .padding(.vertical, 2)
                        .disabled(isExporting)
                }
            }
            .padding(12)
            
            Divider()
            
            Button(action: { clip.resetAdjustments() }) {
                Label("Reset Adjustments", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isExporting)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}
