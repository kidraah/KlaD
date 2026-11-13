// DuplicatesView.swift — identical files (oldest copy kept).

import SwiftUI
import KlaDModels

/// Context menu for a path-based row.
struct PathContextMenu: View {
    @Environment(AppState.self) private var app
    let path: String

    var body: some View {
        Button("Show in Overview") { app.reveal(path: path) }
        Button("Show in Finder") { SystemActions.reveal(path) }
        Button("Copy Path") { SystemActions.copy(path) }
        if let node = app.root?.descendant(atPath: path), app.canTrash(node) {
            Divider()
            Button("Move to Trash…") { app.requestCleanup(node: node) }
        }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Identical Files")
                        Text("Compares files over 1 MB byte for byte. iCloud-only files are never opened, and APFS clones don't count — they already share space. The oldest copy is kept.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.isFindingDuplicates {
                        if let p = app.duplicateProgress {
                            Text("\(p.filesProcessed) of \(p.filesTotal)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView().controlSize(.small)
                        Button("Stop") { app.cancelDuplicates() }
                    } else {
                        Button(app.duplicatesSearched ? "Search Again" : "Find Duplicates") { app.findDuplicates() }
                    }
                }
                if app.duplicatesSearched && !app.isFindingDuplicates {
                    LabeledContent("Reclaimable by keeping one copy", value: formatBytes(app.duplicateReclaimable))
                }
            }
            if app.duplicatesSearched && !app.isFindingDuplicates && app.duplicateGroups.isEmpty {
                Section { Text("No duplicates found.").foregroundStyle(.secondary) }
            }
            ForEach(app.duplicateGroups.prefix(100)) { group in
                Section {
                    ForEach(Array(group.paths.enumerated()), id: \.element) { index, path in
                        HStack(spacing: 8) {
                            Image(nsImage: FileIcons.icon(forPath: path, isDirectory: false)).resizable().frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent)
                                Text(abbreviatePath((path as NSString).deletingLastPathComponent))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            if index == 0 {
                                Text("Keep").font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            Spacer()
                            Button("Show in Finder") { SystemActions.reveal(path) }
                                .buttonStyle(.borderless)
                            if index > 0 && app.mayModify(path: path) {
                                Button("Move to Trash…") {
                                    app.requestReviewCleanup(path: path, note: "Identical to \(abbreviatePath(group.paths[0]))")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("\(group.paths.count) copies of \(formatBytes(group.fileSize))")
                        Spacer()
                        Text(formatBytes(group.reclaimableBytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
