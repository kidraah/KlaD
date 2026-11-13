// HistoryView.swift — used space over time, forecast, what changed, live updates.

import Charts
import SwiftUI
import KlaDModels

struct HistoryView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                if app.usageSeries.count >= 2 {
                    Chart(app.usageSeries, id: \.date) { sample in
                        AreaMark(x: .value("Date", sample.date), y: .value("Used", Double(sample.usedBytes)))
                            .foregroundStyle(Color.accentColor.opacity(0.18))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", sample.date), y: .value("Used", Double(sample.usedBytes)))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel { if let v = value.as(Double.self) { Text(formatBytes(UInt64(max(0, v)))) } }
                        }
                    }
                    .frame(height: 180)
                    .padding(.vertical, 4)
                } else {
                    Text("Scan again over the coming days to see how used space changes.")
                        .foregroundStyle(.secondary)
                }
                if let forecast = app.forecast {
                    Label(forecastText(forecast), systemImage: "calendar")
                }
            } header: {
                Text("Used Space")
            }

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
                } else if app.snapshots.count < 2 {
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

    private func forecastText(_ forecast: ForecastOutcome) -> String {
        switch forecast {
        case .insufficientData:
            return "A fill forecast appears after a week of scans on at least four different days."
        case .notFillingUp:
            return "Used space isn't growing."
        case .fillsIn(let low, let high, let perDay):
            return "At about \(formatBytes(UInt64(max(0, perDay)))) a day, the disk would be full in \(low)–\(high) days."
        case .moreThanTwoYears:
            return "At the current pace, the disk won't fill up for more than two years."
        }
    }
}
