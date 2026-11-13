// TreemapCanvasView.swift — squarified treemap with zoom transitions.

import SwiftUI
import KlaDModels

struct TreemapCanvasView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var geometry: TreemapGeometry?
    @State private var hovered: Int?
    @State private var animating = false
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
            let key = Key(focus: app.focus.map(ObjectIdentifier.init), measure: app.measure,
                          version: app.treeVersion, width: Int(proxy.size.width), height: Int(proxy.size.height))
            ZStack(alignment: .topLeading) {
                if let geometry {
                    TreemapBaseLayer(geometry: geometry, transition: transition, animating: animating)
                        .equatable()
                    TreemapOverlayLayer(geometry: geometry, hovered: hovered,
                                        selected: app.selection.flatMap { geometry.index(of: $0) })
                        .allowsHitTesting(false)
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
            .help(helpText)
            .onTapGesture(count: 2, coordinateSpace: .local) { _ in app.drillUp() }
            .onTapGesture(coordinateSpace: .local) { point in handleTap(point) }
            .contextMenu { contextMenu }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Treemap of \(app.focus?.displayName ?? "")")
            .onAppear { rebuild(size: proxy.size, animated: false) }
            .task(id: transition.start) {
                guard animating else { return }
                try? await Task.sleep(for: .seconds(ZoomTransition<AffineBox>.duration + 0.05))
                animating = false
            }
            .onChange(of: key) { old, new in
                let resizedOnly = old.focus == new.focus && old.measure == new.measure && old.version == new.version
                rebuild(size: proxy.size, animated: !resizedOnly && !reduceMotion)
            }
        }
    }

    private var helpText: String {
        guard let geometry, let hovered, hovered < geometry.tiles.count else { return "" }
        let tile = geometry.tiles[hovered]
        let name = tile.node?.name ?? "\(tile.aggregateCount) smaller items"
        let share = (Double(tile.value) / Double(max(geometry.total, 1))).formatted(.percent.precision(.fractionLength(1)))
        return "\(name) — \(formatBytes(tile.value)) (\(share))"
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
            NodeContextMenu(node: node)
        }
        if app.focus?.parent != nil {
            Divider()
            Button("Zoom Out") { app.drillUp() }
        }
    }

    private func rebuild(size: CGSize, animated: Bool) {
        guard let focus = app.focus, size.width > 8, size.height > 8 else {
            geometry = nil
            return
        }
        let old = geometry
        let new = TreemapGeometry(focus: focus, measure: app.measure, size: size)
        for index in new.iconCandidates.prefix(150) {
            if let node = new.tiles[index].node {
                new.icons[index] = Image(nsImage: FileIcons.icon(for: node))
            }
        }
        var from = CGAffineTransform.identity
        let bounds = CGRect(origin: .zero, size: size)
        if animated, let old, old.focus !== focus, old.measure == new.measure {
            if let index = old.index(of: focus) {
                from = Self.transform(mapping: bounds, to: old.tiles[index].rect)
            } else if let index = new.index(of: old.focus) {
                from = Self.transform(mapping: new.tiles[index].rect, to: bounds)
            }
        }
        geometry = new
        hovered = nil
        transition = ZoomTransition(from: AffineBox(from), start: from.isIdentity ? .distantPast : Date())
        animating = !from.isIdentity
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

struct AffineBox: Equatable, Sendable {
    var t: CGAffineTransform
    init(_ t: CGAffineTransform) { self.t = t }

    func interpolated(_ p: Double) -> CGAffineTransform {
        let q = CGFloat(p)
        return CGAffineTransform(a: t.a + (1 - t.a) * q, b: t.b * (1 - q), c: t.c * (1 - q), d: t.d + (1 - t.d) * q,
                                 tx: t.tx * (1 - q), ty: t.ty * (1 - q))
    }
}

private struct TreemapBaseLayer: View, Equatable {
    let geometry: TreemapGeometry
    let transition: ZoomTransition<AffineBox>
    /// The animation clock only ticks while a zoom is running.
    let animating: Bool

    nonisolated static func == (lhs: TreemapBaseLayer, rhs: TreemapBaseLayer) -> Bool {
        lhs.geometry === rhs.geometry && lhs.transition == rhs.transition && lhs.animating == rhs.animating
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { timeline in
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
                let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4, style: .continuous)
                context.fill(path, with: .color(Color.primary.opacity(0.12)))
                context.stroke(path, with: .color(Color.primary.opacity(0.8)), lineWidth: 1.5)
            }
            if let selected, selected < geometry.tiles.count {
                let rect = geometry.tiles[selected].rect
                context.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 4, style: .continuous),
                               with: .color(.accentColor), lineWidth: 2.5)
            }
        }
    }
}
