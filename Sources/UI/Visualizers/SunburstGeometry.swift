// SunburstGeometry.swift — LOD-culled polar layout
//
// Built once per (focus node, measure, tree version) — independent of view
// size, so window resizes never re-layout. At most `maxRings` rings below the
// focus; any child spanning < `minAngle` radians (and every smaller sibling
// after it — children are size-sorted) is merged into ONE "Other / Smaller
// Items" arc per parent. Segments are stored ring by ring in angular order,
// so hit-testing is a ring lookup + binary search: O(log n) per mouse move.

import Foundation
import SwiftUI
import KlaDModels

struct SunburstSegment {
    /// nil ⇒ aggregated "Other / Smaller Items".
    let node: FileTreeNode?
    /// 1-based ring index below the focus.
    let ring: Int
    /// Radians, clockwise from 12 o'clock.
    let start: Double
    let end: Double
    let color: Color
    let value: UInt64
    let aggregateCount: Int
    /// Index of the parent segment (-1 for ring 1 ⇒ the focus).
    let parent: Int
    /// Has children that are deeper than the visible rings.
    let hasHiddenChildren: Bool

    var isAggregate: Bool { node == nil }
    var span: Double { end - start }
    var midAngle: Double { (start + end) / 2 }
}

/// Maps a geometry's polar coordinates during zoom transitions:
/// θ' = (θ − pivot) · scale + offset, ring' = ring + ringShift.
struct PolarTransform: Equatable, Sendable {
    var scale: Double = 1
    var pivot: Double = 0
    var offset: Double = 0
    var ringShift: Double = 0

    static let identity = PolarTransform()

    func interpolated(to target: PolarTransform, _ t: Double) -> PolarTransform {
        PolarTransform(
            scale: scale + (target.scale - scale) * t,
            pivot: pivot + (target.pivot - pivot) * t,
            offset: offset + (target.offset - offset) * t,
            ringShift: ringShift + (target.ringShift - ringShift) * t
        )
    }

    @inline(__always) func angle(_ theta: Double) -> Double { (theta - pivot) * scale + offset }
}

struct SunburstMetrics {
    let center: CGPoint
    let radius: CGFloat
    let holeRadius: CGFloat
    let ringWidth: CGFloat
}

/// Immutable after init ⇒ safe to share.
final class SunburstGeometry: @unchecked Sendable {
    static let defaultMaxRings = 5
    static let defaultMinAngle = 0.008   // ≈ 0.46°

    let focus: FileTreeNode
    let measure: SizeMeasure
    let maxRings: Int
    let segments: [SunburstSegment]
    let ringRanges: [Range<Int>]          // ringRanges[ring - 1]
    let total: UInt64
    let identity = UUID()

    init(focus: FileTreeNode, measure: SizeMeasure,
         maxRings: Int = SunburstGeometry.defaultMaxRings,
         minAngle: Double = SunburstGeometry.defaultMinAngle) {
        self.focus = focus
        self.measure = measure
        self.maxRings = maxRings
        let total = VisualizerMath.value(focus, measure)
        self.total = total

        var segments: [SunburstSegment] = []
        var ranges: [Range<Int>] = []
        segments.reserveCapacity(1024)

        struct FrontierItem { let node: FileTreeNode; let start: Double; let end: Double; let index: Int }
        var frontier = [FrontierItem(node: focus, start: 0, end: 2 * .pi, index: -1)]

        for ring in 1...maxRings {
            let ringStart = segments.count
            var next: [FrontierItem] = []
            for item in frontier {
                let parentValue = VisualizerMath.value(item.node, measure)
                guard item.node.isDirectory, parentValue > 0, !item.node.children.isEmpty else { continue }
                let span = item.end - item.start
                let scale = span / Double(parentValue)
                let children = VisualizerMath.sortedChildren(item.node, measure)
                var cumulative: UInt64 = 0
                var aggregateValue: UInt64 = 0
                var aggregateCount = 0
                var sibling = 0
                for (position, child) in children.enumerated() {
                    let v = VisualizerMath.value(child, measure)
                    if v == 0 { continue }
                    let width = Double(v) * scale
                    if width < minAngle {
                        // Sorted descending ⇒ everything that follows is smaller too.
                        for rest in children[position...] {
                            let rv = VisualizerMath.value(rest, measure)
                            if rv > 0 { aggregateValue &+= rv; aggregateCount += 1 }
                        }
                        break
                    }
                    let a0 = item.start + Double(cumulative) * scale
                    cumulative &+= v
                    let a1 = item.start + Double(cumulative) * scale
                    let index = segments.count
                    segments.append(SunburstSegment(
                        node: child,
                        ring: ring,
                        start: a0,
                        end: a1,
                        color: VisualizerPalette.color(for: child, depth: ring, siblingIndex: sibling),
                        value: v,
                        aggregateCount: 0,
                        parent: item.index,
                        hasHiddenChildren: ring == maxRings && child.isDirectory && !child.children.isEmpty
                    ))
                    sibling += 1
                    if child.isDirectory && ring < maxRings {
                        next.append(FrontierItem(node: child, start: a0, end: a1, index: index))
                    }
                }
                if aggregateCount > 0 {
                    let a0 = item.start + Double(cumulative) * scale
                    let a1 = min(item.end, a0 + Double(aggregateValue) * scale)
                    if a1 - a0 > 0.0005 {
                        segments.append(SunburstSegment(
                            node: nil, ring: ring, start: a0, end: a1,
                            color: VisualizerPalette.aggregate, value: aggregateValue,
                            aggregateCount: aggregateCount, parent: item.index, hasHiddenChildren: false
                        ))
                    }
                }
            }
            ranges.append(ringStart..<segments.count)
            frontier = next
            if frontier.isEmpty {
                // Pad remaining rings with empty ranges.
                for _ in (ring + 1)..<(maxRings + 1) { ranges.append(segments.count..<segments.count) }
                break
            }
        }
        self.segments = segments
        self.ringRanges = ranges
    }

