// HistoryView.swift — what changed between scans, and live updates.

import SwiftUI
import KlaDModels

struct HistoryView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                if app.snapshots.count >= 2 {
                    Picker("Compare with", selection: Binding(
                        get: { app.diffBaseID },
                        set: { app.diffBaseID = $0; Task { await app.computeDiff() } }
                    )) {
                        ForEach(app.snapshots.dropFirst()) { summary in
                            Text(summary.completedAt.formatted(date: .abbreviated, time: .shortened)).tag(Optional(summary.id))
                        }
                    }
                }
                if let diff = app.diff {
                    LabeledContent("Change", value: formatSignedBytes(diff.totalAllocatedDelta))
                    if diff.hotspots.isEmpty {
                        Text("No folder changed by 50 MB or more.").foregroundStyle(.secondary)
                    }
                    ForEach(diff.hotspots.prefix(40)) { change in
                        HStack {
                            Image(systemName: change.allocatedDelta > 0 ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(change.allocatedDelta > 0 ? .orange : .green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((change.path as NSString).lastPathComponent)
                                Text(abbreviatePath((change.path as NSString).deletingLastPathComponent))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            Text(formatSignedBytes(change.allocatedDelta)).monospacedDigit()
                                .foregroundStyle(change.allocatedDelta > 0 ? .orange : .green)
                        }
                        .contentShape(Rectangle())
                        .contextMenu { PathContextMenu(path: change.path) }
                    }
                } else {
                    Text("Every scan is saved. Scan this location again later to see what changed.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("What Changed")
            }

            Section {
                Toggle("Update automatically when files change", isOn: $app.liveUpdates)
                if app.isRescanning {
                    Label("Updating changed folders…", systemImage: "arrow.triangle.2.circlepath")
                } else if let summary = app.lastRescanSummary {
                    Label(summary, systemImage: "checkmark.circle")
                }
                if !app.dirtyPaths.isEmpty {
                    LabeledContent("Changed folders waiting", value: "\(app.dirtyPaths.count)")
                    Button("Update Now") { Task { await app.rescanDirty() } }
                }
                if app.needsFullRescan {
                    Label("Some changes can only be picked up by a full rescan.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Live Updates")
            }

            if !app.snapshots.isEmpty {
                Section("Saved Scans") {
                    ForEach(app.snapshots) { summary in
                        LabeledContent(summary.completedAt.formatted(date: .abbreviated, time: .shortened),
                                       value: formatBytes(summary.totals.allocatedBytes))
                            .contextMenu {
                                Button("Delete", role: .destructive) { Task { await app.deleteSnapshot(summary.id) } }
                            }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await app.reloadHistory() }
    }
}
