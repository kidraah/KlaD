// CleanupPreFlightSheet.swift — verify, acknowledge, then Trash
//
// Runs SafeCleanupService.preflight (exists · identity · safety · protected
// path · related apps · open files) before enabling the destructive button.
// Review-tier items additionally require an explicit acknowledgement.

import SwiftUI
import KlaDModels

struct CleanupPreFlightSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: CleanupRequest

    @State private var report: PreflightReport?
    @State private var acknowledged = false
    @State private var performing = false
    @State private var outcome: CleanupOutcome?

    var body: some View {
        let target = request.target
        VStack(alignment: .leading, spacing: 16) {
            header(target)
            TelemetryBars(metrics: target.metrics)
                .padding(12)
                .glassPanel(radius: 10)

            if let note = request.note {
                Label(note, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
            if let rec = request.recommendation {
                if let regenerate = rec.regenerateCommand {
                    CommandSnippet(command: regenerate, caption: "Recreate later with")
                }
                ForEach(rec.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            checks

            if request.requiresAcknowledgement {
                Toggle(isOn: $acknowledged) {
                    Text("I reviewed this item. Re-creating it may require re-downloading or rebuilding, and I don't need anything unique inside it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .tint(Theme.warning)
            }

            if let outcome {
                outcomeView(outcome)
            }

            footer
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.slate900)
        .task { report = await app.runPreflight(request) }
    }

    private func header(_ target: CleanupTarget) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Theme.danger.opacity(0.14))
                Image(systemName: "trash.fill").foregroundStyle(Theme.danger)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Move “\(target.displayName)” to the Trash?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(abbreviatePath(target.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    SafetyBadge(level: target.safety)
                    Chip(text: "\(formatBytes(target.metrics.privateBytes)) freed when the Trash is emptied", symbol: "arrow.down.circle", tint: Theme.positive)
                }
            }
        }
    }

    @ViewBuilder
    private var checks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRE-FLIGHT CHECKS").eyebrow()
            if let report {
                ForEach(report.checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: symbol(for: check.status))
                            .foregroundStyle(color(for: check.status))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            Text(check.detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !report.processesUsingTarget.isEmpty {
                    Text("In use by: " + report.processesUsingTarget.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying identity, safety tier, open files and running apps…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 10)
    }

    private func outcomeView(_ outcome: CleanupOutcome) -> some View {
        Group {
            if outcome.succeeded {
                Label("Moved to the Trash. \(formatBytes(outcome.reclaimedPrivateBytes)) frees immediately when you empty it.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.positive)
            } else {
                Label(outcome.errorMessage ?? "The item could not be moved.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Theme.danger)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Text("Nothing is permanently deleted until you empty the Trash.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            if outcome?.succeeded == true {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    perform()
                } label: {
                    if performing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Move to Trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.danger)
                .disabled(!canProceed)
            }
        }
    }

    private var canProceed: Bool {
        guard let report, report.canProceed, !performing, outcome?.succeeded != true else { return false }
        return !request.requiresAcknowledgement || acknowledged
    }

    private func perform() {
        guard let report else { return }
        performing = true
        Task {
            outcome = await app.performCleanup(request, report: report)
            performing = false
        }
    }

    private func symbol(for status: PreflightStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(for status: PreflightStatus) -> Color {
        switch status {
        case .passed: return Theme.positive
        case .warning: return Theme.warning
        case .failed: return Theme.danger
        case .skipped: return Theme.textTertiary
        }
    }
}
