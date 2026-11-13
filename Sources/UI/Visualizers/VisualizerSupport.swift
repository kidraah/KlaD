// VisualizerSupport.swift — shared geometry helpers

import SwiftUI
import KlaDModels

enum VisualizerMode: String, CaseIterable, Identifiable {
    case sunburst
    case treemap

    var id: String { rawValue }
    var title: String { self == .sunburst ? "Sunburst" : "Treemap" }
    var symbol: String { self == .sunburst ? "circle.circle" : "square.grid.3x3.square" }
}

enum VisualizerMath {
    /// Value used for sizing; hard-link duplicates contribute nothing.
    @inline(__always)
    static func value(_ node: FileTreeNode, _ measure: SizeMeasure) -> UInt64 {
        if node.flags.contains(.hardLinkDuplicate) { return 0 }
        return node.metrics.value(for: measure)
    }

    /// Children sorted by `measure` descending (the tree is pre-sorted by allocated).
    static func sortedChildren(_ node: FileTreeNode, _ measure: SizeMeasure) -> [FileTreeNode] {
        if measure == .allocated { return node.children }
        return node.children.sorted { value($0, measure) > value($1, measure) }
    }
}

enum VisualizerPalette {
    /// System color for a node: category (or age bucket) shaded by ring depth via
    /// opacity, so it adapts to light/dark/increased-contrast automatically.
    static func color(for node: FileTreeNode, depth: Int, siblingIndex: Int) -> Color {
        if node.isOpaque || node.isProtectedLocation { return Color(nsColor: .systemGray).opacity(node.isOpaque ? 0.55 : 0.4) }
        let base = node.category.color
        var opacity = max(0.5, 1.0 - Double(max(depth - 1, 0)) * 0.11)
        if node.kind != .directory { opacity *= 0.82 }
        if siblingIndex % 2 == 1 { opacity *= 0.9 }
        if node.flags.contains(.cloudPlaceholder) { opacity *= 0.5 }
        return base.opacity(opacity)
    }

    /// Heat-map tile: solid category color, darker for smaller siblings.
    static func tileColor(for node: FileTreeNode, share: Double) -> Color {
        if node.isOpaque || node.isProtectedLocation { return Color(nsColor: .systemGray).opacity(0.55) }
        let opacity = 0.5 + 0.5 * min(1, max(0, share)).squareRoot()
        return node.category.color.opacity(node.flags.contains(.cloudPlaceholder) ? opacity * 0.5 : opacity)
    }

    /// Section header strip (adapts to light/dark).
    static let sectionHeader = Color.primary.opacity(0.14)

    static let aggregate = Color(nsColor: .tertiaryLabelColor).opacity(0.35)
    static let aggregateStroke = Color(nsColor: .separatorColor)
    static let separator = Color(nsColor: .windowBackgroundColor)
}
