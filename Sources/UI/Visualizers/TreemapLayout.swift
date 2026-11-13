// TreemapLayout.swift — squarified, LoD-culled, nested treemap
//
// Squarified layout (Bruls, Huizing & van Wijk) nested up to `maxDepth`
// levels. Children whose area would fall below `minTileArea` (≈ 6 pt × 6 pt),
// and every smaller sibling after them, collapse into one aggregated tile per
// parent. Tiles are stored in draw order (parents before children), so the
// deepest tile under the cursor is found by a reverse scan.

import CoreGraphics
import SwiftUI
import KlaDModels

struct TreemapTile {
    let node: FileTreeNode?        // nil ⇒ aggregate
    let rect: CGRect
    let depth: Int
    let color: Color
    let value: UInt64
    let aggregateCount: Int
    let parent: Int
    /// Has nested tiles drawn inside (rendered as a framed group with a header).
    var isContainer: Bool

    var isAggregate: Bool { node == nil }
}

/// Immutable after init (tiles are only appended during layout) ⇒ safe to share.
final class TreemapGeometry: @unchecked Sendable {
    static let defaultMaxDepth = 3
    static let minTileArea: CGFloat = 36       // 6 × 6 pt
    static let headerHeight: CGFloat = 16
    static let padding: CGFloat = 2

    let focus: FileTreeNode
    let measure: SizeMeasure
    let size: CGSize
    let maxDepth: Int
    private(set) var tiles: [TreemapTile] = []
    let total: UInt64
    let identity = UUID()

    let colorMode: ColorMode

    init(focus: FileTreeNode, measure: SizeMeasure, size: CGSize, colorMode: ColorMode = .category,
         maxDepth: Int = TreemapGeometry.defaultMaxDepth) {
        self.focus = focus
        self.measure = measure
        self.colorMode = colorMode
        self.size = size
        self.maxDepth = maxDepth
        self.total = VisualizerMath.value(focus, measure)
        tiles.reserveCapacity(1024)
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        if bounds.width > 4 && bounds.height > 4 {
            layoutChildren(of: focus, in: bounds, depth: 1, parent: -1)
        }
    }

    private func layoutChildren(of node: FileTreeNode, in rect: CGRect, depth: Int, parent: Int) {
        let parentValue = VisualizerMath.value(node, measure)
        guard parentValue > 0, node.hasChildren, rect.width > 2, rect.height > 2 else { return }
        let area = rect.width * rect.height
        let scale = Double(area) / Double(parentValue)

        // Collect kept items; aggregate the tail below the LoD threshold.
        var items: [(node: FileTreeNode?, value: UInt64, count: Int)] = []
        var aggregateValue: UInt64 = 0
        var aggregateCount = 0
        let children = VisualizerMath.sortedChildren(node, measure)
        for (position, child) in children.enumerated() {
            let v = VisualizerMath.value(child, measure)
            if v == 0 { continue }
            if CGFloat(Double(v) * scale) < Self.minTileArea {
                for rest in children[position...] {
                    let rv = VisualizerMath.value(rest, measure)
                    if rv > 0 { aggregateValue &+= rv; aggregateCount += 1 }
                }
                break
            }
            items.append((child, v, 0))
        }
        if aggregateCount > 0 {
            items.append((nil, aggregateValue, aggregateCount))
        }
        guard !items.isEmpty else { return }

        let rects = Self.squarify(values: items.map { Double($0.value) * scale }, in: rect)
        for (sibling, (item, itemRect)) in zip(items, rects).enumerated() {
            guard itemRect.width >= 1, itemRect.height >= 1 else { continue }
            let color: Color
            if let child = item.node {
                color = VisualizerPalette.color(for: child, depth: 1, siblingIndex: sibling, mode: colorMode)
            } else {
                color = VisualizerPalette.aggregate
            }
            let index = tiles.count
            tiles.append(TreemapTile(node: item.node, rect: itemRect, depth: depth, color: color,
                                     value: item.value, aggregateCount: item.count, parent: parent, isContainer: false))
            if let child = item.node, child.isDirectory, child.hasChildren, depth < maxDepth,
               itemRect.width > 44, itemRect.height > 36 {
                let header = itemRect.height > 56 && itemRect.width > 70 ? Self.headerHeight : 0
                let inner = CGRect(
                    x: itemRect.minX + Self.padding,
                    y: itemRect.minY + Self.padding + header,
                    width: itemRect.width - Self.padding * 2,
                    height: itemRect.height - Self.padding * 2 - header
                )
                // Compact single-folder chains (e.g. Foo.app/Contents) so nesting
                // depth is spent on content that actually varies.
                var content = child
                while content.children.count == 1, let only = content.children.first, only.isDirectory, only.hasChildren {
                    content = only
                }
                let before = tiles.count
                layoutChildren(of: content, in: inner, depth: depth + 1, parent: index)
                if tiles.count > before { tiles[index].isContainer = true }
            }
        }
    }

