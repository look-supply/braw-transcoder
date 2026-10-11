import Foundation
import AppKit

@main
struct AdjustedThumbnailTests {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 2, "Pass a BRAW sample path")
        let project = ProjectModel()
        _ = project.importClip(path: CommandLine.arguments[1])
        _ = project.importClip(path: CommandLine.arguments[1])
        let deadline = Date().addingTimeInterval(50)
        func waitUntil(_ finished: () -> Bool) async throws {
            while !finished() {
                precondition(Date() < deadline, "Timed out waiting for thumbnails")
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func pixels(_ image: NSImage?) -> Data {
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = cgImage.dataProvider?.data else { fatalError("No thumbnail pixels") }
            return data as Data
        }
        try await waitUntil { !project.isImporting }
        precondition(project.importError == nil && project.clipCount == 2, "Import failed")
        let inactive = project.getClip(at: 0)!
        let active = project.getClip(at: 1)!
        project.selectClip(1)
        inactive.loadThumbnail()
        active.loadThumbnail()
        try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail && !inactive.isLoadingThumbnail }
        let baseline = pixels(active.thumbnail)
        let inactivePreview = inactive.preview

        active.exposure = 2
        try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail }
        precondition(pixels(active.thumbnail) != baseline, "Exposure did not refresh thumbnail pixels")

        var previous = active.thumbnail
        active.highlightRecovery.toggle()
        try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail }
        precondition(active.thumbnail !== previous, "Highlight recovery did not refresh thumbnail")
        previous = active.thumbnail
        active.previewLUT.toggle()
        try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail }
        precondition(active.thumbnail !== previous, "LUT change did not refresh thumbnail")

        project.copySettings(from: 1)
        project.pasteSettings(to: 0)
        try await waitUntil { !inactive.isLoadingThumbnail }
        precondition(pixels(inactive.thumbnail) == pixels(active.thumbnail), "Pasted settings did not update inactive thumbnail")
        precondition(inactive.preview === inactivePreview, "Inactive clip unnecessarily decoded a full preview")

        active.exposure = -2
        try await waitUntil { !active.isLoadingThumbnail && !active.isLoadingPreview }
        project.applyClipSettingsToAll(from: 1)
        try await waitUntil { !inactive.isLoadingThumbnail }
        precondition(pixels(inactive.thumbnail) == pixels(active.thumbnail), "Apply to All left a stale thumbnail")

        active.resetAdjustments()
        try await waitUntil { !active.isLoadingThumbnail && !active.isLoadingPreview }
        precondition(pixels(active.thumbnail) == baseline, "Reset did not restore thumbnail pixels")

        // Rapid changes and a selection switch during the debounce must not
        // leave a thumbnail with older settings or cancel the final refresh.
        active.exposure = 3
        active.exposure = -3
        active.exposure = 1
        project.selectClip(0)
        try await waitUntil { !active.isLoadingThumbnail && !inactive.isLoadingPreview }
        let switched = pixels(active.thumbnail)
        active.loadThumbnail(force: true)
        try await waitUntil { !active.isLoadingThumbnail }
        precondition(pixels(active.thumbnail) == switched, "Selection switch published stale adjustments")
        project.releaseDecoders()
        print("PASS: adjusted thumbnails, highlight/LUT refresh, paste, apply-all, reset, rapid changes, selection switch")
    }
}
