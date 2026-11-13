// InspectorView.swift — Get Info-style inspector for the selected item.

import Charts
import SwiftUI
import KlaDModels

struct InspectorView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let _ = app.treeVersion
        if let node = app.selection ?? app.focus {
            NodeInspector(node: node)
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle",
                                   description: Text("Select an item to see its details."))
        }
    }
}

private struct NodeInspector: View {
    @Environment(AppState.self) private var app
    let node: FileTreeNode

    var body: some View {
        let m = node.metrics
        let home = NSHomeDirectory()
        Form {
            Section {
                HStack(spacing: 12) {
                    NodeIcon(node: node, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.isOpaque ? node.name : node.displayName)
                            .font(.headline)
                            .lineLimit(2)
                        Text(kindDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                if !node.isOpaque {
                    LabeledContent("Where") {
                        Text(abbreviatePath(node.parent?.path ?? node.path))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }

            if node.isOpaque || node.isProtectedLocation {
                Section {
                    Text(node.annotation?.reason ?? SystemPolicy.protectedLocation(containing: node.path, home: home)?.explanation
                         ?? "Protected by macOS.")
                        .foregroundStyle(.secondary)
                    if node.isProtectedLocation {
                        Label("KlaD never opens this folder, with or without Full Disk Access.", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                        if let guidance = SystemPolicy.protectedLocation(containing: node.path, home: home)?.guidance {
                            GuidanceView(remediation: guidance)
                        }
                    }
                }
            }

            Section("Storage") {
                LabeledContent(node.isOpaque ? "Size" : "Size on disk", value: formatBytes(m.allocatedBytes))
                if !node.isOpaque && !node.isProtectedLocation {
                    LabeledContent("Freed if deleted", value: formatBytes(m.privateBytes))
                    if m.sharedBytes > 0 {
                        LabeledContent("Shared with clones & snapshots", value: formatBytes(m.sharedBytes))
                    }
                    LabeledContent("Logical size", value: formatBytes(m.logicalBytes))
                    if m.cloudStubBytes > 0 {
                        LabeledContent("In iCloud only", value: formatBytes(m.cloudStubBytes))
                    }
                    if node.isDirectory {
                        LabeledContent("Contains", value: "\(m.fileCount.formatted()) files, \(m.directoryCount.formatted()) folders")
                    }
                }
                if node.modificationTime > 0 && !node.isOpaque {
                    LabeledContent("Modified", value: node.modificationDate.formatted(date: .abbreviated, time: .shortened))
                }
                if node.isDirectory && node.newestModificationTime > 0 && !node.isProtectedLocation {
                    LabeledContent("Last activity inside", value: relativeDate(Date(timeIntervalSince1970: TimeInterval(node.newestModificationTime))))
                }
            }

            if !notes.isEmpty {
                Section {
                    ForEach(notes, id: \.self) { note in
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            if let annotation = node.effectiveAnnotation, !node.isOpaque, !node.isProtectedLocation {
                let recommendation = app.recommendations.first { $0.path == node.path }
                Section("Safety") {
                    SafetyLabel(level: annotation.safety)
                    Text(recommendation?.rationale ?? annotation.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let recommendation {
                        ForEach(Array(recommendation.evidence.enumerated()), id: \.offset) { _, evidence in
                            Label(evidence.detail, systemImage: "checkmark.circle")
                                .font(.callout)
                        }
                        ForEach(Array(recommendation.signals.enumerated()), id: \.offset) { _, signal in
                            Label(signal.text, systemImage: signal.symbolName)
                                .font(.callout)
                                .foregroundStyle(signal.isWarning ? .orange : .secondary)
                        }
                    }
                }
            }

            if app.folderSeries.count >= 2, app.selection === node {
                Section("Size History") {
                    Chart(app.folderSeries, id: \.date) { sample in
                        LineMark(x: .value("Date", sample.date), y: .value("Size", Double(sample.metrics.allocatedBytes)))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", sample.date), y: .value("Size", Double(sample.metrics.allocatedBytes)))
                            .symbolSize(18)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel { if let v = value.as(Double.self) { Text(formatBytes(UInt64(max(0, v)))) } }
                        }
                    }
                    .frame(height: 120)
                    if let first = app.folderSeries.first, let last = app.folderSeries.last {
                        let delta = Int64(bitPattern: last.metrics.allocatedBytes) - Int64(bitPattern: first.metrics.allocatedBytes)
                        Text("\(formatSignedBytes(delta)) since \(first.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !node.isOpaque {
                Section {
                    Button("Show in Finder") { SystemActions.reveal(node.path) }
                    if node.isDirectory && node.hasChildren && !node.isProtectedLocation && node !== app.focus {
                        Button("Zoom In") { app.drill(into: node) }
                    }
                    if app.canTrash(node) {
                        Button("Move to Trash…", role: .destructive) { app.requestCleanup(node: node) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var kindDescription: String {
        if node.isOpaque { return "Managed by macOS" }
        if node.isProtectedLocation { return "Protected by macOS" }
        if node.flags.contains(.package) { return "Package" }
        switch node.kind {
        case .directory: return node.parent == nil ? "Location" : "Folder"
        case .file: return (node.name as NSString).pathExtension.isEmpty ? "File" : "\((node.name as NSString).pathExtension.uppercased()) File"
        case .symlink: return "Alias"
        case .other: return "Item"
        }
    }

    private var notes: [String] {
        let m = node.metrics
        var notes: [String] = []
        guard !node.isOpaque, !node.isProtectedLocation else { return notes }
        if m.sharedBytes > 0 {
            notes.append("\(formatBytes(m.sharedBytes)) is shared with APFS clones, local snapshots or hard links, so deleting frees \(formatBytes(m.privateBytes)) right away.")
        }
        if m.cloudStubBytes > 0 {
            notes.append("\(formatBytes(m.cloudStubBytes)) is stored in iCloud and takes no space on this Mac. KlaD never downloads it.")
        }
        let onDisk = m.logicalBytes > m.cloudStubBytes ? m.logicalBytes - m.cloudStubBytes : 0
        if onDisk > m.allocatedBytes &+ max(m.allocatedBytes / 5, 64 << 20) {
            notes.append("Sparse or compressed: \(formatBytes(onDisk)) of data occupies \(formatBytes(m.allocatedBytes)) on disk.")
        }
        return notes
    }
}

/// Copyable commands and an "Open App" button for guided remediation.
struct GuidanceView: View {
    let remediation: GuidedRemediation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(remediation.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(remediation.commands) { command in
                CommandRow(command: command)
            }
            if let bundleID = remediation.applicationBundleID {
                Button("Open App") { SystemActions.openApplication(bundleID: bundleID) }
            }
        }
    }
}

struct CommandRow: View {
    let command: GuidedCommand
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(command.label, systemImage: command.isDestructive ? "exclamationmark.triangle" : "terminal")
                .font(.callout)
                .foregroundStyle(command.isDestructive ? .orange : .primary)
            HStack {
                Text(command.command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    SystemActions.copy(command.command)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .controlSize(.small)
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
