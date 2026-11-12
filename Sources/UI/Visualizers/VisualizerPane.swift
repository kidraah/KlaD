// VisualizerPane.swift — breadcrumb, mode/measure switches, legend

import SwiftUI
import KlaDModels

struct VisualizerPane: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BreadcrumbBar()
                Spacer(minLength: 8)
                Picker("Size by", selection: $app.measure) {
                    ForEach(SizeMeasure.allCases) { measure in
                        Text(measure.displayName).tag(measure)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(app.measure.explanation)
                Picker("Visualizer", selection: $app.visualizerMode) {
                    ForEach(VisualizerMode.allCases) { mode in
                        Image(systemName: mode.symbol).tag(mode).help(mode.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Theme.hairline)

            ZStack {
                switch app.visualizerMode {
                case .sunburst:
                    SunburstCanvasView()
                        .padding(18)
                case .treemap:
                    TreemapCanvasView()
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            CategoryLegend()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }
}

struct BreadcrumbBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let chain = app.focusChain
        let visible: [FileTreeNode] = chain.count > 5 ? [chain[0]] + chain.suffix(3) : chain
        HStack(spacing: 2) {
            Button {
                app.drillUp()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(app.focus?.parent == nil ? Theme.textTertiary : Theme.textPrimary)
            .disabled(app.focus?.parent == nil)
            .help("Zoom out")

            ForEach(Array(visible.enumerated()), id: \.element.id) { offset, node in
                if offset > 0 {
                    Image(systemName: chain.count > 5 && offset == 1 ? "ellipsis" : "chevron.compact.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Button {
                    withAnimation(.snappy) { app.drill(into: node) }
                } label: {
                    HStack(spacing: 4) {
                        if offset == 0 {
                            Image(systemName: node.name == "/" ? "internaldrive.fill" : "house.fill")
                                .font(.system(size: 10))
                        }
                        Text(node.displayName)
                            .font(.system(size: 12, weight: node === app.focus ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(node === app.focus ? Theme.accentSoft : Color.clear)
                    )
                    .foregroundStyle(node === app.focus ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy, value: app.focus.map(ObjectIdentifier.init))
    }
}

struct CategoryLegend: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let totals = app.categoryTotals
            .map { (category: $0.key, bytes: $0.value.value(for: app.measure)) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
        let sum = max(totals.reduce(0) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(totals, id: \.category) { item in
                        Rectangle()
                            .fill(item.category.color)
                            .frame(width: max(2, proxy.size.width * CGFloat(Double(item.bytes) / Double(sum)) - 1.5))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            FlowLayout(spacing: 12, lineSpacing: 5) {
                ForEach(totals, id: \.category) { item in
                    HStack(spacing: 5) {
                        CategoryDot(category: item.category, size: 7)
                        Text(item.category.displayName)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                        Text(formatBytes(item.bytes))
                            .font(.system(size: 10.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
    }
}

/// Minimal wrapping layout for chips/legends.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
