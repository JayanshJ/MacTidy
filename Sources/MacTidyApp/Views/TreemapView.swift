import SwiftUI
import CoreKit

/// A read-only squarified(ish) treemap of disk usage: each tile's area is
/// proportional to its allocated size. Tapping a directory tile drills into
/// it; tapping a file reveals it in Finder. Pure visualization — no mutation.
struct TreemapView: View {
    let items: [ScanItem]
    var onDrillInto: (ScanItem) -> Void

    private static let palette: [Color] = [
        .blue, .teal, .indigo, .purple, .pink, .orange, .green, .cyan, .mint
    ]

    var body: some View {
        GeometryReader { proxy in
            let canvas = CGRect(origin: .zero, size: proxy.size)
            let tiles = Self.layout(items.sorted { $0.sizeBytes > $1.sizeBytes },
                                    in: canvas)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.quaternary.opacity(0.3))
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    tileView(tile, color: Self.palette[index % Self.palette.count])
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
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
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
                    .foregroundStyle(.white)
                    .padding(5)
                }
            }
            .frame(width: r.width, height: r.height)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .position(x: r.midX, y: r.midY)
        .help("\(tile.item.url.lastPathComponent) — \(tile.item.sizeBytes.formattedBytes)")
    }

    /// Recursive binary-split layout: split the longest axis at the point that
    /// halves the byte total, recurse each side. Produces squarish tiles whose
    /// areas are proportional to size. Degenerate (zero-size) items are
    /// dropped so they don't get invisible slivers.
    static func layout(_ items: [ScanItem], in rect: CGRect) -> [(rect: CGRect, item: ScanItem)] {
        let sized = items.filter { $0.sizeBytes > 0 }
        guard let first = sized.first else { return [] }
        guard sized.count > 1 else { return [(rect, first)] }

        let total = sized.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > 0 else { return [] }

        // Find the split index whose cumulative total first reaches half.
        var cum: Int64 = 0
        var split = 0
        let half = total / 2
        for (i, item) in sized.enumerated() {
            cum += item.sizeBytes
            if cum >= half { split = i; break }
        }
        split = min(max(split, 0), sized.count - 2)
        let left = Array(sized[0...split])
        let right = Array(sized[(split + 1)...])
        let leftTotal = left.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let leftFrac = CGFloat(leftTotal) / CGFloat(total)

        if rect.width >= rect.height {
            let lw = rect.width * leftFrac
            let leftRect = CGRect(x: rect.minX, y: rect.minY, width: lw, height: rect.height)
            let rightRect = CGRect(x: rect.minX + lw, y: rect.minY,
                                   width: rect.width - lw, height: rect.height)
            return layout(left, in: leftRect) + layout(right, in: rightRect)
        } else {
            let lh = rect.height * leftFrac
            let leftRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lh)
            let rightRect = CGRect(x: rect.minX, y: rect.minY + lh,
                                   width: rect.width, height: rect.height - lh)
            return layout(left, in: leftRect) + layout(right, in: rightRect)
        }
    }
}