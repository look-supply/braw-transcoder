import AppKit
import SwiftUI

@main @MainActor struct ExportPanelTests {
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    static func snapshot(_ view: NSView, _ name: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: "/private/tmp/braw-export-\(name).png"))
    }
    static func main() {
        precondition(CommandLine.arguments.count == 2)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let project = ProjectModel()
        let manager = ExportManager(project: project)
        let suite = "braw-export-test-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        Task {
            defer { store.removePersistentDomain(forName: suite) }
            _ = project.importClip(path: CommandLine.arguments[1])
            while project.isImporting { try await Task.sleep(for: .milliseconds(20)) }
            precondition(project.selectedClip != nil, "Export fixture import failed")
            for width in [360.0, 500, 720, 1000] {
                let host = NSHostingView(rootView: ExportView(project: project, manager: manager)
                    .defaultAppStorage(store).frame(width: width)
                    .background(Color(nsColor: .windowBackgroundColor)))
                window.contentView = host
                window.setContentSize(NSSize(width: width, height: 300))
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                let popup = { (title: String) in
                    descendants(host).compactMap { $0 as? FullWidthDropdown.Popup }
                        .first { $0.accessibilityLabel() == title }!
                }
                let codec = popup("Codec")
                let resolution = popup("Resolution")
                let before = resolution.convert(resolution.bounds, to: host)
                for control in [codec, resolution, popup("Data Rate")] {
                    let bounds = control.convert(control.bounds, to: host)
                    precondition(bounds.minX >= 11 && bounds.maxX <= width - 11, "Field overflowed narrow panel")
                    precondition(bounds.width >= 100, "Field was compressed")
                }
                resolution.selectItem(at: 1)
                NSApp.sendAction(resolution.action!, to: resolution.target, from: resolution)
                snapshot(host, "\(Int(width))-hevc")
                codec.selectItem(at: 2)
                NSApp.sendAction(codec.action!, to: codec.target, from: codec)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let after = popup("Resolution").convert(popup("Resolution").bounds, to: host)
                precondition(before == after, "Codec changed Resolution position")
                precondition(popup("Resolution").indexOfSelectedItem == 1, "Codec changed selected Resolution")
                precondition(descendants(host).compactMap { $0 as? FullWidthDropdown.Popup }.count == 3,
                             "Codec duplicated quality fields")
                _ = popup("Profile")
                snapshot(host, "\(Int(width))-prores")
                store.set(false, forKey: "exportUseSourceDirectory")
                store.set("/Volumes/Working video files/Exports", forKey: "exportOutputDirectory")
                try await Task.sleep(for: .milliseconds(50))
                window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
                host.layoutSubtreeIfNeeded()
                let outputSwitch = descendants(host).compactMap { $0 as? NSSwitch }.first!
                let outputFolder = descendants(host).compactMap { $0 as? NSTextField }
                    .first { $0.placeholderString == "Choose output folder" }!
                let switchBounds = outputSwitch.convert(outputSwitch.bounds, to: host)
                let folderBounds = outputFolder.convert(outputFolder.bounds, to: host)
                precondition(abs(switchBounds.midY - folderBounds.midY) < 3,
                             "Output folder wrapped below the source toggle")
                precondition(folderBounds.minX > switchBounds.maxX && folderBounds.maxX <= width - 11,
                             "Output folder overlapped the toggle or overflowed the panel")
                snapshot(host, "\(Int(width))-folder")
                store.set(true, forKey: "exportUseSourceDirectory")

                manager.progress = 0.42; manager.clipIndex = 1; manager.totalClips = 3
                manager.currentFrame = 42; manager.totalFrames = 100
                manager.currentClipName = "A003_08311600_C007.braw"
                manager.isExporting = true
                try await Task.sleep(for: .milliseconds(50))
                window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
                host.layoutSubtreeIfNeeded()
                precondition(descendants(host).compactMap { $0 as? FullWidthDropdown.Popup }.isEmpty,
                             "Exporting still displayed settings dropdowns")
                precondition(descendants(host).compactMap { $0 as? NSSwitch }.isEmpty,
                             "Exporting still displayed output settings")
                snapshot(host, "\(Int(width))-progress")
                manager.cancel()
                try await Task.sleep(for: .milliseconds(50))
                precondition(manager.isCancelling, "Cancel did not transition state")
                snapshot(host, "\(Int(width))-cancelling")
                manager.isExporting = false; manager.isCancelling = false
            }
            print("PASS: 360/500/720/1000-point export panels, codec order, resolution retention, folders, progress-only and cancellation states")
            exit(0)
        }
        NSApp.run()
    }
}
