// SidebarView.swift — source list: locations, then insights for the current one.

import SwiftUI
import KlaDModels

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var lastSection: InsightSection = .overview

    var body: some View {
        @Bindable var app = app
        List(selection: $app.sidebarSelection) {
            Section("Locations") {
                ForEach(app.locations) { location in
                    HStack {
                        Label(location.title, systemImage: location.symbol)
                        Spacer()
                        if app.isBusy && app.currentLocation == location {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .tag(SidebarItem.location(location.path))
                    .contextMenu {
                        Button("Rescan") { app.open(location, forceRescan: true) }
                        if location.path != "/" {
                            Button("Show in Finder") { SystemActions.reveal(location.path) }
                        }
                        if !([ScanLocation.disk, .home].contains(location)) {
                            Divider()
                            Button("Remove from Sidebar") { app.removeLocation(location) }
                        }
                    }
                }
            }

            if app.hasResults {
                Section(app.currentLocation?.title ?? "Results") {
                    ForEach(InsightSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .badge(badge(for: section))
                            .tag(SidebarItem.section(section))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    if let path = FolderPicker.choose() {
                        app.open(app.addLocation(path: path))
                    }
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Analyze another folder or volume")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: app.sidebarSelection) { old, new in
            switch new {
            case .location(let path):
                if case .section(let previous) = old { lastSection = previous }
                if let location = app.locations.first(where: { $0.path == path }) {
                    app.open(location)
                }
                app.sidebarSelection = .section(lastSection)
            case .section(let section):
                lastSection = section
            case nil:
                break
            }
        }
    }

    private func badge(for section: InsightSection) -> Int {
        switch section {
        case .recommendations: return app.recommendations(for: .safeToClear).count
        case .similarFolders: return app.similarFolders.count
        case .duplicates: return app.duplicateGroups.count
        default: return 0
        }
    }
}

// MARK: - Welcome & scanning

struct WelcomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("Choose What to Analyze", systemImage: "internaldrive")
        } description: {
            Text("KlaD maps your storage with APFS-accurate sizes. It only reads sizes, never needs Full Disk Access, and never opens private or system data.")
        } actions: {
            Button("Macintosh HD") { app.open(.disk) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Home Folder") { app.open(.home) }
                .controlSize(.large)
            Button("Choose Folder…") {
                if let path = FolderPicker.choose() { app.open(app.addLocation(path: path)) }
            }
            .buttonStyle(.link)
        }
    }
}

struct ScanningView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let p = app.progress
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title3.weight(.semibold))
            if app.phase == .scanning {
                Text("\(formatCount(p.filesScanned + p.directoriesScanned)) items · \(formatBytes(p.allocatedBytes))")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(abbreviatePath(p.currentPath))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 480)
            }
            Button("Stop") { app.cancelScan() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        let name = app.currentLocation?.title ?? "Location"
        switch app.phase {
        case .loading: return "Opening “\(name)”…"
        case .analyzing: return "Analyzing “\(name)”…"
        default: return "Scanning “\(name)”…"
        }
    }
}
