// TreemapCanvasView.swift — squarified treemap with zoom transitions

import SwiftUI
import KlaDModels

struct TreemapCanvasView: View {
    @Environment(AppState.self) private var app

    @State private var geometry: TreemapGeometry?
    @State private var hovered: Int?
    @State private var transition = ZoomTransition<AffineBox>(from: AffineBox(.identity), start: .distantPast)

    private struct Key: Equatable {
        let focus: ObjectIdentifier?
        let measure: SizeMeasure
        let version: Int
        let width: Int
        let height: Int
    }

    var body: some View {
        GeometryReader { proxy in
            let key = Key(focus: app.focus.map(ObjectIdentifier.init), measure: app.measure, version: app.treeVersion,
                          width: Int(proxy.size.width), height: Int(proxy.size.height))
            ZStack(alignment: .topLeading) {
                if let geometry {
                    TreemapBaseLayer(geometry: geometry, transition: transition)
                        .equatable()
                    TreemapOverlayLayer(
                        geometry: geometry,
                        hovered: hovered,
                        selected: app.selection.flatMap { geometry.index(of: $0) }
                    )
                    .allowsHitTesting(false)
                    if let hovered, hovered < geometry.tiles.count {
                        HoverCard(tile: geometry.tiles[hovered], total: geometry.total)
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let hit = geometry?.hitTest(point)
                    if hit != hovered { hovered = hit }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { _ in app.drillUp() }
            .onTapGesture(coordinateSpace: .local) { point in handleTap(point) }
            .contextMenu { contextMenu }
            .onAppear { rebuild(key: key, size: proxy.size, animated: false) }
            .onChange(of: key) { old, new in
                let resizedOnly = old.focus == new.focus && old.measure == new.measure && old.version == new.version
                rebuild(key: new, size: proxy.size, animated: !resizedOnly)
            }
        }
    }

    private func handleTap(_ point: CGPoint) {
        guard let geometry, let index = geometry.hitTest(point) else { return }
        let tile = geometry.tiles[index]
        if let node = tile.node {
            if node.isDirectory && node.hasChildren { app.drill(into: node) } else { app.select(node) }
        } else if tile.parent >= 0, let parent = geometry.tiles[tile.parent].node {
            app.drill(into: parent)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let geometry, let hovered, hovered < geometry.tiles.count, let node = geometry.tiles[hovered].node {
            Button("Reveal in Finder") { SystemActions.reveal(node.path) }
            Button("Copy Path") { SystemActions.copy(node.path) }
            if node.isDirectory && node.hasChildren {
                Button("Zoom Into \(node.name)") { app.drill(into: node) }
            }
            if app.canTrash(node) {
                Divider()
                Button("Move to Trash…") { app.requestCleanup(node: node) }
            }
        }
        if app.focus?.parent != nil {
            Divider()
            Button("Zoom Out") { app.drillUp() }
        }
    }

    private func rebuild(key: Key, size: CGSize, animated: Bool) {
        guard let focus = app.focus, size.width > 8, size.height > 8 else {
            geometry = nil
            return
        }
        let old = geometry
        let new = TreemapGeometry(focus: focus, measure: app.measure, size: size)
        var from = CGAffineTransform.identity
        let bounds = CGRect(origin: .zero, size: size)
        if animated, let old, old.focus !== focus, old.measure == new.measure {
            if let index = old.index(of: focus) {
                // Drill down: the full-size layout starts inside the tile it came from.
                from = Self.transform(mapping: bounds, to: old.tiles[index].rect)
            } else if let index = new.index(of: old.focus) {
                // Drill up: start zoomed into where the old focus now sits.
                from = Self.transform(mapping: new.tiles[index].rect, to: bounds)
            }
        }
        geometry = new
        hovered = nil
        transition = ZoomTransition(from: AffineBox(from), start: from.isIdentity ? .distantPast : Date())
    }

    static func transform(mapping source: CGRect, to target: CGRect) -> CGAffineTransform {
        guard source.width > 0, source.height > 0 else { return .identity }
        let sx = target.width / source.width
        let sy = target.height / source.height
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                 tx: target.minX - source.minX * sx,
                                 ty: target.minY - source.minY * sy)
    }
}

/// Equatable wrapper for CGAffineTransform interpolation.
struct AffineBox: Equatable, Sendable {
    var t: CGAffineTransform
    init(_ t: CGAffineTransform) { self.t = t }

    func interpolated(_ p: Double) -> CGAffineTransform {
        let q = CGFloat(p)
        return CGAffineTransform(
            a: t.a + (1 - t.a) * q, b: t.b * (1 - q), c: t.c * (1 - q), d: t.d + (1 - t.d) * q,
            tx: t.tx * (1 - q), ty: t.ty * (1 - q)
        )
    }
}

private struct TreemapBaseLayer: View, Equatable {
    let geometry: TreemapGeometry
    let transition: ZoomTransition<AffineBox>

    nonisolated static func == (lhs: TreemapBaseLayer, rhs: TreemapBaseLayer) -> Bool {
        lhs.geometry === rhs.geometry && lhs.transition == rhs.transition
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !transition.isRunning(at: Date()))) { timeline in
            let p = transition.progress(at: timeline.date)
            Canvas { context, size in
                context.clip(to: Path(CGRect(origin: .zero, size: size)))
                geometry.draw(in: &context, transform: transition.from.interpolated(p))
            }
        }
    }
}

private struct TreemapOverlayLayer: View {
    let geometry: TreemapGeometry
    let hovered: Int?
    let selected: Int?

    var body: some View {
        Canvas { context, _ in
            if let hovered, hovered < geometry.tiles.count {
                let rect = geometry.tiles[hovered].rect
                let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3)
                context.fill(path, with: .color(Color.white.opacity(0.14)))
                context.stroke(path, with: .color(Color.white.opacity(0.9)), lineWidth: 1.5)
                var parent = geometry.tiles[hovered].parent
                while parent >= 0 {
                    let r = geometry.tiles[parent].rect
                    context.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3),
                                   with: .color(Color.white.opacity(0.35)), lineWidth: 1)
                    parent = geometry.tiles[parent].parent
                }
            }
            if let selected, selected < geometry.tiles.count {
                let rect = geometry.tiles[selected].rect
                context.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 3),
                               with: .color(Theme.accent), lineWidth: 2)
            }
        }
    }
}

private struct HoverCard: View {
    let tile: TreemapTile
    let total: UInt64

    var body: some View {
        HStack(spacing: 8) {
            if let node = tile.node { CategoryDot(category: node.category) }
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.node?.name ?? "\(tile.aggregateCount) smaller items")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(formatBytes(tile.value)) · \(String(format: "%.1f%%", Double(tile.value) / Double(max(total, 1)) * 100))")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassPanel(radius: 8, fill: Theme.panelRaised)
    }
}
