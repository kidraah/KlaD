// SaveSpaceDashboardView.swift — tiered, evidence-first cleanup hub

import SwiftUI
import KlaDModels

struct SaveSpaceDashboardView: View {
    @Environment(AppState.self) private var app
    @State private var categoryFilter: StorageCategory?

    private let tiers: [(SafetyLevel, String, String)] = [
        (.safeToClear, "Regeneratable Build Artifacts & Caches", "Positive manifest or tool evidence — recreated by a single command."),
        (.reviewFirst, "Reviewable Model & Archive Bloat", "Reclaimable, but may cost large re-downloads or hold artifacts worth keeping."),
        (.guidedExternalAction, "Guided Container, VM & Snapshot Optimization", "Owned by another tool — KlaD shows the right command instead of touching the file."),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                hero
                filterBar
                ForEach(tiers, id: \.0) { tier in
                    let items = filtered(app.recommendations(for: tier.0))
                    if !items.isEmpty {
                        TierSection(level: tier.0, title: tier.1, subtitle: tier.2, items: items)
                    }
                }
                DuplicatesSection()
            }
            .padding(22)
        }
        .scrollContentBackground(.hidden)
    }

    private func filtered(_ items: [CleanupRecommendation]) -> [CleanupRecommendation] {
        guard let categoryFilter else { return items }
        return items.filter { $0.category == categoryFilter }
    }

    private var hero: some View {
        let safe = app.reclaimable(for: .safeToClear)
        let review = app.reclaimable(for: .reviewFirst)
        let guided = app.recommendations(for: .guidedExternalAction).reduce(0) { $0 + $1.metrics.allocatedBytes }
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SAVE SPACE").eyebrow()
                (Text(formatBytes(safe)).foregroundColor(Theme.positive)
                 + Text(" can be cleared safely").foregroundColor(Theme.textPrimary))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Only items with positive, deterministic evidence are marked safe. Everything moves to the Trash — nothing is permanently deleted until you empty it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer()
            HStack(spacing: 10) {
                TierStat(level: .safeToClear, bytes: safe, count: app.recommendations(for: .safeToClear).count)
                TierStat(level: .reviewFirst, bytes: review, count: app.recommendations(for: .reviewFirst).count)
                TierStat(level: .guidedExternalAction, bytes: guided, count: app.recommendations(for: .guidedExternalAction).count)
            }
        }
        .padding(18)
        .glassPanel(radius: 14, fill: Theme.panelRaised)
    }

    private var filterBar: some View {
        let categories = Array(Set(app.recommendations.map(\.category))).sorted()
        return HStack(spacing: 6) {
            Button {
                categoryFilter = nil
            } label: {
                Chip(text: "All", tint: categoryFilter == nil ? Theme.accent : Theme.textSecondary, filled: categoryFilter == nil)
            }
            .buttonStyle(.plain)
            ForEach(categories) { category in
                Button {
                    categoryFilter = categoryFilter == category ? nil : category
                } label: {
                    Chip(text: category.displayName, symbol: category.symbolName,
                         tint: categoryFilter == category ? category.color : Theme.textSecondary,
                         filled: categoryFilter == category)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if app.reclaimedThisSession > 0 {
                Chip(text: "\(formatBytes(app.reclaimedThisSession)) reclaimed this session", symbol: "checkmark.circle.fill",
                     tint: Theme.positive, filled: true)
            }
        }
    }
}

private struct TierStat: View {
    let level: SafetyLevel
    let bytes: UInt64
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SafetyBadge(level: level)
                .fixedSize()
            Text(formatBytes(bytes))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text("\(count) item\(count == 1 ? "" : "s")")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(12)
        .frame(width: 176, alignment: .leading)
        .glassPanel(radius: 10, fill: level.color.opacity(0.06))
    }
}

private struct TierSection: View {
    let level: SafetyLevel
    let title: String
    let subtitle: String
    let items: [CleanupRecommendation]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: level.symbolName).foregroundStyle(level.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text(formatBytes(items.reduce(0) { $0 + (level == .guidedExternalAction ? $1.metrics.allocatedBytes : $1.reclaimableBytes) }))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(level.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 640), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        RecommendationCard(recommendation: item)
                    }
                }
            }
        }
    }
}

struct RecommendationCard: View {
    @Environment(AppState.self) private var app
    let recommendation: CleanupRecommendation
    @State private var showCommands = false
    @State private var hovering = false

    var body: some View {
        let rec = recommendation
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rec.category.color.opacity(0.15))
                    Image(systemName: rec.group.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(rec.category.color)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(abbreviatePath(rec.path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rec.path)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(rec.metrics.allocatedBytes == 0 && rec.safety == .guidedExternalAction
                         ? "—" : formatBytes(rec.safety == .guidedExternalAction ? rec.metrics.allocatedBytes : rec.reclaimableBytes))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    if rec.safety != .guidedExternalAction && rec.metrics.sharedBytes > rec.metrics.allocatedBytes / 20 {
                        Text("of \(formatBytes(rec.metrics.allocatedBytes)) allocated")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warning)
                            .help("Part of this is shared with clones, snapshots or hard links and won't be freed immediately.")
                    } else {
                        Text(rec.safety == .guidedExternalAction ? (rec.metrics.allocatedBytes == 0 ? "managed by macOS" : "on disk") : "reclaimable")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            Text(rec.rationale)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if !rec.evidence.isEmpty || !rec.signals.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(Array(rec.evidence.prefix(3).enumerated()), id: \.offset) { _, evidence in
                        Chip(text: evidence.detail, symbol: "checkmark.seal.fill", tint: Theme.positive)
                    }
                    ForEach(Array(rec.signals.enumerated()), id: \.offset) { _, signal in
                        SignalChip(signal: signal)
                    }
                }
            }

