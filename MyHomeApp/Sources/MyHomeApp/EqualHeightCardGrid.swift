import SwiftUI

/// Adaptive card grid where EVERY card in the section shares one height: the
/// tallest card's natural content height.
///
/// Why a `Layout` and not LazyVGrid + measurement: a lazy grid only sizes
/// rows it has rendered and sizes each row on its own, so section-wide
/// equality needed a GeometryReader -> preference -> @State -> frame round
/// trip. That round trip lags late-loading controls, never shrinks cleanly and
/// can feed back into itself. Here the maximum is computed inside the layout
/// pass itself: every pass re-asks each card for its natural height, so a
/// device whose controls arrive late (or a section switch) simply produces a
/// new maximum on the next pass. No stored state, no preferences, no loop.
///
/// Cards should carry `.frame(maxHeight: .infinity, alignment: .topLeading)`
/// so they fill the shared height with their content top-aligned.
struct EqualHeightCardGrid: Layout {
    /// Narrowest a column may get; columns are added while they still fit.
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat

    private struct Metrics {
        var columns: Int
        var columnWidth: CGFloat
        var rowHeight: CGFloat
        var rows: Int
    }

    private func metrics(width: CGFloat, subviews: Subviews) -> Metrics {
        let count = subviews.count
        let columns = max(1, min(count, Int((width + spacing) / (minimumColumnWidth + spacing))))
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        // Natural height: unspecified height proposal, so a card's
        // `maxHeight: .infinity` frame reports its content height here.
        let rowHeight = subviews
            .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
            .max() ?? 0
        let rows = count == 0 ? 0 : (count + columns - 1) / columns
        return Metrics(columns: columns, columnWidth: columnWidth, rowHeight: rowHeight, rows: rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        // No width offered (ideal-size query): lay out as a single column.
        let width = proposal.width ?? minimumColumnWidth
        let m = metrics(width: width, subviews: subviews)
        let height = CGFloat(m.rows) * m.rowHeight + spacing * CGFloat(max(0, m.rows - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let m = metrics(width: bounds.width, subviews: subviews)
        let cell = ProposedViewSize(width: m.columnWidth, height: m.rowHeight)
        for (index, subview) in subviews.enumerated() {
            let row = index / m.columns
            let column = index % m.columns
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (m.columnWidth + spacing),
                y: bounds.minY + CGFloat(row) * (m.rowHeight + spacing)
            )
            subview.place(at: origin, anchor: .topLeading, proposal: cell)
        }
    }
}
