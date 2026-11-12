// TreeTableView.swift — hierarchical tree-table synced with the visualizer
//
// Rows are the focus node's children (LoD: the largest 250 per level plus one
// aggregated "N more items" row), expanded lazily through `children`.

import SwiftUI
import KlaDModels

struct TreeRow: Identifiable, Hashable {
    enum ID: Hashable {
        case node(ObjectIdentifier)
        case aggregate(ObjectIdentifier)
    }

    static let pageSize = 250

    let id: ID
    let node: FileTreeNode?
    let owner: FileTreeNode
    let measure: SizeMeasure
    let aggregateCount: Int
    let aggregateMetrics: StorageMetrics

    static func == (lhs: TreeRow, rhs: TreeRow) -> Bool { lhs.id == rhs.id && lhs.measure == rhs.measure }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var metrics: StorageMetrics { node?.metrics ?? aggregateMetrics }

    var children: [TreeRow]? {
        guard let node, node.isDirectory, node.hasChildren else { return nil }
        return TreeRow.rows(for: node, measure: measure)
    }

    static func rows(for parent: FileTreeNode, measure: SizeMeasure) -> [TreeRow] {
        let sorted = VisualizerMath.sortedChildren(parent, measure)
        var rows = sorted.prefix(pageSize).map {
            TreeRow(id: .node(ObjectIdentifier($0)), node: $0, owner: parent, measure: measure,
                    aggregateCount: 0, aggregateMetrics: .zero)
        }
        if sorted.count > pageSize {
            var rest = StorageMetrics.zero
            for child in sorted.dropFirst(pageSize) { rest.add(child.aggregateContribution) }
            rows.append(TreeRow(id: .aggregate(ObjectIdentifier(parent)), node: nil, owner: parent, measure: measure,
                                aggregateCount: sorted.count - pageSize, aggregateMetrics: rest))
        }
        return rows
    }
}

struct TreeTableView: View {
    @Environment(AppState.self) private var app
    @State private var selectedID: TreeRow.ID?

