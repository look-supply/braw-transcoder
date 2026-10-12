import Foundation
import AppKit

@main
struct AdjustedThumbnailTests {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 2, "Pass a BRAW sample path")
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        var paths: [String] = []
        for i in 0..<3 {
            let folder = fixtures.appendingPathComponent(String(i))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("sample.braw")
            try FileManager.default.copyItem(at: source, to: copy)
            paths.append(copy.path)
        }
        let project = ProjectModel()
        _ = project.importClip(path: paths[0])
        _ = project.importClip(path: paths[1])
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
        // Imports complete asynchronously; selection/export indices refer to
        // the actual project order, not the order tasks were submitted.
        paths = (0..<2).map { String(cString: braw_clip_get_filepath(braw_project_get_clip(project.projectHandle, Int32($0)))) } + [paths[2]]
        let inactive = project.getClip(at: 0)!
        let active = project.getClip(at: 1)!
        precondition(!active.highlightRecovery && !inactive.highlightRecovery, "Imports forced highlight recovery on")
        project.selectClip(1)
        inactive.loadThumbnail()
        active.loadThumbnail()
        try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail && !inactive.isLoadingThumbnail }
        let baseline = pixels(active.thumbnail)
        let previewBaseline = pixels(active.preview)
        let inactivePreview = inactive.preview
        precondition(active.isoPresets.count == Int(braw_clip_get_iso_count(braw_project_get_clip(project.projectHandle, 1))), "Inspector ISO list differs from clip capabilities")
        if !active.isoReadOnly, let adjustedISO = active.isoPresets.first(where: { $0 != active.nativeISO }) {
            active.applyISOPreset(active.isoPresets.firstIndex(of: adjustedISO)! + 1)
            try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail }
            precondition(pixels(active.thumbnail) != baseline && pixels(active.preview) != previewBaseline,
                         "ISO did not refresh thumbnail and main preview")
            active.iso = active.nativeISO
            try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail }
            precondition(pixels(active.thumbnail) == baseline && active.isoPresetIndex == 0, "As Shot ISO did not restore preview")
            active.iso = UInt32.max
            precondition(active.iso == active.nativeISO && active.isoAdjustmentNotice != nil, "Unsupported ISO left inspector inconsistent")
            active.iso = active.nativeISO
            precondition(active.isoAdjustmentNotice == nil, "ISO notice did not clear")
            try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail }
        }

        active.exposure = 2
        try await waitUntil { !active.isLoadingPreview && !active.isLoadingThumbnail }
        precondition(pixels(active.thumbnail) != baseline, "Exposure did not refresh thumbnail pixels")
        precondition(pixels(active.preview) != previewBaseline, "Exposure did not refresh main preview pixels")

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

        // Include a clip whose Swift model has not been created yet (offscreen
        // assets), and verify both native values and inspector preset labels.
        precondition(braw_project_import(project.projectHandle, paths[2]) == 2)
        project.clipCount = 3
        active.iso = active.isoPresets.first(where: { $0 != active.nativeISO }) ?? active.nativeISO
        active.colorTemp = 6100
        active.tint = -7
        active.highlightRecovery = false
        active.exposure = -2
        try await waitUntil { !active.isLoadingThumbnail && !active.isLoadingPreview }
        project.applyClipSettingsToAll(from: 1)
        try await waitUntil { !inactive.isLoadingThumbnail }
        precondition(pixels(inactive.thumbnail) == pixels(active.thumbnail), "Apply to All left a stale thumbnail")
        let offscreen = project.getClip(at: 2)!
        try await waitUntil { !offscreen.isLoadingThumbnail }
        for target in [inactive, offscreen] {
            precondition(target.iso == active.iso && target.colorTemp == active.colorTemp &&
                         target.tint == active.tint && target.exposure == active.exposure &&
                         target.highlightRecovery == active.highlightRecovery && target.previewLUT == active.previewLUT,
                         "Apply to All lost adjustments")
            precondition(target.colorPresetIndex == ClipModel.colorPresetLabels.count - 1,
                         "Apply to All left white balance labeled As Shot")
            precondition(target.isoPresetIndex == (target.nativeISO == active.iso ? 0 : target.isoPresets.firstIndex(of: active.iso)! + 1),
                         "Apply to All left a stale ISO preset")
            let nativeSettings = braw_clip_get_settings(braw_project_get_clip(project.projectHandle, target === inactive ? 0 : 2))
            precondition(nativeSettings.temperature == 6100 && nativeSettings.tint == -7 && !nativeSettings.highlightRecovery,
                         "Native/export settings differ from applied settings")
        }
        project.selectClip(2)
        try await waitUntil { !offscreen.isLoadingPreview }
        precondition(offscreen.previewError == nil && offscreen.preview != nil, "Applied clip preview failed")
        project.selectClip(1)

        active.resetAdjustments()
        precondition(!active.highlightRecovery, "Reset forced highlight recovery on")
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
        // Export releases preview decoders. The selected clip must become
        // active again afterward, or adjustments only refresh its thumbnail.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let exporter = ExportManager(project: project)
        var settings = ExportUISettings()
        settings.codec = 2
        settings.resolutionMode = 4
        settings.outputDir = output.path
        settings.selectedIndices = [0]
        exporter.export(settings: settings)
        try await waitUntil { !exporter.isExporting && !inactive.isLoadingPreview }
        precondition(exporter.statusMessage == "Export complete.", "Test export failed")
        let postExportPreview = pixels(inactive.preview)
        inactive.exposure = -1
        try await waitUntil { !inactive.isLoadingPreview && !inactive.isLoadingThumbnail }
        precondition(pixels(inactive.preview) != postExportPreview,
                     "Exposure left main preview stale after export")
        // Shared selection drives the topmost preview and export's clip list.
        project.selectClip(0)
        project.selectClip(2, extendingRange: true)
        precondition(project.selectedIndices == [0, 1, 2] && project.selectedIndex == 0, "Forward range selection failed")
        project.selectClip(2)
        project.selectClip(0, extendingRange: true)
        precondition(project.selectedIndices == [0, 1, 2] && project.selectedIndex == 0, "Backward range selection failed")
        project.selectClip(1, toggling: true)
        precondition(project.selectedIndices == [0, 2] && project.selectedIndex == 0, "Toggle did not remove middle clip")
        project.selectClip(0, toggling: true)
        precondition(project.selectedIndices == [2] && project.selectedIndex == 2, "Preview did not follow topmost selection")
        project.selectClip(0, toggling: true)
        precondition(project.selectedIndices == [0, 2] && project.selectedIndex == 0, "Toggle did not add individual clip")
        settings.outputDir = ""
        settings.selectedIndices = project.selectedIndices.sorted()
        exporter.export(settings: settings)
        try await waitUntil { !exporter.isExporting && !project.selectedClip!.isLoadingPreview }
        precondition(exporter.totalClips == 2 && exporter.statusMessage == "Export complete.", "Selected export failed")
        for (index, path) in paths.enumerated() {
            let mov = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("mov")
            precondition(FileManager.default.fileExists(atPath: mov.path) == (index != 1), "Selected export output mismatch at index \(index), selected \(project.selectedIndices), path \(mov.path)")
        }
        let survivor = project.getClip(at: 1)!
        for index in project.selectedIndices.sorted(by: >) { project.removeClip(at: index) }
        precondition(project.clipCount == 1 && project.getClip(at: 0) === survivor, "Selected deletion removed the wrong clips")
        precondition(project.selectedIndices.isEmpty && project.selectedClip == nil, "Deletion left stale selection")
        project.selectClip(0)
        _ = project.importClip(path: paths[1])
        try await waitUntil { !project.isImporting }
        precondition(project.clipCount == 1 && project.importError == nil, "Duplicate was added or reported as an error")
        let symlink = fixtures.appendingPathComponent("linked.braw")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: paths[1])
        precondition(braw_project_import(project.projectHandle, symlink.path) == -2, "Symlink duplicate added")
        let hardlink = fixtures.appendingPathComponent("hardlinked.braw")
        try FileManager.default.linkItem(atPath: paths[1], toPath: hardlink.path)
        precondition(braw_project_import(project.projectHandle, hardlink.path) == -2, "Hardlink duplicate added")
        project.releaseDecoders()
        print("PASS: adjusted thumbnails, highlight/LUT refresh, paste, apply-all, reset, rapid changes, selection switch, preview refresh after export, range/toggle selection, selected export/deletion, duplicate skipping")
    }
}
