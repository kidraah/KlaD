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

/// RGB triple with cheap lighten/darken (Color.mix is macOS 15+).
struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func lightened(_ t: Double) -> RGB { mixed(with: RGB(r: 1, g: 1, b: 1), t) }
    func darkened(_ t: Double) -> RGB { mixed(with: RGB(r: 0.02, g: 0.03, b: 0.06), t) }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

enum VisualizerPalette {
    /// Category color shaded by depth (deeper = slightly lighter & calmer) and
    /// alternated by sibling parity so adjacent same-category items separate.
    static func color(for node: FileTreeNode, depth: Int, siblingIndex: Int) -> Color {
        var rgb = RGB(hex: node.category.hexColor)
        if node.kind != .directory {
            rgb = rgb.darkened(0.18)
        }
        rgb = rgb.lightened(min(0.30, Double(max(depth - 1, 0)) * 0.07))
        if siblingIndex % 2 == 1 { rgb = rgb.darkened(0.10) }
        if node.flags.contains(.cloudPlaceholder) { rgb = rgb.mixed(with: RGB(hex: 0x64748B), 0.55) }
        return rgb.color
    }

    static let aggregate = RGB(hex: 0x334155).color
    static let aggregateStroke = Color.white.opacity(0.10)
}
