// VisualizerLayoutTests.swift — KlaDCoreTests
//
// Pure-geometry checks for the LoD sunburst and squarified treemap.

import CoreGraphics
import Foundation
import Testing
@testable import KlaD
@testable import KlaDModels

@MainActor
@Suite("Visualizer geometry")
struct VisualizerLayoutTests {
    /// Root with 3 big children and 2 000 tiny files.
    private func makeTree() -> FileTreeNode {
        var children: [FileTreeNode] = [
            .file("a", logical: 400 << 20),
            .file("b", logical: 300 << 20),
            .directory("c", children: (0..<50).map { .file("c\($0)", logical: 2 << 20) }),
        ]
        children += (0..<2_000).map { FileTreeNode.file("tiny\($0)", logical: 4096) }
        let root = FileTreeNode.directory("/r", children: children)
        root.recomputeAggregates()
        return root
    }

    @Test func squarifyConservesAreaAndStaysInBounds() {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 500)
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1].map { $0 / 24 * 400_000 }
        let rects = TreemapGeometry.squarify(values: values, in: rect)
        #expect(rects.count == values.count)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - 400_000) < 1)
        for r in rects { #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(r)) }
        // Squarified ⇒ reasonable aspect ratios for this classic input.
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 4)
    }

    @Test func sunburstAggregatesTinyArcsAndStaysBounded() {
        let root = makeTree()
        let geometry = SunburstGeometry(focus: root, measure: .allocated)
        let ring1 = geometry.segments[geometry.ringRanges[0]]
        // 3 real children + one aggregate for 2 000 tiny files.
        #expect(ring1.filter { !$0.isAggregate }.count == 3)
        let aggregate = ring1.first { $0.isAggregate }
        #expect(aggregate?.aggregateCount == 2_000)
        // Arcs tile the circle.
        #expect(abs((ring1.last?.end ?? 0) - 2 * .pi) < 1e-6)
        for segment in geometry.segments where !segment.isAggregate {
            #expect(segment.span >= SunburstGeometry.defaultMinAngle)
        }
        #expect(geometry.segments.count < 200)
    }

    @Test func sunburstHitTestingFindsSegments() {
        let root = makeTree()
        let geometry = SunburstGeometry(focus: root, measure: .allocated)
        let size = CGSize(width: 600, height: 600)
        let m = geometry.metrics(in: size)
        #expect(geometry.hitTest(m.center, size: size) == .center)
        // Just right of 12 o'clock in ring 1 ⇒ the first (largest) child, "a".
        let point = CGPoint(x: m.center.x + 2, y: m.center.y - (m.holeRadius + m.ringWidth * 0.5))
        guard case .segment(let index)? = geometry.hitTest(point, size: size) else {
            Issue.record("expected a segment hit")
            return
        }
        #expect(geometry.segments[index].node?.name == "a")
        #expect(geometry.hitTest(CGPoint(x: 0, y: 0), size: size) == nil)
    }

    @Test func treemapCullsSmallTilesIntoAggregate() {
        let root = makeTree()
        let geometry = TreemapGeometry(focus: root, measure: .allocated, size: CGSize(width: 400, height: 300))
        let topLevel = geometry.tiles.filter { $0.depth == 1 }
        #expect(topLevel.contains { $0.isAggregate && $0.aggregateCount >= 1_000 })
        for tile in geometry.tiles where !tile.isAggregate && tile.depth == 1 {
            #expect(tile.rect.width * tile.rect.height >= TreemapGeometry.minTileArea - 0.5)
        }
        // Deepest-tile hit test returns a nested tile inside "c".
        if let c = geometry.tiles.firstIndex(where: { $0.node?.name == "c" }), geometry.tiles[c].isContainer {
            let center = CGPoint(x: geometry.tiles[c].rect.midX, y: geometry.tiles[c].rect.maxY - 4)
            let hit = geometry.hitTest(center)
            #expect(hit != nil && geometry.tiles[hit!].depth == 2)
        }
    }
}