    var body: some View {
        let rows = app.focus.map { TreeRow.rows(for: $0, measure: app.measure) } ?? []
        let focusValue = max(app.focus?.metrics.value(for: app.measure) ?? 1, 1)
        // Re-evaluate on tree mutations.
        let _ = app.treeVersion

        Table(rows, children: \.children, selection: $selectedID) {
            TableColumn("Name") { row in
                NameCell(row: row)
            }
            .width(min: 180, ideal: 260)

            TableColumn(app.measure == .allocated ? "Allocated" : app.measure.displayName) { row in
                SizeCell(value: row.metrics.value(for: app.measure), fraction: Double(row.metrics.value(for: app.measure)) / Double(focusValue),
                         tint: row.node?.category.color ?? Theme.aggregate)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Reclaimable") { row in
                Text(formatBytes(row.metrics.privateBytes))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(row.metrics.privateBytes < row.metrics.allocatedBytes ? Theme.warning : Theme.textSecondary)
                    .help(row.metrics.sharedBytes > 0
                          ? "\(formatBytes(row.metrics.sharedBytes)) is shared with clones, snapshots or hard links"
                          : "Fully private — freed immediately if deleted")
            }
            .width(min: 70, ideal: 86)

            TableColumn("Items") { row in
                Text(row.node?.isDirectory == false ? "—" : formatCount(row.metrics.itemCount))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .width(min: 44, ideal: 56)

            TableColumn("Safety") { row in
                if let annotation = row.node?.effectiveAnnotation {
                    SafetyBadge(level: annotation.safety, compact: true)
                        .help("\(annotation.title) — \(annotation.safety.displayName)")
                }
            }
            .width(min: 40, ideal: 48)

            TableColumn("") { row in
                FlagIcons(row: row)
            }
            .width(min: 40, ideal: 56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: TreeRow.ID.self) { ids in
            if let id = ids.first, let node = node(for: id, in: rows) {
                Button("Reveal in Finder") { SystemActions.reveal(node.path) }
                Button("Copy Path") { SystemActions.copy(node.path) }
                if node.isDirectory && node.hasChildren {
                    Button("Show in Visualizer") { app.drill(into: node) }
                }
                if app.canTrash(node) {
                    Divider()
                    Button("Move to Trash…") { app.requestCleanup(node: node) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let node = node(for: id, in: rows), node.isDirectory, node.hasChildren {
                app.drill(into: node)
            }
        }
        .onChange(of: selectedID) { _, newValue in
            guard let newValue, let node = node(for: newValue, in: rows) else { return }
            if app.selection !== node { app.select(node) }
        }
        .onChange(of: app.selection.map(ObjectIdentifier.init)) { _, newValue in
            guard let newValue else { return }
            let id = TreeRow.ID.node(newValue)
            if selectedID != id { selectedID = id }
        }
    }

    /// Resolves a row id to a node (searching the focus subtree for expanded rows).
    private func node(for id: TreeRow.ID, in rows: [TreeRow]) -> FileTreeNode? {
        guard case .node(let oid) = id else { return nil }
        if let direct = rows.first(where: { $0.id == id })?.node { return direct }
        if let selection = app.selection, ObjectIdentifier(selection) == oid { return selection }
        var found: FileTreeNode?
        app.focus?.walk { node in
            if ObjectIdentifier(node) == oid { found = node; return .stop }
            return node.depth > 64 ? .skipChildren : .continue
        }
        return found
    }
}

private struct NameCell: View {
    let row: TreeRow

    var body: some View {
        HStack(spacing: 6) {
            if let node = row.node {
                Image(systemName: icon(for: node))
                    .font(.system(size: 11))
                    .foregroundStyle(node.category.color.opacity(0.9))
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(node.flags.contains(.hidden) ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14)
                Text("\(row.aggregateCount) more items")
                    .font(.system(size: 12).italic())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func icon(for node: FileTreeNode) -> String {
        if node.flags.contains(.cloudPlaceholder) { return "icloud" }
        switch node.kind {
        case .directory:
            if node.flags.contains(.package) { return "shippingbox" }
            if node.flags.contains(.unreadable) { return "folder.badge.minus" }
            return "folder.fill"
        case .symlink: return "arrow.turn.up.right"
        case .other: return "questionmark.square.dashed"
        case .file: return "doc"
        }
    }
}

private struct SizeCell: View {
    let value: UInt64
    let fraction: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ProportionBar(fraction: fraction, tint: tint, height: 3)
                .frame(width: 34)
            Text(formatBytes(value))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct FlagIcons: View {
    let row: TreeRow

    var body: some View {
        HStack(spacing: 3) {
            if let node = row.node {
                if node.metrics.cloudStubBytes > 0 {
                    icon("icloud.fill", Theme.info, "\(formatBytes(node.metrics.cloudStubBytes)) in iCloud (0 B on SSD)")
                }
                if node.flags.contains(.sharesAllBlocks) || node.flags.contains(.mayShareBlocks) || (node.isDirectory && node.metrics.sharedBytes > 0) {
                    icon("square.on.square", Theme.warning, "Shares blocks with APFS clones or snapshots")
                }
                if node.flags.contains(.hardLinked) {
                    icon("link", Theme.textSecondary, "Hard-linked")
                }
                if node.flags.contains(.unreadable) || node.flags.contains(.incompleteSubtree) {
                    icon("lock.fill", Theme.danger, "Some contents could not be read")
                }
                if node.flags.contains(.mountPoint) || node.flags.contains(.excluded) {
                    icon("externaldrive", Theme.textTertiary, "Not scanned (other volume or excluded)")
                }
            }
        }
    }

    private func icon(_ name: String, _ tint: Color, _ help: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .help(help)
    }
}
