import SwiftUI

struct ExportFieldWidth: LayoutValueKey { static let defaultValue: CGFloat = 140 }

// Wrap whole fields in reading order, then share each row's remaining width.
// Labels and controls always move together; codec changes never reorder fields.
struct ExportControlsLayout: Layout {
    var spacing: CGFloat = 12
    struct Row { var indices: [Int]; var widths: [CGFloat]; var height: CGFloat }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        guard !subviews.isEmpty else { return [] }
        let minimums = subviews.map { min(width, $0[ExportFieldWidth.self]) }
        var groups: [[Int]] = []
        var group: [Int] = []
        var used: CGFloat = 0
        for index in subviews.indices {
            let needed = minimums[index] + (group.isEmpty ? 0 : spacing)
            if !group.isEmpty && used + needed > width {
                groups.append(group); group = []; used = 0
            }
            used += minimums[index] + (group.isEmpty ? 0 : spacing)
            group.append(index)
        }
        if !group.isEmpty { groups.append(group) }
        // Avoid a lone action column when the destination and actions fit together.
        if groups.count > 1, groups[groups.count - 1].count == 1,
           groups[groups.count - 2].count > 1,
           let previous = groups[groups.count - 2].last,
           let last = groups.last?.first,
           minimums[previous] + spacing + minimums[last] <= width {
            groups[groups.count - 2].removeLast()
            groups[groups.count - 1].insert(previous, at: 0)
        }
        return groups.map { indices in
            let occupied = indices.reduce(CGFloat(0)) { $0 + minimums[$1] } + spacing * CGFloat(indices.count - 1)
            let extra = max(0, width - occupied) / CGFloat(indices.count)
            let widths = indices.map { minimums[$0] + extra }
            let height = zip(indices, widths).map {
                subviews[$0.0].sizeThatFits(ProposedViewSize(width: $0.1, height: nil)).height
            }.max() ?? 0
            return Row(indices: indices, widths: widths, height: height)
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.reduce(CGFloat(0)) { $0 + $1[ExportFieldWidth.self] }
            + spacing * CGFloat(max(0, subviews.count - 1))
        // SwiftUI probes zero width when calculating a window's minimum size.
        // Keep a real field width during that probe; one-pixel labels would
        // otherwise wrap vertically and inflate the minimum window height.
        let minimumWidth = subviews.map { $0[ExportFieldWidth.self] }.max() ?? 1
        let width = max(minimumWidth, proposal.width ?? natural)
        let rows = rows(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height }
                      + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, width) in zip(row.indices, row.widths) {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                     proposal: ProposedViewSize(width: width, height: nil))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }
}
