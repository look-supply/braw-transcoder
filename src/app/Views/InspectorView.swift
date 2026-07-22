import SwiftUI

struct InspectorView: View {
    @ObservedObject var project: ProjectModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundColor(.secondary)
                Text("Inspector").font(.headline).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
            if let clip = project.selectedClip {
                InspectorContent(clip: clip, project: project)
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
                            HStack {
                                Text("ISO").font(.system(size: 10)).foregroundColor(.secondary)
                                if clip.nativeISO > 0 {
                                    Text("Native: \(clip.nativeISO)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                            }
                            Picker("ISO", selection: Binding<Int>(
                                get: { clip.isoPresetIndex },
                                set: { clip.applyISOPreset($0) }
                            )) {
                                ForEach(0..<ClipModel.isoPresetLabels.count, id: \.self) { i in
                                    Text(ClipModel.isoPresetLabels[i]).tag(i)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)
                            .disabled(isExporting)
                            
                            if clip.isoPresetIndex < 0 || clip.isoPresetIndex >= ClipModel.isoPresets.count {
                                HStack {
                                    Text(String(format: "%.0f", Double(clip.iso)))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 55, alignment: .trailing)
                                    Slider(value: Binding<Double>(
                                        get: { Double(clip.iso) },
                                        set: { clip.iso = UInt32($0) }
                                    ), in: 100...25600).controlSize(.small)
                                    .disabled(isExporting)
                                }
                            }
                        }
                        
                        // ── Color Temp Preset Dropdown ───────
                        VStack(alignment: .leading, spacing: 4) {
                            Text("White Balance").font(.system(size: 10)).foregroundColor(.secondary)
                            Picker("WB", selection: Binding<Int>(
                                get: { clip.colorPresetIndex },
                                set: { clip.applyColorPreset($0) }
                            )) {
                                ForEach(0..<ClipModel.colorPresetLabels.count, id: \.self) { i in
                                    Text(ClipModel.colorPresetLabels[i]).tag(i)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)
                            .disabled(isExporting)
                            
                            let isAsShot = clip.colorPresetIndex == 0
                            let isCustomWB = clip.colorPresetIndex == ClipModel.colorPresetLabels.count - 1
                            
                            if isAsShot {
                                // Show native values as read-only labels
                                VStack(spacing: 4) {
                                    HStack {
                                        Text("Temp").font(.system(size: 10)).foregroundColor(.secondary)
                                        Text("\(clip.colorTemp)K")
                                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    HStack {
                                        Text("Tint").font(.system(size: 10)).foregroundColor(.secondary)
                                        Text("\(clip.tint)")
                                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                        Spacer()
                                    }
                                }
                            } else if isCustomWB {
                                VStack(spacing: 4) {
                                    HStack {
                                        Text("Temp").font(.system(size: 10)).foregroundColor(.secondary)
                                        Text("\(clip.colorTemp)K")
                                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    Slider(value: Binding<Double>(
                                        get: { Double(clip.colorTemp) },
                                        set: { clip.colorTemp = UInt32($0) }
                                    ), in: 2000...50000).controlSize(.small)
                                    .disabled(isExporting)
                                    
                                    HStack {
                                        Text("Tint").font(.system(size: 10)).foregroundColor(.secondary)
                                        Text("\(clip.tint)")
                                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    Slider(value: Binding<Double>(
                                        get: { Double(clip.tint) },
                                        set: { clip.tint = Int16($0) }
                                    ), in: -50...50).controlSize(.small)
                                    .disabled(isExporting)
                                }
                            }
                        }
                        
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
                    .padding(.vertical, 4)
                }
                
                GroupBox(label: Text("Highlight Recovery").font(.headline)) {
                    Toggle("Enable", isOn: $clip.highlightRecovery)
                        .padding(.vertical, 2)
                        .disabled(isExporting)
                }
                
                GroupBox(label: Text("LUT").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Preview Embedded LUT", isOn: $clip.previewLUT)
                            .disabled(isExporting)
                        Toggle("Bake LUT into Output", isOn: $clip.bakeLUT)
                            .disabled(isExporting || !clip.previewLUT)
                    }
                    .padding(.vertical, 2)
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
