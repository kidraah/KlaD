// CleanupSheet.swift — verify, acknowledge, then move to the Trash.

import SwiftUI
import KlaDModels

struct CleanupSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: CleanupRequest

    @State private var report: PreflightReport?
    @State private var reviewed = false
    @State private var acknowledged: Set<String> = []
    @State private var performing = false
    @State private var outcome: CleanupOutcome?

    var body: some View {
        let target = request.target
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: FileIcons.icon(forPath: target.path, isDirectory: target.isDirectory))
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move “\(target.displayName)” to the Trash?")
                        .font(.headline)
                    Text("You can put it back from the Trash until you empty it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Form {
                Section {
                    LabeledContent("Freed when the Trash is emptied", value: formatBytes(target.metrics.privateBytes))
                    LabeledContent("Size on disk", value: formatBytes(target.metrics.allocatedBytes))
                    LabeledContent("Location") {
                        Text(abbreviatePath(target.path)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    if let note = request.note {
                        Text(note).foregroundStyle(.secondary)
                    }
                    if let regenerate = request.recommendation?.regenerateCommand {
                        CommandRow(command: GuidedCommand(label: "Recreate later with", command: regenerate, isDestructive: false))
                    }
                }

                if let warnings = request.recommendation?.warnings, !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }

                Section("Safety Checks") {
                    if let report {
                        ForEach(report.checks) { check in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(check.title)
                                    Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: symbol(for: check.status)).foregroundStyle(color(for: check.status))
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").foregroundStyle(.secondary)
                        }
                    }
                }

                if request.requiresReviewAcknowledgement || !(report?.acknowledgementsRequired.isEmpty ?? true) {
                    Section {
                        if request.requiresReviewAcknowledgement {
                            Toggle("I reviewed this item and don't need anything inside it", isOn: $reviewed)
                        }
                        ForEach(report?.acknowledgementsRequired ?? []) { check in
                            Toggle(check.detail, isOn: Binding(
                                get: { acknowledged.contains(check.id) },
                                set: { if $0 { acknowledged.insert(check.id) } else { acknowledged.remove(check.id) } }
                            ))
                        }
                    }
                }

                if let outcome {
                    Section {
                        if outcome.succeeded {
                            Label("Moved to the Trash.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label(outcome.errorMessage ?? "The item couldn't be moved.", systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Spacer()
                if outcome?.succeeded == true {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive) { perform() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canProceed)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 620)
        .task { report = await app.runPreflight(request) }
    }

    private var canProceed: Bool {
        guard let report, report.canProceed, !performing, outcome?.succeeded != true else { return false }
        if request.requiresReviewAcknowledgement && !reviewed { return false }
        return report.acknowledgementsRequired.allSatisfy { acknowledged.contains($0.id) }
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
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}

// MARK: - Batch

struct BatchCleanupSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: BatchCleanupRequest

    @State private var included: Set<String> = []
    @State private var running = false
    @State private var completed = 0
    @State private var results: [BatchItemResult] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move Safe Items to the Trash")
                    .font(.headline)
                Text("Every item is checked again first. Items that need your individual attention are skipped, never forced.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            List {
                if results.isEmpty {
                    ForEach(request.items) { item in
                        Toggle(isOn: Binding(
                            get: { included.contains(item.id) },
                            set: { if $0 { included.insert(item.id) } else { included.remove(item.id) } }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                    Text(abbreviatePath(item.path)).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(formatBytes(item.reclaimableBytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .disabled(running)
                    }
                } else {
                    ForEach(results) { result in
                        Label {
                            HStack {
                                Text(result.recommendation.title)
                                Spacer()
                                Text(result.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(result.succeeded ? .green : .secondary)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()
            HStack {
                if running {
                    ProgressView(value: Double(completed), total: Double(max(selectedItems.count, 1)))
                        .frame(width: 180)
                } else if !results.isEmpty {
                    let moved = results.filter(\.succeeded).count
                    Text("Moved \(moved) of \(results.count) items")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(selectedItems.count) items · \(formatBytes(selectedItems.reduce(0) { $0 + $1.reclaimableBytes }))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if results.isEmpty {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(running)
                    Button("Move to Trash", role: .destructive) { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || selectedItems.isEmpty)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
        .onAppear { included = Set(request.items.map(\.id)) }
    }

    private var selectedItems: [CleanupRecommendation] {
        request.items.filter { included.contains($0.id) }
    }

    private func run() {
        running = true
        let items = selectedItems
        Task {
            results = await app.performBatch(items) { index in completed = index }
            running = false
        }
    }
}
