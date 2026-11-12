// NodeDetailInspector.swift — APFS telemetry drawer
//
// Logical vs Allocated vs Immediately Reclaimable (private) vs Shared vs
// Cloud placeholder bytes for the selected node, with flags, safety and the
// matching recommendation.

import SwiftUI
import KlaDModels

struct NodeDetailInspector: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let _ = app.treeVersion
        if let node = app.selection ?? app.focus {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(node)
                    TelemetryBars(metrics: node.metrics)
                    explanation(node)
                    flags(node)
                    safety(node)
                    actions(node)
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "cursorarrow.click.2",
                                   description: Text("Hover or click the visualizer to inspect an item."))
        }
    }

    private func header(_ node: FileTreeNode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(node.category.color.opacity(0.16))
                Image(systemName: node.isDirectory ? (node.flags.contains(.package) ? "shippingbox.fill" : "folder.fill") : "doc.fill")
                    .foregroundStyle(node.category.color)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(abbreviatePath(node.path))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Chip(text: node.category.displayName, symbol: node.category.symbolName, tint: node.category.color)
                    if node.modificationTime > 0 {
                        Chip(text: "Modified \(relativeDays(node.modificationDate))", symbol: "clock")
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func explanation(_ node: FileTreeNode) -> some View {
        let m = node.metrics
        VStack(alignment: .leading, spacing: 6) {
            if m.sharedBytes > 0 {
                note("square.on.square", Theme.warning,
                     "\(formatBytes(m.sharedBytes)) is shared with APFS clones, local snapshots or hard links — deleting frees only \(formatBytes(m.privateBytes)) right away.")
            }
            if m.cloudStubBytes > 0 {
                note("icloud", Theme.info,
                     "\(formatBytes(m.cloudStubBytes)) lives in iCloud (0 B on this SSD). KlaD never opens or downloads placeholders.")
            }
            let onDiskLogical = m.logicalBytes > m.cloudStubBytes ? m.logicalBytes - m.cloudStubBytes : 0
            if onDiskLogical > m.allocatedBytes &+ max(m.allocatedBytes / 5, 64 << 20) {
                note("arrow.down.right.and.arrow.up.left", Theme.textSecondary,
                     "Sparse or compressed data: \(formatBytes(m.logicalBytes)) logical occupies \(formatBytes(m.allocatedBytes)) on disk.")
            }
            if node.flags.contains(.unreadable) || node.flags.contains(.incompleteSubtree) {
                note("lock.fill", Theme.danger,
                     "Some folders couldn't be read — totals are a lower bound. Grant Full Disk Access for complete results.")
            }
        }
    }

    private func note(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).frame(width: 14)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func flags(_ node: FileTreeNode) -> some View {
        let items: [(String, String)] = [
            (.cloudPlaceholder, "icloud", "Cloud placeholder"),
            (.sharesAllBlocks, "square.on.square.fill", "Pure APFS clone"),
            (.mayShareBlocks, "square.on.square", "May share blocks"),
            (.hardLinked, "link", "Hard-linked"),
            (.sparse, "circle.dotted", "Sparse"),
            (.compressed, "rectangle.compress.vertical", "Compressed"),
            (.purgeable, "wind", "Purgeable"),
            (.firmlink, "arrow.triangle.branch", "Firmlink"),
            (.mountPoint, "externaldrive", "Mount point"),
            (.package, "shippingbox", "Package"),
            (.restricted, "lock.shield", "SIP-protected"),
            (.immutable, "lock", "Immutable"),
        ].compactMap { (flag: NodeFlags, symbol: String, title: String) in
            node.flags.contains(flag) ? (symbol, title) : nil
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("ATTRIBUTES").eyebrow()
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(items, id: \.1) { item in
                        Chip(text: item.1, symbol: item.0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func safety(_ node: FileTreeNode) -> some View {
        if let annotation = node.effectiveAnnotation {
            let recommendation = app.recommendations.first { $0.path == node.path }
            VStack(alignment: .leading, spacing: 8) {
                Text("SAFETY").eyebrow()
                HStack(spacing: 8) {
                    SafetyBadge(level: annotation.safety)
                    Text(annotation.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Text(recommendation?.rationale ?? annotation.reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let recommendation {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(Array(recommendation.evidence.enumerated()), id: \.offset) { _, evidence in
                            Chip(text: evidence.detail, symbol: "checkmark.seal", tint: Theme.positive)
                        }
                        ForEach(Array(recommendation.signals.enumerated()), id: \.offset) { _, signal in
                            SignalChip(signal: signal)
                        }
                    }
                }
            }
            .padding(12)
            .glassPanel(radius: 8, fill: annotation.safety.color.opacity(0.05))
        }
    }

    private func actions(_ node: FileTreeNode) -> some View {
        HStack(spacing: 8) {
            Button {
                SystemActions.reveal(node.path)
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
            }
            Button {
                SystemActions.copy(node.path)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if node.isDirectory && node.hasChildren && node !== app.focus {
                Button {
                    app.drill(into: node)
                } label: {
                    Label("Zoom", systemImage: "plus.magnifyingglass")
                }
            }
            Spacer()
            if app.canTrash(node) {
                Button(role: .destructive) {
                    app.requestCleanup(node: node)
                } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
                .tint(Theme.danger)
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }
}

/// The 4-metric APFS bars.
struct TelemetryBars: View {
    let metrics: StorageMetrics

    var body: some View {
        let rows: [(String, UInt64, Color, String)] = [
            ("Logical", metrics.logicalBytes, Theme.textSecondary, "Reported content length (ATTR_FILE_TOTALSIZE)"),
            ("Allocated", metrics.allocatedBytes, Theme.accent, "Physical APFS blocks (ATTR_FILE_ALLOCSIZE)"),
            ("Reclaimable", metrics.privateBytes, Theme.positive, "Private bytes freed immediately (ATTR_CMNEXT_PRIVATESIZE)"),
            ("Shared", metrics.sharedBytes, Theme.warning, "Allocated but shared with clones / snapshots / hard links"),
            ("iCloud", metrics.cloudStubBytes, Theme.info, "Logical bytes of SF_DATALESS placeholders — 0 B on disk"),
        ]
        let maxValue = max(rows.map(\.1).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 7) {
            Text("APFS TELEMETRY").eyebrow()
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 8) {
                    Text(row.0)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 72, alignment: .leading)
                    ProportionBar(fraction: Double(row.1) / Double(maxValue), tint: row.2, height: 6)
                    Text(formatBytes(row.1))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(row.1 == 0 ? Theme.textTertiary : Theme.textPrimary)
                        .frame(width: 70, alignment: .trailing)
                }
                .help(row.3)
            }
            HStack(spacing: 14) {
                Text("\(formatCount(UInt64(metrics.fileCount))) files")
                Text("\(formatCount(UInt64(metrics.directoryCount))) folders")
            }
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(Theme.textTertiary)
        }
    }
}
