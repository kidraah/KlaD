// SunburstCanvasView.swift — LoD sunburst with polar zoom transitions.
//
// • Geometry cached per (focus, measure, colour mode, tree version).
// • The arcs live in an Equatable base layer; hover is a separate overlay, so
//   pointer movement never redraws thousands of arcs.
// • Zoom transitions honour Reduce Motion.

import SwiftUI
import KlaDModels

struct SunburstCanvasView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var geometry: SunburstGeometry?
    @State private var hovered: SunburstGeometry.Hit?
    @State private var animating = false
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
                    SunburstBaseLayer(geometry: geometry, transition: transition, animating: animating)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sunburst chart of \(app.focus?.displayName ?? "")")
            .accessibilityValue(app.focus.map { formatBytes($0.metrics.value(for: app.measure)) } ?? "")
        }
        .onAppear { rebuild(animated: false) }
        .task(id: transition.start) {
            guard animating else { return }
            try? await Task.sleep(for: .seconds(ZoomTransition<PolarTransform>.duration + 0.05))
            animating = false
        }
        .onChange(of: key) { _, _ in rebuild(animated: !reduceMotion) }
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
            NodeContextMenu(node: node)
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
                let s = old.segments[index]
                from = PolarTransform(scale: s.span / (2 * .pi), pivot: 0, offset: s.start, ringShift: Double(s.ring))
            } else if let index = new.index(of: old.focus) {
                let s = new.segments[index]
                from = PolarTransform(scale: (2 * .pi) / max(s.span, 0.0001), pivot: s.start, offset: 0, ringShift: -Double(s.ring))
            }
        }
        geometry = new
        hovered = nil
        transition = ZoomTransition(from: from, start: from == .identity ? .distantPast : Date())
        animating = from != .identity
    }

    // MARK: Center readout

    @ViewBuilder
    private func centerLabel(geometry: SunburstGeometry, size: CGSize) -> some View {
        let m = geometry.metrics(in: size)
        let info = readout(geometry: geometry)
        VStack(spacing: 2) {
            Text(info.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(info.value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(info.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: m.holeRadius * 1.65)
        .position(m.center)
    }

    private struct Readout {
        var title: String
        var value: String
        var caption: String
    }

    private func readout(geometry: SunburstGeometry) -> Readout {
        let total = max(geometry.total, 1)
        if case .segment(let index) = hovered {
            let segment = geometry.segments[index]
            let percent = (Double(segment.value) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
            if let node = segment.node {
                return Readout(title: node.name, value: formatBytes(segment.value),
                               caption: "\(percent) of \(geometry.focus.displayName)")
            }
            return Readout(title: "\(segment.aggregateCount) Smaller Items", value: formatBytes(segment.value), caption: percent)
        }
        let focus = geometry.focus
        let caption = focus.parent == nil ? app.measure.displayName : "Click to go back"
        return Readout(title: focus.displayName, value: formatBytes(geometry.total), caption: caption)
    }
}

/// Clock-driven zoom transition state.
struct ZoomTransition<T: Equatable & Sendable>: Equatable, Sendable {
    var from: T
    var start: Date
    static var duration: TimeInterval { 0.45 }

    func progress(at date: Date) -> Double {
        let raw = min(max(date.timeIntervalSince(start) / Self.duration, 0), 1)
        return raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
    }

    func isRunning(at date: Date) -> Bool { date.timeIntervalSince(start) < Self.duration }
}

private struct SunburstBaseLayer: View, Equatable {
    let geometry: SunburstGeometry
    let transition: ZoomTransition<PolarTransform>
    /// The animation clock only ticks while a zoom is running.
    let animating: Bool

    nonisolated static func == (lhs: SunburstBaseLayer, rhs: SunburstBaseLayer) -> Bool {
        lhs.geometry === rhs.geometry && lhs.transition == rhs.transition && lhs.animating == rhs.animating
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { timeline in
            let t = transition.progress(at: timeline.date)
            let transform = transition.from.interpolated(to: .identity, t)
            Canvas { context, size in
                geometry.draw(in: &context, size: size, transform: transform, separator: VisualizerPalette.separator)
            }
        }
    }
}

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
                    context.fill(sector(ancestor), with: .color(Color.primary.opacity(0.07)))
                }
                let path = sector(index, grow: 3)
                context.fill(path, with: .color(Color.primary.opacity(0.14)))
                context.stroke(path, with: .color(Color.primary.opacity(0.75)), lineWidth: 1)
            }
            if let selectedIndex {
                context.stroke(sector(selectedIndex), with: .color(.accentColor), lineWidth: 2.5)
            }
            if hovered == .center {
                let hole = Path(ellipseIn: CGRect(x: m.center.x - m.holeRadius + 2, y: m.center.y - m.holeRadius + 2,
                                                  width: (m.holeRadius - 2) * 2, height: (m.holeRadius - 2) * 2))
                context.fill(hole, with: .color(Color.primary.opacity(0.06)))
            }
        }
    }
}