    // MARK: Squarify

    /// Lays out `values` (already scaled to areas, sorted descending) in `rect`.
    static func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        result.reserveCapacity(values.count)
        var remaining = rect
        var row: [Double] = []
        var index = 0

        func worst(_ row: [Double], _ side: Double) -> Double {
            guard let maxV = row.max(), let minV = row.min(), minV > 0 else { return .infinity }
            let sum = row.reduce(0, +)
            let s2 = sum * sum
            let w2 = side * side
            return max(w2 * maxV / s2, s2 / (w2 * minV))
        }

        func layout(_ row: [Double]) {
            let sum = row.reduce(0, +)
            guard sum > 0 else { return }
            if remaining.width >= remaining.height {
                let width = sum / Double(max(remaining.height, 0.0001))
                var y = Double(remaining.minY)
                for v in row {
                    let h = v / width
                    result.append(CGRect(x: Double(remaining.minX), y: y, width: width, height: h))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + CGFloat(width), y: remaining.minY,
                                   width: max(0, remaining.width - CGFloat(width)), height: remaining.height)
            } else {
                let height = sum / Double(max(remaining.width, 0.0001))
                var x = Double(remaining.minX)
                for v in row {
                    let w = v / height
                    result.append(CGRect(x: x, y: Double(remaining.minY), width: w, height: height))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + CGFloat(height),
                                   width: remaining.width, height: max(0, remaining.height - CGFloat(height)))
            }
        }

        while index < values.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = row + [values[index]]
            if row.isEmpty || worst(candidate, side) <= worst(row, side) {
                row = candidate
                index += 1
            } else {
                layout(row)
                row = []
            }
        }
        if !row.isEmpty { layout(row) }
        return result
    }

    // MARK: Hit testing

    func hitTest(_ point: CGPoint) -> Int? {
        for index in tiles.indices.reversed() where tiles[index].rect.contains(point) {
            return index
        }
        return nil
    }

    func index(of node: FileTreeNode) -> Int? {
        tiles.firstIndex { $0.node === node }
    }

    // MARK: Drawing

    func draw(in context: inout GraphicsContext, transform: CGAffineTransform) {
        let identity = transform.isIdentity
        for tile in tiles {
            let rect = tile.rect.applying(transform)
            if rect.width < 0.5 || rect.height < 0.5 { continue }
            let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: min(4, rect.width / 4, rect.height / 4), style: .continuous)
            if tile.isContainer {
                context.fill(path, with: .color(tile.color.opacity(0.18)))
                context.stroke(path, with: .color(tile.color.opacity(0.6)), lineWidth: 1)
            } else if tile.isAggregate {
                context.fill(path, with: .color(VisualizerPalette.aggregate))
                context.stroke(path, with: .color(VisualizerPalette.aggregateStroke), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            } else {
                context.fill(path, with: .color(tile.color))
                context.stroke(path, with: .color(VisualizerPalette.separator), lineWidth: 1)
            }
            guard identity else { continue }
            drawLabel(for: tile, rect: rect, in: &context)
        }
    }

    private func drawLabel(for tile: TreemapTile, rect: CGRect, in context: inout GraphicsContext) {
        if tile.isContainer {
            guard rect.width > 70, rect.height > 56, let node = tile.node else { return }
            let text = Text(node.name).font(.caption.weight(.semibold)).foregroundColor(.primary)
                + Text("  " + formatBytes(tile.value)).font(.caption).foregroundColor(.secondary)
            context.draw(text, in: CGRect(x: rect.minX + 6, y: rect.minY + 2, width: rect.width - 12, height: Self.headerHeight))
            return
        }
        guard rect.width > 64, rect.height > 30 else { return }
        let dark = tile.node.map { colorMode == .category && $0.category.prefersDarkLabel } ?? false
        let ink: Color = tile.isAggregate ? .secondary : (dark ? .black.opacity(0.85) : .white)
        let title = tile.node?.name ?? "\(tile.aggregateCount) smaller items"
        context.draw(Text(title).font(.caption.weight(.semibold)).foregroundColor(ink),
                     in: CGRect(x: rect.minX + 6, y: rect.minY + 4, width: rect.width - 12, height: 14))
        if rect.height > 44 {
            context.draw(Text(formatBytes(tile.value)).font(.caption2).foregroundColor(ink.opacity(0.8)),
                         in: CGRect(x: rect.minX + 6, y: rect.minY + 18, width: rect.width - 12, height: 13))
        }
    }
}
