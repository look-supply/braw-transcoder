import SwiftUI

struct PreviewView: View {
    @ObservedObject var project: ProjectModel
    
    var body: some View {
        VStack(spacing: 0) {
            if let clip = project.selectedClip {
                PreviewHeader(clip: clip, isExporting: project.isExporting)
            } else {
                Text("No clip selected")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: PanelLayout.headerHeight)
            }
            
            Divider()
            
            if let clip = project.selectedClip {
                PreviewContent(clip: clip, isExporting: project.isExporting)
            } else {
                GeometryReader { geo in
                    ZStack {
                        Color.black.opacity(0.92)
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack").font(.system(size: 56))
                                .foregroundColor(.white.opacity(0.15))
                            Text("No Clip Selected").font(.title3)
                                .foregroundColor(.white.opacity(0.35))
                            Text("Import a BRAW file or select a clip from the sidebar")
                                .font(.callout).foregroundColor(.white.opacity(0.2))
                        }
                    }
                }
            }
        }
    }
}

struct PreviewContent: View {
    @ObservedObject var clip: ClipModel
    let isExporting: Bool
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.92)
                
                let aspect = clip.renderAspectRatio
                
                if let preview = clip.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxWidth: geo.size.width - 24, maxHeight: geo.size.height - 60)
                } else if clip.isLoadingPreview {
                    ProgressView().scaleEffect(1.2)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "film").font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.25))
                        Text("\(clip.nativeWidth) × \(clip.nativeHeight)")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                
                VStack(alignment: .leading) {
                    if clip.falseColorEnabled {
                        FalseColorLegend().padding(12)
                    }
                    if let error = clip.previewError {
                        Text(error).font(.caption).foregroundStyle(.white)
                            .padding(8).background(.black.opacity(0.8))
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        HStack {
                            Text("Frame").font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                            
                            Slider(value: Binding<Double>(
                                get: { Double(clip.currentFrame) },
                                set: { clip.currentFrame = UInt64($0) }
                            ), in: 0...Double(max(clip.frameCount, 1) - 1))
                            .controlSize(.small)
                            .disabled(isExporting)
                            
                            Text("\(clip.currentFrame)").font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                                .frame(width: 60, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        
                        HStack {
                            Text("0").font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                            Spacer()
                            Text("\(clip.frameCount - 1)").font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.7))
                }
            }
        }
    }
}


struct PreviewHeader: View {
    @ObservedObject var clip: ClipModel
    let isExporting: Bool

    private var colorInfo: String {
        [clip.renderedGamma, clip.gamut, "Gen \(clip.colorScienceGen)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var details: some View {
        HStack(spacing: 6) {
            Text(clip.fileName).font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .help(clip.fileName)
            Text("\(clip.renderDimensions.width)×\(clip.renderDimensions.height) · \(String(format: "%.2f", clip.frameRate)) fps")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize()
            Text("· \(colorInfo)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(colorInfo)
        }
    }
    private var modes: some View {
        HStack(spacing: 8) {
            PreviewModeControl(mode: Binding(get: { clip.previewMode }, set: { clip.previewMode = $0 }),
                               isEnabled: !isExporting)
                .fixedSize()
                .help("Choose the embedded LUT or log preview signal.")
            FalseColorToggle(isOn: $clip.falseColorEnabled, isEnabled: !isExporting)
                .fixedSize()
                .help("Show false color for the active preview signal, matching waveform levels.")
        }

    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { details; Spacer(minLength: 8); modes }
                .frame(height: PanelLayout.headerHeight)
            VStack(alignment: .leading, spacing: 6) {
                details
                HStack { Spacer(minLength: 0); modes }
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}


private struct FalseColorLegend: View {
    private let bands: [(String, FalseColor.RGB)] = [
        ("95%WC", FalseColor.red), ("80%WC", FalseColor.yellow),
        ("MG+1", FalseColor.pink), ("18%MG", FalseColor.green),
        ("NBDL", FalseColor.blue), ("BDL", FalseColor.purple)
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(bands.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    let c = bands[i].1
                    Rectangle().fill(Color(red: Double(c.r)/255, green: Double(c.g)/255, blue: Double(c.b)/255))
                        .frame(width: 12, height: 8)
                    Text(bands[i].0).font(.system(size: 9)).foregroundStyle(.white)
                }
            }
        }
        .padding(7).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
        .help("Active preview signal levels from 0 to 100. These do not measure camera-specific sensor clipping.")
    }
}


private struct PreviewModeControl: NSViewRepresentable {
    @Binding var mode: PreviewMode
    let isEnabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: PreviewMode.allCases.map(\.rawValue),
                                         trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.controlSize = .small
        control.segmentDistribution = .fit
        control.setAccessibilityLabel("Preview display")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = PreviewMode.allCases.firstIndex(of: mode) ?? 0
        control.isEnabled = isEnabled
    }
    @MainActor final class Coordinator: NSObject {
        var parent: PreviewModeControl
        init(_ parent: PreviewModeControl) { self.parent = parent }
        @objc func changed(_ control: NSSegmentedControl) {
            guard PreviewMode.allCases.indices.contains(control.selectedSegment) else { return }
            parent.mode = PreviewMode.allCases[control.selectedSegment]
        }
    }
}


private struct FalseColorToggle: NSViewRepresentable {
    @Binding var isOn: Bool
    let isEnabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "False color", target: context.coordinator,
                              action: #selector(Coordinator.changed(_:)))
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel("False color")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.state = isOn ? .on : .off
        button.isEnabled = isEnabled
    }
    @MainActor final class Coordinator: NSObject {
        var parent: FalseColorToggle
        init(_ parent: FalseColorToggle) { self.parent = parent }
        @objc func changed(_ button: NSButton) { parent.isOn = button.state == .on }
    }
}
