// SunburstCanvasView.swift — LoD sunburst with polar zoom transitions
//
// • Geometry is cached per (focus, measure, tree version); resizing only
//   re-derives radii at draw time.
// • The base layer is an Equatable view: hover state lives in a separate
//   overlay Canvas, so pointer movement never redraws thousands of arcs.
// • Drill-down / drill-up animate with a PolarTransform interpolated on a
//   TimelineView clock (only ticking while a transition runs).

import SwiftUI
import KlaDModels

struct SunburstCanvasView: View {
    @Environment(AppState.self) private var app

    @State private var geometry: SunburstGeometry?
    @State private var hovered: SunburstGeometry.Hit?
    @State private var transition = ZoomTransition<PolarTransform>(from: .identity, start: .distantPast)

    private struct Key: Equatable {
        let focus: ObjectIdentifier?
        let measure: SizeMeasure
        let version: Int
    }

    private var key: Key {
        Key(focus: app.focus.map(ObjectIdentifier.init), measure: app.measure, version: app.treeVersion)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let geometry {
                    SunburstBaseLayer(geometry: geometry, transition: transition)
                        .equatable()
                    SunburstOverlayLayer(
                        geometry: geometry,
                        hovered: hovered,
                        selectedIndex: app.selection.flatMap { geometry.index(of: $0) }
                    )
                    .allowsHitTesting(false)
                    centerLabel(geometry: geometry, size: proxy.size)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let hit = geometry?.hitTest(point, size: proxy.size)
                    if hit != hovered { hovered = hit }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                handleTap(at: point, size: proxy.size)
            }
            .contextMenu { contextMenu }
        }
        .onAppear { rebuild(animated: false) }
        .onChange(of: key) { _, _ in rebuild(animated: true) }
    }

    // MARK: Interaction

    private func node(for hit: SunburstGeometry.Hit?) -> FileTreeNode? {
        guard let geometry, let hit else { return nil }
        switch hit {
        case .center: return geometry.focus
        case .segment(let index): return geometry.segments[index].node
        }
    }

    private func handleTap(at point: CGPoint, size: CGSize) {
        guard let geometry, let hit = geometry.hitTest(point, size: size) else { return }
        switch hit {
        case .center:
            app.drillUp()
        case .segment(let index):
            let segment = geometry.segments[index]
            if let node = segment.node {
                if node.isDirectory && node.hasChildren { app.drill(into: node) } else { app.select(node) }
            } else if segment.parent >= 0, let parentNode = geometry.segments[segment.parent].node {
                app.select(parentNode)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let node = node(for: hovered) {
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

    // MARK: Geometry & transitions

    private func rebuild(animated: Bool) {
        guard let focus = app.focus else {
            geometry = nil
            return
        }
        let old = geometry
        let new = SunburstGeometry(focus: focus, measure: app.measure)
        var from = PolarTransform.identity
        if animated, let old, old.measure == new.measure, old.focus !== focus {
            if let index = old.index(of: focus) {
                // Drill down: the new focus grows from its old arc.
                let s = old.segments[index]
                from = PolarTransform(scale: s.span / (2 * .pi), pivot: 0, offset: s.start, ringShift: Double(s.ring))
            } else if let index = new.index(of: old.focus) {
                // Drill up: the old focus shrinks back into its arc.
                let s = new.segments[index]
                from = PolarTransform(scale: (2 * .pi) / max(s.span, 0.0001), pivot: s.start, offset: 0, ringShift: -Double(s.ring))
            }
        }
        geometry = new
        hovered = nil
        transition = ZoomTransition(from: from, start: from == .identity ? .distantPast : Date())
    }

    // MARK: Center readout

    @ViewBuilder
    private func centerLabel(geometry: SunburstGeometry, size: CGSize) -> some View {
        let m = geometry.metrics(in: size)
        let info = readout(geometry: geometry)
        VStack(spacing: 3) {
            if let category = info.category {
                CategoryDot(category: category, size: 7)
            }
            Text(info.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(info.value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(info.caption)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if info.isFocus && geometry.focus.parent != nil {
                Label("Click to zoom out", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .frame(width: m.holeRadius * 1.7)
        .position(m.center)
    }

    private struct Readout {
        var title: String
        var value: String
        var caption: String
        var category: StorageCategory?
        var isFocus: Bool
    }

    private func readout(geometry: SunburstGeometry) -> Readout {
        let total = max(geometry.total, 1)
        if case .segment(let index) = hovered {
            let segment = geometry.segments[index]
            let percent = Double(segment.value) / Double(total) * 100
            if let node = segment.node {
                var caption = String(format: "%.1f%% of %@", percent, geometry.focus.displayName)
                if node.isDirectory { caption += " · \(formatCount(UInt64(node.metrics.fileCount))) files" }
                return Readout(title: node.name, value: formatBytes(segment.value), caption: caption,
                               category: node.category, isFocus: false)
            }
            return Readout(title: "\(segment.aggregateCount) smaller items",
                           value: formatBytes(segment.value),
                           caption: String(format: "%.1f%% · merged for clarity", percent),
                           category: nil, isFocus: false)
        }
        let focus = geometry.focus
        return Readout(
            title: focus.displayName,
            value: formatBytes(geometry.total),
            caption: "\(app.measure.displayName) · \(formatCount(UInt64(focus.metrics.fileCount))) files",
            category: nil,
            isFocus: true
        )
    }
}

/// Clock-driven zoom transition state.
struct ZoomTransition<T: Equatable & Sendable>: Equatable, Sendable {
    var from: T
    var start: Date
    static var duration: TimeInterval { 0.55 }

    /// Eased progress 0…1 at `date`.
    func progress(at date: Date) -> Double {
        let raw = min(max(date.timeIntervalSince(start) / Self.duration, 0), 1)
        // easeInOutCubic
        return raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
    }

    func isRunning(at date: Date) -> Bool { date.timeIntervalSince(start) < Self.duration }
}

/// The expensive layer: all arcs. Re-evaluated only when geometry or the
/// transition changes (Equatable), never on hover.
private struct SunburstBaseLayer: View, Equatable {
    let geometry: SunburstGeometry
    let transition: ZoomTransition<PolarTransform>

    nonisolated static func == (lhs: SunburstBaseLayer, rhs: SunburstBaseLayer) -> Bool {
        lhs.geometry === rhs.geometry && lhs.transition == rhs.transition
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !transition.isRunning(at: Date()))) { timeline in
            let t = transition.progress(at: timeline.date)
            let transform = transition.from.interpolated(to: .identity, t)
            Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { context, size in
                geometry.draw(in: &context, size: size, transform: transform, separator: Theme.obsidian.opacity(0.9))
            }
        }
        .drawingGroup()
    }
}

/// Cheap overlay: hovered arc + ancestry + selection outline.
private struct SunburstOverlayLayer: View {
    let geometry: SunburstGeometry
    let hovered: SunburstGeometry.Hit?
    let selectedIndex: Int?

    var body: some View {
        Canvas { context, size in
            let m = geometry.metrics(in: size)
            func sector(_ index: Int, grow: CGFloat = 0) -> Path {
                let s = geometry.segments[index]
                let inner = m.holeRadius + CGFloat(s.ring - 1) * m.ringWidth + 0.5
                let outer = m.holeRadius + CGFloat(s.ring) * m.ringWidth - 0.5 + grow
                return SunburstGeometry.sectorPath(center: m.center, inner: inner, outer: outer, start: s.start, end: s.end)
            }
            if case .segment(let index) = hovered {
                for ancestor in geometry.ancestry(of: index).dropLast() {
                    context.fill(sector(ancestor), with: .color(Color.white.opacity(0.10)))
                }
                let path = sector(index, grow: 3)
                context.fill(path, with: .color(Color.white.opacity(0.22)))
                context.stroke(path, with: .color(Color.white.opacity(0.85)), lineWidth: 1.2)
            }
            if let selectedIndex {
                context.stroke(sector(selectedIndex), with: .color(Theme.accent), lineWidth: 2)
            }
            // Center disc.
            let hole = Path(ellipseIn: CGRect(x: m.center.x - m.holeRadius + 2, y: m.center.y - m.holeRadius + 2,
                                              width: (m.holeRadius - 2) * 2, height: (m.holeRadius - 2) * 2))
            context.fill(hole, with: .color(hovered == .center ? Color.white.opacity(0.07) : Color.white.opacity(0.025)))
            context.stroke(hole, with: .color(Theme.hairline), lineWidth: 1)
        }
    }
}
