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
                PreviewContent(clip: clip, project: project)
                    .id(clip.id)
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
        .background(PlaybackKeyboardShortcuts(project: project).frame(width: 0, height: 0))
    }
}

/// Handle Space before focused buttons consume it. Text editors keep their
/// normal input; the monitor only handles events from the preview's own window.
struct PlaybackKeyboardShortcuts: NSViewRepresentable {
    let project: ProjectModel
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.project = project }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.removeMonitor() }

    final class Anchor: NSView {
        var project: ProjectModel?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window,
                  !(window.firstResponder is NSTextView),
                  let project else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if modifiers == .command, key == "a" {
                project.selectAllClips()
                return nil
            }
            guard let clip = project.selectedClip else { return event }
            if modifiers.contains(.command), modifiers.intersection([.control, .option]).isEmpty {
                if key == "+" || key == "=" { clip.zoomIn(); return nil }
                if key == "-" { clip.zoomOut(); return nil }
            }
            if modifiers.isEmpty, key == "z" { clip.resetZoom(); return nil }
            guard event.keyCode == 49, modifiers.isEmpty,
                  !project.isExporting, !project.isImporting, clip.frameCount > 0 else { return event }
            if !event.isARepeat { clip.togglePlayback() }
            return nil
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

struct PreviewWheelZoom: NSViewRepresentable {
    let clip: ClipModel
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.clip = clip }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.removeMonitor() }
    final class Anchor: NSView {
        weak var clip: ClipModel?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handleScroll(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                    location: event.locationInWindow, eventWindow: event.window) else { return event }
                return nil
            }
        }
        func handleScroll(delta: CGFloat, precise: Bool, location: NSPoint, eventWindow: NSWindow?) -> Bool {
            guard let window, eventWindow === window, bounds.contains(convert(location, from: nil)),
                  let clip, delta != 0 else { return false }
            let sensitivity: Double = precise ? 0.006 : 0.08
            clip.zoomPreview(by: CGFloat(exp(max(-1, min(1, Double(delta) * sensitivity)))))
            return true
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

struct PreviewContent: View {
    @ObservedObject var clip: ClipModel
    @ObservedObject var project: ProjectModel
    var isExporting: Bool { project.isExporting || project.isImporting }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.92)
                    .overlay {
                        PreviewWheelZoom(clip: clip)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.bottom, 60)
                    }
                
                let aspect = clip.renderAspectRatio
                
                if let frame = clip.playbackFrame {
                    MetalPlaybackView(frame: frame, zoom: clip.previewZoom)
                        .frame(width: max(1, geo.size.width - 24), height: max(1, geo.size.height - 60))
                } else if let preview = clip.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(width: max(1, geo.size.width - 24), height: max(1, geo.size.height - 60))
                        .scaleEffect(clip.previewZoom)
                        .frame(width: max(1, geo.size.width - 24), height: max(1, geo.size.height - 60))
                        .clipped()
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
                    HStack(alignment: .top, spacing: 12) {
                        Button { clip.togglePlayback() } label: {
                            Image(systemName: clip.isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .help(clip.isPlaying ? "Pause playback (Space)" : "Play (Space)")
                        .accessibilityLabel(clip.isPlaying ? "Pause" : "Play")
                        .accessibilityIdentifier("preview-playback")
                        .disabled(isExporting || clip.frameCount == 0)
                        .padding(.top, 2)
                        VStack(spacing: 4) {
                            HStack(spacing: 8) {
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
                                    .frame(width: 44, alignment: .trailing)
                            }

                            HStack {
                                Text("0").font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.3))
                                Spacer()
                                Text("\(max(clip.frameCount, 1) - 1)").font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                        }
                        PlaybackTransportControls(clip: clip, project: project)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.7))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onDisappear { clip.stopPlayback(refreshPreview: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            clip.stopPlayback()
        }
    }
}

private struct PlaybackTransportControls: View {
    @ObservedObject var clip: ClipModel
    @ObservedObject var project: ProjectModel
    private var unavailable: Bool { project.isExporting || project.isImporting }

    var body: some View {
        HStack(spacing: 10) {
            control("Previous clip", symbol: "backward.end.fill") { project.navigatePlaybackClip(by: -1) }
                .disabled(unavailable || project.selectedIndex <= 0)
            Button { clip.togglePlayback(direction: .reverse) } label: {
                Image(systemName: clip.isPlaying && clip.playbackDirection == .reverse ? "pause.fill" : "play.fill")
                    .rotationEffect(.degrees(180)).frame(width: 18, height: 18)
            }
            .help(clip.isPlaying && clip.playbackDirection == .reverse ? "Pause reverse playback" : "Play in reverse")
            .accessibilityLabel("Play/Pause in reverse")
            .accessibilityIdentifier("preview-reverse")
            .disabled(unavailable || clip.frameCount == 0)
            control("Stop and rewind", symbol: "stop.fill") { project.stopAndRewindPlayback() }
                .disabled(unavailable)
            control("Next clip", symbol: "forward.end.fill") { project.navigatePlaybackClip(by: 1) }
                .disabled(unavailable || project.selectedIndex >= project.clipCount - 1)
            control(project.playbackLoopEnabled ? "Disable clip loop" : "Enable clip loop", symbol: "repeat") {
                project.playbackLoopEnabled.toggle()
            }
                .foregroundStyle(project.playbackLoopEnabled ? Color.red : Color.white.opacity(0.55))
                .accessibilityValue(project.playbackLoopEnabled ? "On" : "Off")
                .accessibilityIdentifier("preview-loop")
                .disabled(unavailable)
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .fixedSize()
    }
    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 18) }
            .help(title).accessibilityLabel(title)
    }
}


struct PreviewHeader: View {
    @ObservedObject var clip: ClipModel
    let isExporting: Bool

    private var colorInfo: String {
        [clip.renderedGamma, "Gen \(clip.colorScienceGen)"]
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
        HStack(spacing: 12) {
            PreviewModeControl(mode: Binding(get: { clip.previewMode }, set: { clip.previewMode = $0 }),
                               isEnabled: !isExporting)
                .fixedSize()
                .help("Choose the embedded LUT or log preview signal.")
            FalseColorToggle(isOn: $clip.falseColorEnabled, isEnabled: !isExporting)
                .fixedSize()
                .help("Show false color for the active preview signal, matching waveform levels.")
        }

    }
    private var zoomControls: some View {
        HStack(spacing: 4) {
            Text("\(Int((clip.previewZoom * 100).rounded()))%")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
                .padding(.leading, 4)
                .help("Zoom relative to fit")
                .accessibilityLabel("Zoom \(Int((clip.previewZoom * 100).rounded())) percent")
            zoomButton("Zoom in (⌘+)", symbol: "plus.magnifyingglass", action: clip.zoomIn)
            zoomButton("Zoom out (⌘−)", symbol: "minus.magnifyingglass", action: clip.zoomOut)
            zoomButton("Reset zoom (Z)", symbol: "arrow.counterclockwise", action: clip.resetZoom)
        }.fixedSize()
    }
    private func zoomButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 16, height: 16) }
            .buttonStyle(.bordered).controlSize(.small).font(.system(size: 12))
            .help(title).accessibilityLabel(title)
    }
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { zoomControls; modes }
            VStack(alignment: .trailing, spacing: 6) { zoomControls; modes }
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { details; Spacer(minLength: 8); controls }
                .frame(height: PanelLayout.headerHeight)
            VStack(alignment: .leading, spacing: 6) {
                details
                HStack { Spacer(minLength: 0); controls }
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
