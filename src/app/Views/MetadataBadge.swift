import SwiftUI

struct MetadataBadge: View {
    let name: String
    let fontSize: CGFloat

    var body: some View {
        Text(name)
            .font(.system(size: fontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .help(name)
    }
}
