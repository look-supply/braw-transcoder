import AppKit
import SwiftUI

@main @MainActor struct InspectorMetadataTests {
    static func main() async throws {
        precondition(CommandLine.arguments.count == 2)
        let project = ProjectModel()
        _ = project.importClip(path: CommandLine.arguments[1])
        while project.isImporting { try await Task.sleep(for: .milliseconds(20)) }
        guard let clip = project.selectedClip else { fatalError("Fixture import failed") }
        let source = clip.sourceMetadata
        precondition(!source.isEmpty, "Source metadata was not loaded")
        let entries = InspectorMetadataEntry.all(for: clip)
        precondition(Set(entries.map(\.key)).count == entries.count, "Duplicate field identifiers")
        for (key, value) in source where InspectorMetadataEntry.isReadableField(key: key, value: value) {
            precondition(entries.contains { $0.key == key && $0.value == value }, "Dropped source field: \(key)")
        }
        precondition(!entries.contains { $0.key == "post_3dlut_embedded_data" }, "Embedded LUT payload is visible")
        precondition(!InspectorMetadataEntry.copyText(entries).contains("post_3dlut_embedded_data:"), "Copied embedded LUT payload")
        for key in ["post_3dlut_sidecar_data", "lens_shading_points", "lens_distortion_correction_polynomial", "analog_gain", "crop_origin", "tone_curve_contrast"] {
            precondition(!entries.contains { $0.key == key }, "Internal payload is visible: \(key)")
        }
        precondition(!InspectorMetadataEntry.isReadableField(key: "notes", value: String(repeating: "x", count: 513)))
        precondition(!InspectorMetadataEntry.isReadableField(key: "iso", value: "[800, 1600]"))
        precondition(InspectorMetadataEntry.isReadableField(key: "post_3dlut_embedded_title", value: "Camera look"))
        let unknown = InspectorMetadataEntry(key: "vendor_custom_field", value: "Unknown camera value")
        precondition(unknown.group == .additional)
        precondition(unknown.matches("CUSTOM") && unknown.matches("camera value"))
        precondition(!unknown.matches("no such value"))
        let empty = InspectorMetadataEntry(key: "blank_field", value: "")
        precondition(InspectorMetadataEntry.copyText([empty]) == "blank_field: ")
        precondition(InspectorMetadataEntry.copyText(entries).contains("file.path: \(clip.filePath)"))
        clip.exposure = 1
        clip.colorTemp = 6500
        clip.tint = 12
        precondition(clip.sourceMetadata == source, "Adjustments changed recorded source metadata")
        precondition(InspectorMetadataEntry.copyText(entries) == InspectorMetadataEntry.copyText(InspectorMetadataEntry.all(for: clip)),
                     "Displayed metadata changed with adjustments")
        print("Inspector metadata: readable fields retained; payload exclusion, search, copying and recorded values passed")
    }
}
