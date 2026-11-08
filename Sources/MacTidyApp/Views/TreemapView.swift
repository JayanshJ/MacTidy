import SwiftUI
import CoreKit

/// A read-only squarified(ish) treemap of disk usage: each tile's area is
/// proportional to its allocated size. Tapping a directory tile drills into
/// it; tapping a file reveals it in Finder. Pure visualization — no mutation.
struct TreemapView: View {
    let items: [ScanItem]
    var onDrillInto: (ScanItem) -> Void

    var body: some View {
        GeometryReader { proxy in
            let canvas = CGRect(origin: .zero, size: proxy.size)
            let tiles = Self.layout(items.sorted { $0.sizeBytes > $1.sizeBytes },
                                    in: canvas)
            let largest = Double(max(items.map(\.sizeBytes).max() ?? 1, 1))
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.surface)
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    // One hue; bigger tiles are denser.
                    tileView(tile, color: Theme.accent.opacity(0.12 + 0.43 * sqrt(Double(tile.item.sizeBytes) / largest)))
                }
            }
        }
    }

    @ViewBuilder
    private func tileView(_ tile: (rect: CGRect, item: ScanItem), color: Color) -> some View {
        let r = tile.rect
        let bigEnough = r.width > 70 && r.height > 34
        Button {
            if tile.item.isDirectory {
                onDrillInto(tile.item)
            } else {
                showInFinder(tile.item.url)
            }
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color)
                    .padding(1.5)
                if bigEnough {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: tile.item.isDirectory ? "folder.fill" : "doc.fill")
                                .font(.caption2)
                            Text(tile.item.url.lastPathComponent)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        Text(tile.item.sizeBytes.formattedBytes)
                            .font(.system(size: 9, design: .monospaced))
                        if tile.item.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(7)
                }
            }
            .frame(width: r.width, height: r.height)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .position(x: r.midX, y: r.midY)
        .help("\(tile.item.url.lastPathComponent) — \(tile.item.sizeBytes.formattedBytes)")
    }

    /// Bruls et al. squarified layout: add each item to a row while doing so
    /// improves its worst aspect ratio, then lay that row along the short side.
    static func layout(_ items: [ScanItem], in rect: CGRect) -> [(rect: CGRect, item: ScanItem)] {
        let sized = items.filter { $0.sizeBytes > 0 }.sorted { $0.sizeBytes > $1.sizeBytes }
        let total = sized.reduce(0.0) { $0 + Double($1.sizeBytes) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        var remaining = sized.map { ($0, CGFloat(Double($0.sizeBytes) / total) * rect.width * rect.height) }
        var area = rect
        var output: [(rect: CGRect, item: ScanItem)] = []
        func worst(_ row: [(ScanItem, CGFloat)], _ side: CGFloat) -> CGFloat {
            guard !row.isEmpty, side > 0 else { return .infinity }
            let sum = row.reduce(CGFloat.zero) { $0 + $1.1 }
            guard let small = row.map(\.1).min(), let large = row.map(\.1).max(), small > 0 else { return .infinity }
            return max(side * side * large / (sum * sum), sum * sum / (side * side * small))
        }
        while !remaining.isEmpty {
            let side = min(area.width, area.height)
            guard side > 0 else { break }
            var row = [remaining.removeFirst()]
            while let next = remaining.first, worst(row + [next], side) <= worst(row, side) {
                row.append(remaining.removeFirst())
            }
            let sum = row.reduce(CGFloat.zero) { $0 + $1.1 }
            let horizontal = area.width < area.height
            let thickness = sum / side
            var offset: CGFloat = 0
            for (item, value) in row {
                let length = value / thickness
                let tile = horizontal
                    ? CGRect(x: area.minX + offset, y: area.minY, width: length, height: thickness)
                    : CGRect(x: area.minX, y: area.minY + offset, width: thickness, height: length)
                output.append((tile, item)); offset += length
            }
            if horizontal { area.origin.y += thickness; area.size.height -= thickness }
            else { area.origin.x += thickness; area.size.width -= thickness }
        }
        return output
    }
}
