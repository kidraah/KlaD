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
                .inspector(isPresented: Binding(
                    get: { app.showInspector && app.sidebarSelection != .uninstaller },
                    set: { app.showInspector = $0 }
                )) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
                }
        }
        .navigationTitle(app.currentLocation?.title ?? "KlaD")
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar() }
        .sheet(item: $app.cleanupRequest) { request in
            CleanupSheet(request: request)
        }
        .task {
            app.appearance.apply()
            LaunchOptions.applyAppearance()
            if let section = LaunchOptions.section { app.sidebarSelection = .section(section) }
            if let name = LaunchOptions.uninstallerApp {
                app.sidebarSelection = .uninstaller
                if LaunchOptions.demo {
                    app.uninstaller.demoAllowlist = ["Blender", "Docker", "Google Chrome", "Notion", "VLC", "Visual Studio Code",
                                                     "Slack", "Spotify", "Figma", "Zoom", "Android Studio", "OBS", "Discord", "Firefox"]
                }
                app.uninstaller.loadApps()
                for _ in 0..<100 where app.uninstaller.apps.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                app.uninstaller.selectedAppID = app.uninstaller.apps.first { $0.name == name }?.id
            }
            if let mode = LaunchOptions.mode { app.visualizerMode = mode }
            if LaunchOptions.demo {
                app.loadDemo()
                if LaunchOptions.uninstallerApp != nil { app.sidebarSelection = .uninstaller }
                if let focus = LaunchOptions.focusPath, let node = app.root?.descendant(atPath: DemoData.home + "/" + focus) {
                    app.drill(into: node)
                }
                if let select = LaunchOptions.selectPath, let node = app.root?.descendant(atPath: DemoData.home + "/" + select) {
                    app.select(node)
                }
            } else if let path = LaunchOptions.scanPath {
                let location = path == "/" ? ScanLocation.disk
                    : (path == NSHomeDirectory() ? ScanLocation.home : app.addLocation(path: path))
                app.open(location)
            }
        }
    }

    private var subtitle: String {
        switch app.phase {
        case .scanning: return "Scanning…"
        case .analyzing: return "Analyzing…"
        default:
            guard app.scannedAt != nil, let root = app.root else { return "" }
            return "\(formatCount(root.metrics.itemCount)) items · \(formatBytes(root.metrics.allocatedBytes))"
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.sidebarSelection == .uninstaller {
                AppUninstallerView()
            } else {
                locationContent
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    private var locationContent: some View {
        Group {
            switch app.phase {
            case .idle where app.root == nil:
                WelcomeView()
            case .scanning, .analyzing:
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
                switch app.section {
                case .overview: OverviewView()
                case .recommendations: RecommendationsView()
                case .duplicates: DuplicatesView()
                case .history: HistoryView()
                }
            }
        }
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var app

    var body: some ToolbarContent {
        @Bindable var app = app
        if app.section == .overview && app.hasResults && app.sidebarSelection != .uninstaller {
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
                } label: {
                    Label("Size By", systemImage: "slider.horizontal.3")
                }
                .help("What sizes the chart")
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
        if app.sidebarSelection != .uninstaller {
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
    /// `--section overview|recommendations|duplicates|history`
    static var section: InsightSection? { value(after: "--section").flatMap(InsightSection.init(rawValue:)) }
    /// `--uninstaller <App Name>` opens the uninstaller with that app selected (testing aid; removes nothing).
    static var uninstallerApp: String? { value(after: "--uninstaller") }
    /// `--demo` fictional data; `--focus <rel path>` / `--select <rel path>` inside it.
    static var demo: Bool { ProcessInfo.processInfo.arguments.contains("--demo") }
    static var focusPath: String? { value(after: "--focus") }
    static var selectPath: String? { value(after: "--select") }
    /// `--mode sunburst|treemap`
    static var mode: VisualizerMode? { value(after: "--mode").flatMap(VisualizerMode.init(rawValue:)) }

    /// `--appearance light|dark` — testing aid; overrides the setting for this launch.
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
