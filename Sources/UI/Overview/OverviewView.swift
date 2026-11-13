// OverviewView.swift — storage bar · chart + path bar · tree table.

import SwiftUI
import KlaDModels

struct OverviewView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            StorageBarView()
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    Group {
                        switch app.visualizerMode {
                        case .sunburst: SunburstCanvasView().padding(20)
                        case .treemap: TreemapCanvasView().padding(8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if app.colorMode == .age { AgeLegend().padding(.bottom, 8) }
                    Divider()
                    PathBar()
                }
                .frame(minWidth: 380, idealWidth: 620)
                NodeTable()
                    .frame(minWidth: 320, idealWidth: 460)
            }
        }
    }
}

// MARK: - Storage bar (System Settings › Storage style)

struct StorageBarView: View {
    @Environment(AppState.self) private var app

    struct Segment: Identifiable {
        let id: String
        let title: String
        let bytes: UInt64
        let color: Color
    }

    var body: some View {
        let volume = app.volume
        let total = volume?.totalCapacity ?? app.root?.metrics.allocatedBytes ?? 1
        let used = volume?.usedCapacity ?? app.root?.metrics.allocatedBytes ?? 0
        let segments = makeSegments(used: used)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume?.volumeName ?? app.currentLocation?.title ?? "")
                    .font(.headline)
                Spacer()
                Text("\(formatBytes(used)) of \(formatBytes(total)) used")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let spacing: CGFloat = 1.5
                let usable = max(0, width - spacing * CGFloat(max(segments.count, 1)))
                let scale = Double(usable) / Double(max(total, 1))
                HStack(spacing: spacing) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(1, CGFloat(Double(segment.bytes) * scale)))
                            .help("\(segment.title): \(formatBytes(segment.bytes))")
                    }
                    Rectangle().fill(.quaternary)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 20)
            FlowLayout(spacing: 14, lineSpacing: 4) {
                ForEach(segments.prefix(9)) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.title)
                        Text(formatBytes(segment.bytes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
                if let volume {
                    HStack(spacing: 5) {
                        Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: 8, height: 8)
                        Text("Available")
                        Text(formatBytes(volume.availableCapacity)).foregroundStyle(.secondary).monospacedDigit()
                        if volume.purgeableCapacity > 0 {
                            Text("(+\(formatBytes(volume.purgeableCapacity)) purgeable)")
                                .foregroundStyle(.tertiary)
                                .help("Space macOS frees automatically when needed: caches, iCloud files that can be downloaded again, expiring snapshots.")
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func makeSegments(used: UInt64) -> [Segment] {
        var items = app.categoryTotals
            .map { (category: $0.key, bytes: $0.value.allocatedBytes) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
            .map { Segment(id: "\($0.category.rawValue)", title: $0.category.displayName, bytes: $0.bytes, color: $0.category.color) }
        let scanned = items.reduce(0) { $0 + $1.bytes }
        if app.root?.path != "/", used > scanned {
            items.append(Segment(id: "elsewhere", title: "Elsewhere on This Mac", bytes: used - scanned,
                                 color: Color(nsColor: .systemGray).opacity(0.35)))
        }
        // Clones are counted per file but stored once: never draw past "used".
        let sum = items.reduce(0) { $0 + $1.bytes }
        if sum > used, used > 0 {
            let factor = Double(used) / Double(sum)
            items = items.map { Segment(id: $0.id, title: $0.title, bytes: UInt64(Double($0.bytes) * factor), color: $0.color) }
        }
        return items
    }
}

struct AgeLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(AgeBucket.allCases) { bucket in
                HStack(spacing: 4) {
                    Circle().fill(bucket.color).frame(width: 7, height: 7)
                    Text(bucket.title)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Colored by the newest file inside each item")
    }
}

// MARK: - Finder-style path bar

struct PathBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(app.focusChain.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        app.drill(into: node)
                    } label: {
                        HStack(spacing: 4) {
                            NodeIcon(node: node, size: 16)
                            Text(node.displayName)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28)
        .background(.bar)
    }
}

// MARK: - Context menu

struct NodeContextMenu: View {
    @Environment(AppState.self) private var app
    let node: FileTreeNode

    var body: some View {
        if !node.isOpaque {
            Button("Show in Finder") { SystemActions.reveal(node.path) }
            Button("Copy Path") { SystemActions.copy(node.path) }
        }
        if node.isDirectory && node.hasChildren && !node.isProtectedLocation {
            Button("Zoom In") { app.drill(into: node) }
        }
        Button("Get Info") {
            app.select(node)
            app.showInspector = true
        }
        if app.canTrash(node) {
            Divider()
            Button("Move to Trash…") { app.requestCleanup(node: node) }
        }
    }
}
