// InsightViews.swift — Largest Files, File Types, Similar Folders, Duplicates,
// Where Is My Space.

import SwiftUI
import UniformTypeIdentifiers
import KlaDModels

// MARK: - Largest files

struct LargestFilesView: View {
    @Environment(AppState.self) private var app
    @State private var selection: String?

    var body: some View {
        if app.largestFiles.isEmpty {
            ContentUnavailableView("No Files", systemImage: "doc", description: Text("Nothing large was found here."))
        } else {
            Table(app.largestFiles, selection: $selection) {
                TableColumn("Name") { entry in
                    HStack(spacing: 6) {
                        Image(nsImage: FileIcons.icon(forPath: entry.path, isDirectory: false))
                            .resizable().frame(width: 16, height: 16)
                        Text((entry.path as NSString).lastPathComponent).lineLimit(1)
                    }
                }
                .width(min: 160, ideal: 260)
                TableColumn("Size") { entry in
                    Text(formatBytes(entry.metrics.allocatedBytes)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 84)
                TableColumn("Kind") { entry in
                    Text(entry.category.displayName).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Modified") { entry in
                    Text(Date(timeIntervalSince1970: TimeInterval(entry.modificationTime)), format: .dateTime.day().month(.abbreviated).year())
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Location") { entry in
                    Text(abbreviatePath((entry.path as NSString).deletingLastPathComponent))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .contextMenu(forSelectionType: String.self) { paths in
                if let path = paths.first { PathContextMenu(path: path) }
            } primaryAction: { paths in
                if let path = paths.first { app.reveal(path: path) }
            }
            .onChange(of: selection) { _, path in
                if let path, let node = app.root?.descendant(atPath: path) { app.select(node) }
            }
        }
    }
}

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

// MARK: - File types

struct FileTypesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let total = max(app.fileTypes.reduce(0) { $0 + $1.metrics.allocatedBytes }, 1)
        if app.fileTypes.isEmpty {
            ContentUnavailableView("No Files", systemImage: "square.grid.2x2")
        } else {
            Table(app.fileTypes) {
                TableColumn("Type") { type in
                    HStack(spacing: 6) {
                        Image(nsImage: FileIcons.typeIcon(type.key.isEmpty ? .data : (UTType(filenameExtension: type.key) ?? .data)))
                            .resizable().frame(width: 16, height: 16)
                        Text(type.key.isEmpty ? "No Extension" : "." + type.key)
                        if let description = UTType(filenameExtension: type.key)?.localizedDescription, !type.key.isEmpty {
                            Text(description).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 180, ideal: 280)
                TableColumn("Files") { type in
                    Text(type.fileCount.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Size") { type in
                    Text(formatBytes(type.metrics.allocatedBytes)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Share") { type in
                    Gauge(value: Double(type.metrics.allocatedBytes) / Double(total)) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(type.category.color)
                }
                .width(min: 80, ideal: 140)
            }
        }
    }
}

// MARK: - Similar folders

struct SimilarFoldersView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.similarFolders.isEmpty {
            ContentUnavailableView("No Similar Folders", systemImage: "folder.badge.questionmark",
                                   description: Text("KlaD looks for copies like “project”, “project copy” and “project_v2” larger than 50 MB."))
        } else {
            Form {
                Section {
                    LabeledContent("Could be reclaimed by keeping one copy of each",
                                   value: formatBytes(app.similarFolders.reduce(0) { $0 + $1.reclaimableBytes }))
                } footer: {
                    Text("These are hints. Compare the folders before removing anything; the first folder in each group looks like the original.")
                }
                ForEach(app.similarFolders) { group in
                    Section {
                        ForEach(Array(group.folders.enumerated()), id: \.element.path) { index, folder in
                            HStack(spacing: 8) {
                                Image(nsImage: FileIcons.typeIcon(.folder)).resizable().frame(width: 16, height: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((folder.path as NSString).lastPathComponent)
                                    Text(abbreviatePath((folder.path as NSString).deletingLastPathComponent))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                if index == 0 {
                                    Text("Original").font(.caption).foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                                Spacer()
                                Text(formatBytes(folder.metrics.allocatedBytes)).monospacedDigit().foregroundStyle(.secondary)
                                Button("Show in Finder") { SystemActions.reveal(folder.path) }
                                    .buttonStyle(.borderless)
                                if index > 0 && app.mayModify(path: folder.path) {
                                    Button("Move to Trash…") {
                                        app.requestReviewCleanup(path: folder.path,
                                                                 note: "Similar to \(abbreviatePath(group.folders[0].path))")
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Text(group.kind == .identicalContents ? "Identical contents" : "Name variants, \(Int(group.similarity * 100))% alike")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatBytes(group.reclaimableBytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
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
                        Text("Compares files over 1 MB byte for byte. iCloud-only files are never opened, and APFS clones don't count — they already share space.")
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

// MARK: - Where is my space

struct WhereIsMySpaceView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let home = NSHomeDirectory()
        Form {
            if let volume = app.volume {
                Section {
                    LabeledContent("Capacity", value: formatBytes(volume.totalCapacity))
                    LabeledContent("Used", value: formatBytes(volume.usedCapacity))
                    LabeledContent("Counted by this scan", value: formatBytes(app.scannedMetrics.allocatedBytes))
                    LabeledContent("Available now", value: formatBytes(volume.availableCapacity))
                    if volume.purgeableCapacity > 0 {
                        LabeledContent("Purgeable", value: formatBytes(volume.purgeableCapacity))
                    }
                } header: {
                    Text(volume.volumeName)
                } footer: {
                    Text("Purgeable space is freed by macOS automatically when it's needed. Files cloned with APFS are counted in full for each copy but stored once, so scanned totals can exceed what the disk reports.")
                }
            }

            if !app.opaqueNodes.isEmpty {
                Section {
                    ForEach(app.opaqueNodes) { node in
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(node.name, value: formatBytes(node.metrics.allocatedBytes))
                            Text(node.annotation?.reason ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sized by APFS, Not Opened")
                } footer: {
                    Text("KlaD reads these totals from macOS's own volume accounting, the same numbers System Settings › Storage uses.")
                }
            } else if let volume = app.volume, !volume.containerVolumes.isEmpty {
                Section("Other Volumes in This Container") {
                    ForEach(volume.containerVolumes.filter { !$0.roles.contains("Data") }) { item in
                        LabeledContent(item.name, value: formatBytes(item.capacityInUse))
                    }
                }
            }

            if !app.protectedNodes.isEmpty {
                Section {
                    ForEach(app.protectedNodes) { node in
                        let location = SystemPolicy.protectedLocation(containing: node.path, home: home)
                        DisclosureGroup {
                            if let guidance = location?.guidance {
                                GuidanceView(remediation: guidance)
                            } else {
                                Text("Managed by macOS. Nothing to do here.").foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(location?.title ?? node.name)
                                    Text(location?.explanation ?? abbreviatePath(node.path))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Private Data, Never Opened")
                } footer: {
                    Text("KlaD never opens these folders — with or without Full Disk Access — so it can't size them. Manage them with the apps shown.")
                }
            }

            if let snapshots = app.volume?.localSnapshotNames, !snapshots.isEmpty {
                Section("Local Snapshots") {
                    ForEach(snapshots, id: \.self) { name in
                        Text(name).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
