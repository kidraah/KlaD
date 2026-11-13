// RecommendationsView.swift — System Settings › Storage-style recommendations.

import SwiftUI
import KlaDModels

struct RecommendationsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            Section {
                StorageBarView()
                    .padding(.vertical, 4)
            }

            tierSection(.safeToClear, title: "Safe to Clear",
                        footer: "Each item has proof it can be recreated — a project manifest and lockfile, or a cache folder its tool rebuilds. Everything goes to the Trash first.")
            tierSection(.reviewFirst, title: "Review First",
                        footer: "Reclaimable, but may mean large downloads to get back, or may hold something you want to keep.")
            tierSection(.guidedExternalAction, title: "Managed by Other Apps",
                        footer: "KlaD never deletes these files. Use the owning app or its command-line tool instead.")

            if app.recommendations.isEmpty {
                Section {
                    Text("No recommendations for this location.")
                        .foregroundStyle(.secondary)
                }
            }
            if app.reclaimedThisSession > 0 {
                Section {
                    LabeledContent("Moved to the Trash this session", value: formatBytes(app.reclaimedThisSession))
                    Text("Space is freed when you empty the Trash.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func tierSection(_ level: SafetyLevel, title: String, footer: String) -> some View {
        let items = app.recommendations(for: level)
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    RecommendationRow(recommendation: item)
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    if level != .guidedExternalAction {
                        Text(formatBytes(items.reduce(0) { $0 + $1.reclaimableBytes }))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if level == .safeToClear && app.batchCandidates.count > 1 {
                        Button("Review All…") { app.requestBatchCleanup() }
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text(footer)
            }
        }
    }
}

struct RecommendationRow: View {
    @Environment(AppState.self) private var app
    let recommendation: CleanupRecommendation
    @State private var showDetails = false

    var body: some View {
        let rec = recommendation
        HStack(spacing: 10) {
            SymbolTile(systemName: rec.group.symbolName, color: rec.category.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if rec.metrics.allocatedBytes > 0 {
                Text(formatBytes(rec.safety == .guidedExternalAction ? rec.metrics.allocatedBytes : rec.reclaimableBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button {
                showDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Details")
            .popover(isPresented: $showDetails, arrowEdge: .trailing) {
                RecommendationDetails(recommendation: rec)
            }
            actionButton
        }
        .padding(.vertical, 2)
        .contextMenu {
            if rec.path != "/" && rec.path != "/Applications" {
                Button("Show in Overview") { app.reveal(path: rec.path) }
                Button("Show in Finder") { SystemActions.reveal(rec.path) }
            }
        }
    }

    private var subtitle: String {
        if recommendation.safety == .guidedExternalAction || recommendation.path == "/" {
            return recommendation.rationale
        }
        return abbreviatePath(recommendation.path)
    }

    @ViewBuilder
    private var actionButton: some View {
        if recommendation.isTrashable && app.mayModify(path: recommendation.path) {
            Button("Move to Trash…") { app.requestCleanup(recommendation) }
        } else if case .guided = recommendation.action {
            Button("Show How…") { showDetails = true }
        }
    }
}

struct RecommendationDetails: View {
    @Environment(AppState.self) private var app
    let recommendation: CleanupRecommendation

    var body: some View {
        let rec = recommendation
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    SymbolTile(systemName: rec.group.symbolName, color: rec.category.color, size: 32)
                    VStack(alignment: .leading) {
                        Text(rec.title).font(.headline)
                        SafetyLabel(level: rec.safety).font(.caption)
                    }
                }
                Text(rec.rationale)
                    .fixedSize(horizontal: false, vertical: true)
                if !rec.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Evidence").font(.subheadline.weight(.semibold))
                        ForEach(Array(rec.evidence.enumerated()), id: \.offset) { _, evidence in
                            Label(evidence.detail, systemImage: "checkmark.circle")
                                .font(.callout)
                        }
                    }
                }
                if !rec.signals.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Good to Know").font(.subheadline.weight(.semibold))
                        ForEach(Array(rec.signals.enumerated()), id: \.offset) { _, signal in
                            Label(signal.text, systemImage: signal.symbolName)
                                .font(.callout)
                                .foregroundStyle(signal.isWarning ? .orange : .secondary)
                        }
                    }
                }
                ForEach(rec.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let regenerate = rec.regenerateCommand {
                    CommandRow(command: GuidedCommand(label: "Recreate later with", command: regenerate, isDestructive: false))
                }
                if let remediation = rec.action.guidedRemediation {
                    Divider()
                    Text(remediation.headline).font(.subheadline.weight(.semibold))
                    GuidanceView(remediation: remediation)
                }
                if rec.metrics.allocatedBytes > 0 {
                    Divider()
                    LabeledContent("Size on disk", value: formatBytes(rec.metrics.allocatedBytes))
                    LabeledContent("Freed when the Trash is emptied", value: formatBytes(rec.reclaimableBytes))
                }
            }
            .padding(16)
        }
        .frame(width: 420)
        .frame(maxHeight: 520)
    }
}