            if let regenerate = rec.regenerateCommand {
                CommandSnippet(command: regenerate, caption: "Recreate with")
            }

            ForEach(rec.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                SafetyBadge(level: rec.safety)
                Spacer()
                Button {
                    SystemActions.reveal(rec.path)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Reveal in Finder")
                Button {
                    app.reveal(path: rec.path)
                } label: {
                    Image(systemName: "circle.circle")
                }
                .help("Show in Explore")
                switch rec.action {
                case .moveToTrash where rec.isTrashable:
                    Button {
                        app.requestCleanup(rec)
                    } label: {
                        Label("Move to Trash…", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(rec.safety == .safeToClear ? Theme.positive.opacity(0.85) : Theme.warning.opacity(0.85))
                case .guided(let remediation):
                    Button {
                        showCommands.toggle()
                    } label: {
                        Label("Show Commands", systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.info.opacity(0.85))
                    .popover(isPresented: $showCommands, arrowEdge: .bottom) {
                        GuidedRemediationView(remediation: remediation)
                    }
                default:
                    EmptyView()
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(14)
        .glassPanel(radius: 12, fill: hovering ? Theme.panelRaised : Theme.panel)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(rec.safety.color).frame(width: 3).padding(.vertical, 14)
        }
        .onHover { hovering = $0 }
    }
}

struct CommandSnippet: View {
    let command: String
    var caption: String? = nil
    var destructive = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            if let caption {
                Text(caption).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 6) {
                Text("$").foregroundStyle(destructive ? Theme.danger : Theme.accent)
                Text(command).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .font(.system(size: 11, design: .monospaced))
            Spacer(minLength: 4)
            Button {
                SystemActions.copy(command)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(copied ? Theme.positive : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy command")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(destructive ? Theme.danger.opacity(0.3) : Theme.hairline, lineWidth: 1))
    }
}

struct GuidedRemediationView: View {
    let remediation: GuidedRemediation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(remediation.headline, systemImage: "terminal.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.info)
            Text(remediation.explanation)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(remediation.commands) { command in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if command.isDestructive {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                        }
                        Text(command.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(command.isDestructive ? Theme.danger : Theme.textPrimary)
                    }
                    CommandSnippet(command: command.command, destructive: command.isDestructive)
                }
            }
            if let bundleID = remediation.applicationBundleID {
                Button {
                    SystemActions.openApplication(bundleID: bundleID)
                } label: {
                    Label("Open App", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
            Text("KlaD never deletes these files itself — run the commands in Terminal after reading them.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .frame(width: 460)
    }
}

// MARK: - Duplicates

private struct DuplicatesSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc.fill").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Files").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Byte-identical files ≥ 1 MB, verified by SHA-256. iCloud placeholders are never opened; APFS clones are not counted as waste.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if app.isFindingDuplicates {
                    if let progress = app.duplicateProgress {
                        Text("\(progress.phase.rawValue) \(progress.filesProcessed)/\(progress.filesTotal)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ProgressView().controlSize(.small)
                    Button("Stop") { app.cancelDuplicates() }.controlSize(.small)
                } else {
                    if app.duplicatesSearched {
                        Text(formatBytes(app.duplicateReclaimable))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.warning)
                    }
                    Button {
                        app.findDuplicates()
                    } label: {
                        Label(app.duplicatesSearched ? "Search Again" : "Find Duplicates", systemImage: "magnifyingglass")
                    }
                    .controlSize(.small)
                    .disabled(app.root == nil)
                }
            }
            if app.duplicatesSearched && !app.isFindingDuplicates && app.duplicateGroups.isEmpty {
                Text("No duplicates found.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            ForEach(app.duplicateGroups.prefix(60)) { group in
                DuplicateGroupRow(group: group)
            }
        }
    }
}

private struct DuplicateGroupRow: View {
    @Environment(AppState.self) private var app
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((group.paths.first.map { ($0 as NSString).lastPathComponent }) ?? "—")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Chip(text: "\(group.paths.count) copies × \(formatBytes(group.fileSize))")
                Spacer()
                Text("\(formatBytes(group.reclaimableBytes)) reclaimable")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.warning)
            }
            ForEach(Array(group.paths.enumerated()), id: \.element) { index, path in
                HStack(spacing: 8) {
                    Image(systemName: index == 0 ? "star.fill" : "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(index == 0 ? Theme.positive : Theme.textTertiary)
                        .help(index == 0 ? "Oldest copy — kept" : "Duplicate")
                    Text(abbreviatePath(path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        SystemActions.reveal(path)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    if index > 0 {
                        Button("Trash…") { app.requestDuplicateCleanup(path: path, in: group) }
                            .controlSize(.mini)
                    }
                }
            }
        }
        .padding(12)
        .glassPanel(radius: 10)
    }
}
