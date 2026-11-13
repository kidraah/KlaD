// NodeTable.swift — Finder-style hierarchical table, synced with the chart.

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
    let measure: SizeMeasure
    let aggregateCount: Int
    let aggregateMetrics: StorageMetrics

    static func == (lhs: TreeRow, rhs: TreeRow) -> Bool { lhs.id == rhs.id && lhs.measure == rhs.measure }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var metrics: StorageMetrics { node?.metrics ?? aggregateMetrics }

    var children: [TreeRow]? {
        guard let node, node.isDirectory, node.hasChildren, !node.isProtectedLocation else { return nil }
        return TreeRow.rows(for: node, measure: measure)
    }

    static func rows(for parent: FileTreeNode, measure: SizeMeasure) -> [TreeRow] {
        let sorted = VisualizerMath.sortedChildren(parent, measure)
        var rows = sorted.prefix(pageSize).map {
            TreeRow(id: .node(ObjectIdentifier($0)), node: $0, measure: measure, aggregateCount: 0, aggregateMetrics: .zero)
        }
        if sorted.count > pageSize {
            var rest = StorageMetrics.zero
            for child in sorted.dropFirst(pageSize) { rest.add(child.aggregateContribution) }
            rows.append(TreeRow(id: .aggregate(ObjectIdentifier(parent)), node: nil, measure: measure,
                                aggregateCount: sorted.count - pageSize, aggregateMetrics: rest))
        }
        return rows
    }
}

struct NodeTable: View {
    @Environment(AppState.self) private var app
    @State private var selectedID: TreeRow.ID?

    var body: some View {
        let _ = app.treeVersion
        let rows = app.focus.map { TreeRow.rows(for: $0, measure: app.measure) } ?? []
        Table(rows, children: \.children, selection: $selectedID) {
            TableColumn("Name") { row in
                NameCell(row: row)
            }
            .width(min: 160, ideal: 240)

            TableColumn(app.measure == .allocated ? "Size" : app.measure.displayName) { row in
                Text(formatBytes(row.metrics.value(for: app.measure)))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84)

            TableColumn("Reclaimable") { row in
                Text(row.node?.isOpaque == true || row.node?.isProtectedLocation == true ? "—" : formatBytes(row.metrics.privateBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(row.metrics.sharedBytes > 0
                          ? "\(formatBytes(row.metrics.sharedBytes)) is shared with APFS clones, snapshots or hard links"
                          : "Freed immediately if deleted")
            }
            .width(min: 70, ideal: 90)

            TableColumn("Items") { row in
                Text(row.node.map { $0.isDirectory ? formatCount($0.metrics.itemCount) : "" } ?? formatCount(UInt64(row.aggregateCount)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 56)

            TableColumn("Last Activity") { row in
                if let node = row.node, node.newestModificationTime > 0, !node.isOpaque {
                    Text(Date(timeIntervalSince1970: TimeInterval(node.newestModificationTime)), format: .dateTime.day().month(.abbreviated).year())
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: TreeRow.ID.self) { ids in
            if let id = ids.first, let node = node(for: id, in: rows) {
                NodeContextMenu(node: node)
            }
        } primaryAction: { ids in
            if let id = ids.first, let node = node(for: id, in: rows) { app.drill(into: node) }
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

    private func node(for id: TreeRow.ID, in rows: [TreeRow]) -> FileTreeNode? {
        guard case .node(let oid) = id else { return nil }
        if let direct = rows.first(where: { $0.id == id })?.node { return direct }
        if let selection = app.selection, ObjectIdentifier(selection) == oid { return selection }
        var found: FileTreeNode?
        var budget = 200_000
        app.focus?.walk { node in
            budget -= 1
            if ObjectIdentifier(node) == oid { found = node; return .stop }
            return budget > 0 ? .continue : .stop
        }
        return found
    }
}

private struct NameCell: View {
    let row: TreeRow

    var body: some View {
        if let node = row.node {
            HStack(spacing: 6) {
                NodeIcon(node: node, size: 16)
                Text(node.isOpaque ? node.name : node.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(node.flags.contains(.hidden) ? .secondary : .primary)
                if node.isProtectedLocation {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Protected by macOS — KlaD never opens it")
                }
                if node.metrics.cloudStubBytes > 0 {
                    Image(systemName: "icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("\(formatBytes(node.metrics.cloudStubBytes)) stored in iCloud only")
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("\(row.aggregateCount) more items")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
