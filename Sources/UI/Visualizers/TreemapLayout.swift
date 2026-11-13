// TreemapLayout.swift — heat-map style treemap.
//
// Two levels: every child of the focus is a SECTION (a block with a header
// strip, like a market sector), filled with solid TILES for its own children.
// Tiles carry large, bold, centered labels and the item's icon, scaled to the
// tile. Squarified layout (Bruls, Huizing & van Wijk); anything that would be
// smaller than `minTileArea` (and every smaller sibling after it) is merged
// into one "N smaller items" tile. Tiles are stored parents-first, so the
// deepest tile under the cursor is found by a reverse scan.

import AppKit
import CoreGraphics
import SwiftUI
import KlaDModels

struct TreemapTile {
    let node: FileTreeNode?        // nil ⇒ aggregate
    let rect: CGRect
    let depth: Int                 // 1 = section, 2 = tile inside a section
    let color: Color
    let value: UInt64
    let aggregateCount: Int
    let parent: Int
    /// A section drawn as a header strip + nested tiles.
    var isContainer: Bool

    var isAggregate: Bool { node == nil }
}

/// Immutable after init (tiles are only appended during layout) ⇒ safe to share.
final class TreemapGeometry: @unchecked Sendable {
    static let defaultMaxDepth = 2
    static let minTileArea: CGFloat = 36       // 6 × 6 pt
    static let headerHeight: CGFloat = 20
    static let gap: CGFloat = 1.5

    let focus: FileTreeNode
    let measure: SizeMeasure
    let size: CGSize
    let maxDepth: Int
    private(set) var tiles: [TreemapTile] = []
    /// Icons for tiles large enough to show one (filled on the MainActor).
    var icons: [Int: Image] = [:]
    let total: UInt64
    let identity = UUID()

    init(focus: FileTreeNode, measure: SizeMeasure, size: CGSize, maxDepth: Int = TreemapGeometry.defaultMaxDepth) {
        self.focus = focus
        self.measure = measure
        self.size = size
        self.maxDepth = maxDepth
        self.total = VisualizerMath.value(focus, measure)
        tiles.reserveCapacity(512)
        let bounds = CGRect(origin: .zero, size: size)
        if bounds.width > 4 && bounds.height > 4 {
            layoutChildren(of: focus, in: bounds, depth: 1, parent: -1)
        }
    }