    // MARK: Layout

    func metrics(in size: CGSize) -> SunburstMetrics {
        let radius = max(10, min(size.width, size.height) / 2 - 14)
        let hole = radius * 0.24
        return SunburstMetrics(
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            radius: radius,
            holeRadius: hole,
            ringWidth: (radius - hole) / CGFloat(maxRings)
        )
    }

    // MARK: Hit testing

    enum Hit: Equatable {
        case center
        case segment(Int)
    }

    func hitTest(_ point: CGPoint, size: CGSize) -> Hit? {
        let m = metrics(in: size)
        let dx = Double(point.x - m.center.x)
        let dy = Double(point.y - m.center.y)
        let r = (dx * dx + dy * dy).squareRoot()
        if r < Double(m.holeRadius) { return .center }
        let ring = Int((r - Double(m.holeRadius)) / Double(m.ringWidth)) + 1
        guard ring >= 1, ring <= maxRings, ring - 1 < ringRanges.count else { return nil }
        var theta = atan2(dx, -dy)
        if theta < 0 { theta += 2 * .pi }
        let range = ringRanges[ring - 1]
        var lo = range.lowerBound
        var hi = range.upperBound - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = segments[mid]
            if theta < s.start { hi = mid - 1 }
            else if theta >= s.end { lo = mid + 1 }
            else { return .segment(mid) }
        }
        return nil
    }

    /// Segment index for a node, if visible.
    func index(of node: FileTreeNode) -> Int? {
        segments.firstIndex { $0.node === node }
    }

    /// Chain of segment indices from ring 1 down to `index`.
    func ancestry(of index: Int) -> [Int] {
        var chain: [Int] = []
        var cursor = index
        while cursor >= 0 {
            chain.append(cursor)
            cursor = segments[cursor].parent
        }
        return chain.reversed()
    }

    // MARK: Drawing

    /// Annular sector path. Angles are clockwise from 12 o'clock.
    static func sectorPath(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        var path = Path()
        let a0 = Angle(radians: start - .pi / 2)
        let a1 = Angle(radians: end - .pi / 2)
        path.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: max(inner, 0.1), startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Draws all segments under `transform`, clipped to the visible disc.
    func draw(in context: inout GraphicsContext, size: CGSize, transform: PolarTransform, separator: Color) {
        let m = metrics(in: size)
        let fullCircle = 2 * Double.pi
        for segment in segments {
            var s = transform.angle(segment.start)
            var e = transform.angle(segment.end)
            if e <= 0 || s >= fullCircle { continue }
            s = max(s, 0)
            e = min(e, fullCircle)
            if e - s < 0.0004 { continue }
            let ring = Double(segment.ring) + transform.ringShift
            var inner = m.holeRadius + CGFloat(ring - 1) * m.ringWidth
            var outer = m.holeRadius + CGFloat(ring) * m.ringWidth
            if outer <= m.holeRadius || inner >= m.radius { continue }
            inner = max(inner, m.holeRadius)
            outer = min(outer, m.radius)
            let gap: CGFloat = 1.0
            let path = Self.sectorPath(center: m.center, inner: inner + gap * 0.5, outer: outer - gap * 0.5, start: s, end: e)
            context.fill(path, with: .color(segment.color))
            if segment.isAggregate {
                context.stroke(path, with: .color(VisualizerPalette.aggregateStroke), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            } else if e - s > 0.004 {
                context.stroke(path, with: .color(separator), lineWidth: 0.75)
            }
            if segment.hasHiddenChildren && e - s > 0.02 && transform == .identity {
                // Outer tick: "more inside".
                let tick = Self.sectorPath(center: m.center, inner: outer - 2, outer: outer + 1.5, start: s + 0.004, end: e - 0.004)
                context.fill(tick, with: .color(Color.white.opacity(0.22)))
            }
        }
    }
}
