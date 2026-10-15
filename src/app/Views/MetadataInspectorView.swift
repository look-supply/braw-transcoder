import AppKit
import SwiftUI

struct InspectorMetadataEntry: Identifiable {
    enum Group: String, CaseIterable {
        case file = "File", camera = "Camera", recording = "Recording"
        case lens = "Lens", production = "Production", color = "Color", additional = "Additional Metadata"
    }
    let key: String
    let label: String
    let value: String
    let group: Group
    var id: String { key }

    init(key: String, value: String, group: Group? = nil, label: String? = nil) {
        self.key = key
        self.value = value
        self.group = group ?? Self.group(for: key)
        self.label = label ?? Self.labels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static let labels = [
        "iso": "ISO", "white_balance_kelvin": "White balance", "white_balance_tint": "Tint",
        "sensor_fps": "Sensor FPS", "fps": "Frame rate", "internal_nd": "Internal ND",
        "camera_id": "Camera ID", "camera_type": "Camera model", "timecode": "Start timecode",
        "date_recorded": "Recorded date", "lens_type": "Lens", "distance": "Focus distance",
        "offspeed": "Off-speed", "is_good": "Good take", "good_take": "Good take",
        "braw_compression_ratio": "BRAW compression", "sensor_rate": "Sensor rate",
        "post_3dlut_embedded_name": "Embedded LUT filename", "post_3dlut_embedded_title": "Embedded LUT title",
        "post_3dlut_sidecar_name": "Sidecar LUT filename", "post_3dlut_sidecar_title": "Sidecar LUT title",
        "post_3dlut_mode": "LUT mode", "viewing_gamma": "Recorded gamma", "viewing_gamut": "Recorded gamut"
    ]

    private static func group(for key: String) -> Group {
        switch key {
        case "manufacturer", "camera_type", "camera_id", "camera_number", "firmware_version": .camera
        case "iso", "white_balance_kelvin", "white_balance_tint", "sensor_fps", "fps", "timecode",
             "date_recorded", "shutter_type", "shutter_value", "offspeed", "timelapse_interval",
             "exposure", "sensor_rate", "braw_compression_ratio": .recording
        case "gamma", "gamut", "color_science_generation", "viewing_gamma", "viewing_gamut",
             "post_3dlut_embedded_name", "post_3dlut_embedded_title", "post_3dlut_sidecar_name",
             "post_3dlut_sidecar_title", "post_3dlut_mode": .color
        case "lens_type", "aperture", "focal_length", "distance", "internal_nd", "lens_filter": .lens
        case "clip_number", "reel_name", "scene", "take", "production_name", "director",
             "camera_operator", "day_night", "environment", "take_type", "shot_type", "is_good",
             "frameguide_aspect_ratio", "good_take": .production
        case "description", "notes", "comment", "copyright", "artist": .additional
        default: .additional
        }
    }

    static func isReadableField(key: String, value: String) -> Bool {
        // The inspector is for human-readable shot information, not decoder
        // internals, calibration arrays, or binary LUT payloads. Bound text
        // even for recognized keys so an unusual clip cannot overwhelm SwiftUI.
        let familiar = group(for: key) != .additional ||
            ["description", "notes", "comment", "copyright", "artist"].contains(key)
        return familiar && !value.isEmpty && value.count <= 512 && !value.hasPrefix("[")
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || [key, label, value].contains { $0.localizedStandardContains(query) }
    }

    @MainActor static func all(for clip: ClipModel) -> [Self] {
        var source = clip.sourceMetadata
        // Fill known source attributes only when the embedded collection lacks them.
        let defaults = [
            "camera_type": clip.cameraName, "iso": String(clip.nativeISO),
            "white_balance_kelvin": String(clip.nativeColorTemp), "white_balance_tint": String(clip.nativeTint),
            "gamma": clip.gamma, "gamut": clip.gamut,
            "color_science_generation": String(clip.colorScienceGen)
        ]
        for (key, value) in defaults where source[key] == nil && !value.isEmpty { source[key] = value }
        let file: [Self] = [
            .init(key: "file.name", value: clip.fileName, group: .file, label: "Filename"),
            .init(key: "file.path", value: clip.filePath, group: .file, label: "Path"),
            .init(key: "file.resolution", value: "\(clip.nativeWidth) × \(clip.nativeHeight)", group: .file, label: "Resolution"),
            .init(key: "file.frame_rate", value: clip.frameRate.formatted(.number.precision(.fractionLength(0...3))) + " fps", group: .file, label: "Frame rate"),
            .init(key: "file.frames", value: String(clip.frameCount), group: .file, label: "Frames"),
            .init(key: "file.duration", value: clip.durationTimecode, group: .file, label: "Duration")
        ]
        return file + source.filter { Self.isReadableField(key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { Self(key: $0.key, value: $0.value) }
    }

    static func copyText(_ entries: [Self]) -> String {
        entries.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

struct MetadataInspectorView: View {
    @ObservedObject var clip: ClipModel
    @State private var query = ""

    private var entries: [InspectorMetadataEntry] { InspectorMetadataEntry.all(for: clip) }
    private var filtered: [InspectorMetadataEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { $0.matches(search) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search metadata", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search metadata")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear metadata search")
                }
            }
            .padding(8)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recorded source metadata. Frame values reflect the first frame.")
                        .font(.caption).foregroundStyle(.secondary)
                    if filtered.isEmpty {
                        Text("No matching metadata").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                    } else {
                        ForEach(InspectorMetadataEntry.Group.allCases, id: \.self) { group in
                            let rows = filtered.filter { $0.group == group }
                            if !rows.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(group.rawValue).font(.headline)
                                    ForEach(rows) { entry in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(entry.label).foregroundStyle(.secondary)
                                                .frame(width: 88, alignment: .leading)
                                            MetadataValueView(value: entry.value)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.system(size: 11))
                                        .textSelection(.enabled)
                                        .help(entry.key)
                                        .contextMenu {
                                            Button("Copy Value") { copy(entry.value) }
                                            Button("Copy Field and Value") { copy(InspectorMetadataEntry.copyText([entry])) }
                                        }
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            Divider()
            HStack {
                Text("\(filtered.count) of \(entries.count) fields")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Copy All Metadata") { copy(InspectorMetadataEntry.copyText(entries)) }
                    .controlSize(.small)
                    .help("Copy every field, including fields hidden by search.")
            }
            .padding(12)
        }
    }
}

private struct MetadataValueView: View {
    let value: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.isEmpty ? "Empty" : value.count > 240 && !expanded ? String(value.prefix(180)) + "…" : value)
            if value.count > 240 {
                Button(expanded ? "Show less" : "Show full value") { expanded.toggle() }
                    .buttonStyle(.link)
                    .accessibilityLabel(expanded ? "Collapse metadata value" : "Expand full metadata value")
            }
        }
    }
}