    private func layoutChildren(of node: FileTreeNode, in rect: CGRect, depth: Int, parent: Int) {
        let parentValue = VisualizerMath.value(node, measure)
        guard parentValue > 0, node.hasChildren, rect.width > 2, rect.height > 2 else { return }
        let scale = Double(rect.width * rect.height) / Double(parentValue)

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
        if aggregateCount > 0 { items.append((nil, aggregateValue, aggregateCount)) }
        guard !items.isEmpty else { return }
        let largest = Double(items.map(\.value).max() ?? 1)

        let rects = Self.squarify(values: items.map { Double($0.value) * scale }, in: rect)
        for (item, itemRect) in zip(items, rects) {
            guard itemRect.width >= 1, itemRect.height >= 1 else { continue }
            let color: Color
            if let child = item.node {
                color = VisualizerPalette.tileColor(for: child, share: Double(item.value) / largest)
            } else {
                color = VisualizerPalette.aggregate
            }
            let index = tiles.count
            tiles.append(TreemapTile(node: item.node, rect: itemRect, depth: depth, color: color,
                                     value: item.value, aggregateCount: item.count, parent: parent, isContainer: false))
            // Sections: a header strip, then their own children as tiles.
            if let child = item.node, child.isDirectory, child.hasChildren, !child.isProtectedLocation,
               depth < maxDepth, itemRect.width > 64, itemRect.height > 52 {
                var content = child
                while content.children.count == 1, let only = content.children.first, only.isDirectory, only.hasChildren {
                    content = only   // Foo.app/Contents → its contents
                }
                let inner = CGRect(x: itemRect.minX, y: itemRect.minY + Self.headerHeight,
                                   width: itemRect.width, height: itemRect.height - Self.headerHeight)
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

    /// Indices of tiles big enough to carry an icon.
    var iconCandidates: [Int] {
        tiles.indices.filter { index in
            let tile = tiles[index]
            return !tile.isContainer && tile.node != nil && tile.rect.width >= 64 && tile.rect.height >= 72
        }
    }

    // MARK: Drawing

    func draw(in context: inout GraphicsContext, transform: CGAffineTransform) {
        let identity = transform.isIdentity
        let inset = Self.gap / 2
        for (index, tile) in tiles.enumerated() {
            let rect = tile.rect.applying(transform).insetBy(dx: inset, dy: inset)
            if rect.width < 0.5 || rect.height < 0.5 { continue }
            if tile.isContainer {
                // Section header strip; its tiles paint the body.
                let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                                    height: min(Self.headerHeight * (rect.height / max(tile.rect.height, 1)), rect.height) - inset)
                context.fill(Path(header), with: .color(VisualizerPalette.sectionHeader))
                if identity { drawHeader(for: tile, rect: header, in: &context) }
                continue
            }
            context.fill(Path(rect), with: .color(tile.isAggregate ? VisualizerPalette.aggregate : tile.color))
            if identity { drawLabel(index: index, tile: tile, rect: rect, in: &context) }
        }
    }

    private func drawHeader(for tile: TreemapTile, rect: CGRect, in context: inout GraphicsContext) {
        guard let node = tile.node, rect.width > 40 else { return }
        let text = Text(node.name + " ›").font(.system(size: 11, weight: .semibold)).foregroundColor(.primary)
            + Text("  " + formatBytes(tile.value)).font(.system(size: 11)).foregroundColor(.secondary)
        context.draw(text, in: CGRect(x: rect.minX + 6, y: rect.minY + 3, width: rect.width - 12, height: rect.height - 3))
    }

    private func drawLabel(index: Int, tile: TreemapTile, rect: CGRect, in context: inout GraphicsContext) {
        guard rect.width >= 40, rect.height >= 26 else { return }
        let dark = tile.node.map { $0.category.prefersDarkLabel } ?? false
        let ink: Color = tile.isAggregate ? .white.opacity(0.75) : (dark ? .black.opacity(0.85) : .white)
        let side = min(rect.width, rect.height)
        let titleSize = min(max(min(rect.width * 0.12, rect.height * 0.24), 10), 34)
        let name = tile.node?.name ?? "\(tile.aggregateCount) smaller"
        let maxWidth = rect.width - 8

        // Shrink the title until it fits on one line (or give up below 10 pt).
        var size = titleSize
        var resolvedTitle = context.resolve(Text(name).font(.system(size: size, weight: .bold)).foregroundColor(ink))
        var titleBox = resolvedTitle.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        while titleBox.width > maxWidth && size > 10 {
            size -= 1
            resolvedTitle = context.resolve(Text(name).font(.system(size: size, weight: .bold)).foregroundColor(ink))
            titleBox = resolvedTitle.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        }
        if titleBox.width > maxWidth {
            // Still too wide: truncate the text itself.
            let keep = max(1, Int(Double(name.count) * Double(maxWidth / titleBox.width)) - 1)
            resolvedTitle = context.resolve(Text(String(name.prefix(keep)) + "…").font(.system(size: size, weight: .bold)).foregroundColor(ink))
            titleBox = resolvedTitle.measure(in: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
        }
        let valueText = context.resolve(Text(formatBytes(tile.value)).font(.system(size: max(9, size * 0.68), weight: .semibold))
            .foregroundColor(ink.opacity(0.85)))
        let valueBox = valueText.measure(in: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
        let showValue = rect.height >= titleBox.height + valueBox.height + 6

        let icon = icons[index]
        let iconSide = min(side * 0.34, 72)
        let showIcon = icon != nil && rect.height >= titleBox.height + (showValue ? valueBox.height : 0) + iconSide + 14
        let blockHeight = titleBox.height + (showValue ? valueBox.height + 1 : 0) + (showIcon ? iconSide + 6 : 0)
        var y = rect.midY - blockHeight / 2
        if showIcon, let icon {
            context.draw(icon, in: CGRect(x: rect.midX - iconSide / 2, y: y, width: iconSide, height: iconSide))
            y += iconSide + 6
        }
        context.draw(resolvedTitle, at: CGPoint(x: rect.midX, y: y), anchor: .top)
        y += titleBox.height + 1
        if showValue {
            context.draw(valueText, at: CGPoint(x: rect.midX, y: y), anchor: .top)
        }
    }
}
