// ContentView.swift — the main window: sidebar · detail · inspector.

import AppKit
import SwiftUI
import KlaDModels

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            DetailView()
                .inspector(isPresented: $app.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
                }
        }
        .navigationTitle(app.currentLocation?.title ?? "KlaD")
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar() }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search")
        .sheet(item: $app.cleanupRequest) { request in
            CleanupSheet(request: request)
        }
        .sheet(item: $app.batchRequest) { request in
            BatchCleanupSheet(request: request)
        }
        .task {
            LaunchOptions.applyAppearance()
            if let tab = LaunchOptions.section { app.sidebarSelection = .section(tab) }
            if let mode = LaunchOptions.mode { app.visualizerMode = mode }
            if let path = LaunchOptions.scanPath {
                let location = path == "/" ? ScanLocation.disk
                    : (path == NSHomeDirectory() ? ScanLocation.home : app.addLocation(path: path))
                app.open(location, forceRescan: LaunchOptions.forceRescan)
            } else {
                await app.restoreLastSession()
            }
        }
    }

    private var subtitle: String {
        switch app.phase {
        case .scanning: return "Scanning…"
        case .analyzing: return "Analyzing…"
        case .loading: return "Opening…"
        default:
            guard let scannedAt = app.scannedAt, let root = app.root else { return "" }
            let age = Date().timeIntervalSince(scannedAt) < 90 ? "Scanned just now" : "Scanned \(relativeDate(scannedAt))"
            return "\(age) · \(formatCount(root.metrics.itemCount)) items"
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .idle where app.root == nil:
                WelcomeView()
            case .scanning, .analyzing, .loading:
                ScanningView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Scan", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Choose Another Location") { app.phase = .idle }
                }
            default:
                if !app.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsView()
                } else {
                    sectionView
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    private var sectionView: some View {
        switch app.section {
        case .overview: OverviewView()
        case .recommendations: RecommendationsView()
        case .largestFiles: LargestFilesView()
        case .fileTypes: FileTypesView()
        case .similarFolders: SimilarFoldersView()
        case .duplicates: DuplicatesView()
        case .whereIsMySpace: WhereIsMySpaceView()
        case .history: HistoryView()
        }
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var app

    var body: some ToolbarContent {
        @Bindable var app = app
        if app.section == .overview && app.hasResults && app.searchText.isEmpty {
            ToolbarItem(placement: .principal) {
                Picker("Chart", selection: $app.visualizerMode) {
                    ForEach(VisualizerMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Chart style")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Size By", selection: $app.measure) {
                        ForEach(SizeMeasure.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Color By", selection: $app.colorMode) {
                        ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label("View Options", systemImage: "slider.horizontal.3")
                }
                .help("Size and color options")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if app.isBusy {
                Button {
                    app.cancelScan()
                } label: {
                    Label("Stop", systemImage: "xmark")
                }
                .help("Stop scanning")
            } else {
                Button {
                    app.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(app.currentLocation == nil)
                .help("Scan this location again")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                app.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(app.showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }
}

// MARK: - Launch options (also used for automated visual checks)

enum LaunchOptions {
    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// `--scan <path>`
    static var scanPath: String? { value(after: "--scan").map { ($0 as NSString).expandingTildeInPath } }
    /// `--rescan` forces a fresh scan instead of the cached one.
    static var forceRescan: Bool { ProcessInfo.processInfo.arguments.contains("--rescan") }
    /// `--section overview|recommendations|…`
    static var section: InsightSection? { value(after: "--section").flatMap(InsightSection.init(rawValue:)) }
    /// `--mode sunburst|treemap`
    static var mode: VisualizerMode? { value(after: "--mode").flatMap(VisualizerMode.init(rawValue:)) }

    /// `--appearance light|dark` — testing aid; normally KlaD follows the system.
    @MainActor
    static func applyAppearance() {
        switch value(after: "--appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
}

// MARK: - Folder picker

@MainActor
enum FolderPicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        panel.message = "Choose a folder or volume to analyze."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
