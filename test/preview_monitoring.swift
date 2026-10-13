import AppKit
import SwiftUI

// Shared app header geometry, without linking the application entry point.
enum PanelLayout { static let headerHeight: CGFloat = 40 }

@main
struct MonitoringTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(CommandLine.arguments.count == 2)
        for (signal, expected) in [(0.0, FalseColor.purple), (0.03, FalseColor.blue),
                                   (0.40, FalseColor.green), (0.54, FalseColor.pink),
                                   (0.85, FalseColor.yellow), (0.98, FalseColor.red)] {
            precondition(FalseColor.color(signal: signal) == expected)
            let byte = UInt8((signal * 255).rounded())
            let output = FalseColor.render(bgra: Data([byte, byte, byte, 255]), width: 1, height: 1)!
            precondition(output == Data([expected.b, expected.g, expected.r, 255]))
        }
        precondition(FalseColor.render(bgra: Data(), width: 1, height: 1) == nil)
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "waveformVisible")
        defer {
            if let previous { defaults.set(previous, forKey: "waveformVisible") }
            else { defaults.removeObject(forKey: "waveformVisible") }
        }
        defaults.removeObject(forKey: "waveformVisible")
        let project = ProjectModel()
        precondition(!project.waveformVisible, "Waveform should start hidden")
        project.waveformVisible = true
        precondition(ProjectModel().waveformVisible, "Waveform state did not survive recreation")
        project.waveformVisible = false
        precondition(!ProjectModel().waveformVisible)
        _ = project.importClip(path: CommandLine.arguments[1])
        let deadline = Date().addingTimeInterval(50)
        func wait(_ condition: () -> Bool) async throws {
            while !condition() {
                precondition(Date() < deadline, "Preview monitoring timed out")
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func pixels(_ image: NSImage?) -> Data {
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let bytes = cg.dataProvider?.data else { fatalError("Missing preview") }
            return bytes as Data
        }
        try await wait { !project.isImporting && project.selectedClip != nil }
        let clip = project.selectedClip!
        clip.previewMode = .log
        try await wait { !clip.isLoadingPreview && !clip.isLoadingThumbnail }
        precondition(clip.previewError == nil, clip.previewError ?? "")
        let previewImage = clip.preview!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(previewImage.width == clip.renderDimensions.width && previewImage.height == clip.renderDimensions.height,
                     "Main preview was decoded below native render resolution")
        let logPixels = pixels(clip.preview)
        let scope = clip.waveform!.imageData
        let h = braw_project_get_clip(project.projectHandle, Int32(project.selectedIndex))!
        let settingsBefore = braw_clip_get_settings(h)
        clip.falseColorEnabled = true
        precondition(!clip.previewLUT && clip.falseColorEnabled)
        try await wait { !clip.isLoadingPreview && !clip.isLoadingThumbnail }
        precondition(clip.previewError == nil, clip.previewError ?? "")
        let falsePixels = pixels(clip.preview)
        precondition(falsePixels != logPixels, "False color did not replace the log image")
        precondition(clip.waveform!.imageData == scope, "False-color palette contaminated the waveform")
        let settingsAfter = braw_clip_get_settings(h)
        precondition(settingsBefore.toneCurveEnabled == settingsAfter.toneCurveEnabled && settingsBefore.exposure == settingsAfter.exposure)
        clip.exposure = 1
        try await wait { !clip.isLoadingPreview && !clip.isLoadingThumbnail }
        precondition(pixels(clip.preview) != falsePixels, "Exposure did not update false color")
        clip.exposure = 0
        clip.previewMode = .embeddedLUT
        try await wait { !clip.isLoadingPreview && !clip.isLoadingThumbnail }
        precondition(clip.previewLUT && clip.previewMode == .embeddedLUT && clip.falseColorEnabled,
                     "Switching to LUT disabled false color")
        let lutFalsePixels = pixels(clip.preview)
        let lutScope = clip.waveform!.imageData
        clip.falseColorEnabled = false
        try await wait { !clip.isLoadingPreview }
        let lutPixels = pixels(clip.preview)
        precondition(lutPixels != lutFalsePixels, "False color did not apply to LUT preview")
        let dimensions = clip.preview!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(FalseColor.render(bgra: lutPixels, width: dimensions.width, height: dimensions.height) == lutFalsePixels,
                     "False color did not measure the active LUT signal")
        precondition(clip.waveform!.imageData == lutScope, "Overlay changed the LUT waveform")
        clip.falseColorEnabled = true
        clip.falseColorEnabled = false
        clip.previewMode = .log
        try await wait { !clip.isLoadingPreview && !clip.isLoadingThumbnail }
        precondition(pixels(clip.preview) == logPixels, "Rapid changes displayed stale false color")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        for width: CGFloat in [400, 500, 900] {
            let view = NSHostingView(rootView: PreviewView(project: project))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            precondition(view.bounds.width == width, "Preview header increased the minimum window width")
            let control = descendants(view).compactMap { $0 as? NSSegmentedControl }.first!
            let bounds = control.convert(control.bounds, to: view)
            precondition(bounds.minX >= 0 && bounds.maxX <= width, "Preview mode control overflowed")
            precondition(control.trackingMode == .selectOne && control.segmentCount == 2)
            let toggle = descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "False color" }!
            let toggleBounds = toggle.convert(toggle.bounds, to: view)
            precondition(abs(toggleBounds.minX - bounds.maxX - 8) < 1, "False color button is not spaced 8 points from segments")
            toggle.performClick(nil)
            precondition(clip.falseColorEnabled && clip.previewMode == .log)
            control.selectedSegment = 0
            precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
            precondition(clip.previewMode == .embeddedLUT && clip.previewLUT && clip.falseColorEnabled)
            control.selectedSegment = 1
            _ = NSApp.sendAction(control.action!, to: control.target, from: control)
            try await wait { !clip.isLoadingPreview }
            toggle.performClick(nil)
            precondition(!clip.falseColorEnabled && clip.previewMode == .log)
            try await wait { !clip.isLoadingPreview }
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/braw-preview-\(Int(width)).png"))
            window.orderOut(nil)
        }
        clip.falseColorEnabled = true
        try await wait { !clip.isLoadingPreview }
        let view = NSHostingView(rootView: PreviewView(project: project))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 550)
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/braw-preview-false-color.png"))
        print("Independent false color, LUT/log signal bands, live exposure, unmodified waveform, stale requests, persistent visibility, and native preview renders passed")
    }
}
