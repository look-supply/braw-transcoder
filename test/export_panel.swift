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
    static func press(_ identifier: String, in view: NSView) {
        // SwiftUI buttons are drawn rather than NSButtons. Exercise actual mouse
        // input at the settings row's trailing button / sheet footer's Done button.
        let topY = identifier == "export-settings" ? 54.0 : view.bounds.height - 35
        let point = view.convert(NSPoint(x: view.bounds.width - 80,
            y: view.isFlipped ? topY : view.bounds.height - topY), to: nil)
        let window = view.window!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
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
                precondition(descendants(host).compactMap { $0 as? FullWidthDropdown.Popup }.isEmpty,
                             "Main panel still displayed compression controls")
                snapshot(host, "\(Int(width))-main")
                if width == 360 {
                    press("export-settings", in: host)
                    try await Task.sleep(for: .milliseconds(300))
                    guard let sheet = window.attachedSheet, let sheetHost = sheet.contentView else {
                        fatalError("Settings did not open as a sheet")
                    }
                    sheetHost.layoutSubtreeIfNeeded()
                    let popup = { (title: String) in
                        descendants(sheetHost).compactMap { $0 as? FullWidthDropdown.Popup }
                            .first { $0.accessibilityLabel() == title }!
                    }
                    let codec = popup("Format")
                    let resolution = popup("Resolution")
                    let before = resolution.convert(resolution.bounds, to: sheetHost)
                    for control in [codec, resolution, popup("Data Rate")] {
                        let bounds = control.convert(control.bounds, to: sheetHost)
                        precondition(bounds.minX >= 20 && bounds.maxX <= sheetHost.bounds.width - 20,
                                     "Field overflowed sheet")
                        precondition(bounds.width >= 300, "Settings field was compressed")
                    }
                    resolution.selectItem(at: 1)
                    NSApp.sendAction(resolution.action!, to: resolution.target, from: resolution)
                    snapshot(sheetHost, "\(Int(width))-hevc-settings")
                    codec.selectItem(at: 2)
                    NSApp.sendAction(codec.action!, to: codec.target, from: codec)
                    try await Task.sleep(for: .milliseconds(100))
                    sheetHost.layoutSubtreeIfNeeded()
                    let after = popup("Resolution").convert(popup("Resolution").bounds, to: sheetHost)
                    precondition(before == after, "Codec changed Resolution position")
                    precondition(popup("Resolution").indexOfSelectedItem == 1, "Codec changed selected Resolution")
                    precondition(descendants(sheetHost).compactMap { $0 as? FullWidthDropdown.Popup }.count == 3,
                                 "Codec duplicated quality fields")
                    _ = popup("Profile")
                    store.set(false, forKey: "exportUseSourceDirectory")
                    store.set("/Volumes/Working video files/Exports", forKey: "exportOutputDirectory")
                    try await Task.sleep(for: .milliseconds(100))
                    sheetHost.layoutSubtreeIfNeeded()
                    let outputFolder = descendants(sheetHost).compactMap { $0 as? NSTextField }
                        .first { $0.placeholderString == "Choose output folder" }!
                    let folderBounds = outputFolder.convert(outputFolder.bounds, to: sheetHost)
                    precondition(folderBounds.minX >= 20 && folderBounds.maxX <= sheetHost.bounds.width - 20,
                                 "Output folder overflowed sheet")
                    snapshot(sheetHost, "\(Int(width))-prores-settings")
                    press("export-settings-done", in: sheetHost)
                    try await Task.sleep(for: .milliseconds(300))
                    precondition(window.attachedSheet == nil, "Done did not close settings")
                    window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
                    host.layoutSubtreeIfNeeded()
                    snapshot(host, "\(Int(width))-prores-main")
                    press("export-settings", in: host)
                    try await Task.sleep(for: .milliseconds(300))
                    let reopened = window.attachedSheet!.contentView!
                    let controls = descendants(reopened).compactMap { $0 as? FullWidthDropdown.Popup }
                    precondition(controls.first { $0.accessibilityLabel() == "Format" }!.indexOfSelectedItem == 2,
                                 "Reopening settings lost format")
                    precondition(controls.first { $0.accessibilityLabel() == "Resolution" }!.indexOfSelectedItem == 1,
                                 "Reopening settings lost resolution")
                    // Exercise Escape through the sheet's responder chain.
                    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: window.attachedSheet!.windowNumber, context: nil,
                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                    window.attachedSheet!.sendEvent(escape)
                    try await Task.sleep(for: .milliseconds(300))
                    precondition(window.attachedSheet == nil, "Escape did not close settings")
                    store.set(true, forKey: "exportUseSourceDirectory")
                }

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
            print("PASS: compact 360/500/720/1000-point panels, settings sheet, codec/resolution retention, folders, Done/Escape, progress and cancellation")
            exit(0)
        }
        NSApp.run()
    }
}
