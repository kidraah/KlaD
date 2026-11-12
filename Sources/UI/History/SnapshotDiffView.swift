// SnapshotDiffView.swift — "Where did my space go?" + live watcher

import SwiftUI
import KlaDModels

struct SnapshotDiffView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            snapshotList
                .frame(width: 290)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WatcherCard()
                    diffContent
                }
                .padding(22)
            }
        }
        .task { await app.reloadHistory() }
    }

    // MARK: Snapshot list

    private var snapshotList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SCAN HISTORY").eyebrow()
                Spacer()
                Text("\(app.snapshots.count)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(app.snapshots.enumerated()), id: \.element.id) { index, summary in
                        snapshotRow(summary, index: index)
                    }
                }
                .padding(.horizontal, 8)
            }
            if let error = app.historyError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Theme.danger).padding(12)
            }
        }
        .background(Theme.panel.opacity(0.5))
    }

    private func snapshotRow(_ summary: ScanSnapshotSummary, index: Int) -> some View {
        let isCurrent = index == 0
        let isBase = app.diffBaseID == summary.id
        let previous = index + 1 < app.snapshots.count ? app.snapshots[index + 1] : nil
        let delta = previous.map {
            Int64(bitPattern: summary.totals.allocatedBytes) - Int64(bitPattern: $0.totals.allocatedBytes)
        }
        return Button {
            guard !isCurrent else { return }
            app.diffBaseID = summary.id
            Task { await app.computeDiff() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? "largecircle.fill.circle" : (isBase ? "smallcircle.filled.circle" : "circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? Theme.accent : (isBase ? Theme.warning : Theme.textTertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.completedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(isCurrent ? "Current scan" : (isBase ? "Comparing against" : relativeDays(summary.completedAt)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatBytes(summary.totals.allocatedBytes))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    if let delta, delta != 0 {
                        Text(formatSignedBytes(delta))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(delta > 0 ? Color(hex: 0xF97316) : Theme.positive)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isBase ? Theme.warning.opacity(0.08) : (isCurrent ? Theme.accentSoft.opacity(0.5) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isCurrent {
                Button("Delete Snapshot", role: .destructive) {
                    Task { await app.deleteSnapshot(summary.id) }
                }
            }
        }
    }

    // MARK: Diff

    @ViewBuilder
    private var diffContent: some View {
        if let diff = app.diff {
            let delta = diff.totalAllocatedDelta
            VStack(alignment: .leading, spacing: 6) {
                Text("WHERE DID MY SPACE GO?").eyebrow()
                (Text(delta >= 0 ? "\(formatSignedBytes(delta)) " : "\(formatSignedBytes(delta)) ")
                    .foregroundColor(delta > 0 ? Color(hex: 0xF97316) : Theme.positive)
                 + Text("since \(diff.base.completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundColor(Theme.textPrimary))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Hotspots are the deepest folders whose change isn't explained by a single subfolder.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            let maxDelta = max(diff.hotspots.map { $0.allocatedDelta.magnitude }.max() ?? 1, 1)
            VStack(spacing: 6) {
                ForEach(diff.hotspots.prefix(40)) { change in
                    DeltaRow(change: change, maxMagnitude: maxDelta)
                }
                if diff.hotspots.isEmpty {
                    Text("No significant changes (≥ 50 MB) between these scans.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Nothing to compare yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(app.snapshots.count < 2
                     ? "Every scan is saved as a compact snapshot. Scan this location again later — KlaD will show exactly which folders grew."
                     : "Pick an earlier scan on the left to compare against.")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }
}

private struct DeltaRow: View {
    @Environment(AppState.self) private var app
    let change: DirectoryDelta
    let maxMagnitude: UInt64

    var body: some View {
        let delta = change.allocatedDelta
        let tint = delta > 0 ? Color(hex: 0xF97316) : Theme.positive
        Button {
            app.reveal(path: change.path)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(abbreviatePath(change.path))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("\(change.before.map { formatBytes($0.allocatedBytes) } ?? "—") → \(change.after.map { formatBytes($0.allocatedBytes) } ?? "—") · \(change.kind.rawValue)")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                ProportionBar(fraction: Double(delta.magnitude) / Double(maxMagnitude), tint: tint, height: 5)
                    .frame(width: 120)
                Text(formatSignedBytes(delta))
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassPanel(radius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show in Explore")
    }

    private var icon: String {
        switch change.kind {
        case .appeared: return "plus.circle.fill"
        case .disappeared: return "minus.circle.fill"
        case .grew: return "arrow.up.right.circle.fill"
        case .shrank: return "arrow.down.right.circle.fill"
        case .unchanged: return "equal.circle"
        }
    }
}

private struct WatcherCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 14) {
            ZStack {
                Circle().fill((app.dirtyPaths.isEmpty ? Theme.positive : Theme.warning).opacity(0.15))
                Image(systemName: app.isRescanning ? "arrow.triangle.2.circlepath" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(app.dirtyPaths.isEmpty ? Theme.positive : Theme.warning)
                    .symbolEffect(.pulse, isActive: app.isRescanning)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.root.map { "Watching \(abbreviatePath($0.path)) with FSEvents" } ?? "Watcher idle")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Toggle("Auto-update", isOn: $app.autoRescan)
                .toggleStyle(.switch)
                .controlSize(.small)
            Button {
                Task { await app.rescanDirty() }
            } label: {
                Label("Rescan Changed", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(app.dirtyPaths.isEmpty || app.isRescanning)
        }
        .padding(14)
        .glassPanel(radius: 12, fill: Theme.panelRaised)
    }

    private var statusText: String {
        if app.isRescanning { return "Rescanning changed folders…" }
        if app.needsFullRescan && app.dirtyPaths.isEmpty {
            return "macOS reported changes it couldn't itemize at the top level — run a full Rescan (⌘R) for exact totals."
        }
        if !app.dirtyPaths.isEmpty {
            let names = app.dirtyPaths.prefix(3).map { abbreviatePath($0.path) }.joined(separator: ", ")
            let pending = "\(app.dirtyPaths.count) changed folder\(app.dirtyPaths.count == 1 ? "" : "s") pending: \(names)"
            return app.lastRescanSummary.map { "\($0)\n\(pending)" } ?? pending
        }
        return app.lastRescanSummary ?? "No changes since the scan. Changed folders are marked dirty and rescanned in the background."
    }
}
