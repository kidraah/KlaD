// MainWorkspaceView.swift — window shell

import AppKit
import SwiftUI
import KlaDModels

struct MainWorkspaceView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            VisualEffectBackground(material: .underWindowBackground)
                .ignoresSafeArea()
            LinearGradient(colors: [Theme.obsidian.opacity(0.92), Theme.slate900.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if app.volume != nil || app.root != nil {
                    StorageHeaderBar()
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar { toolbar }
        .sheet(item: $app.cleanupRequest) { request in
            CleanupPreFlightSheet(request: request)
                .environment(app)
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(6))
                        withAnimation(.snappy) { app.toast = nil }
                    }
            }
        }
        .animation(.snappy, value: app.toast)
        .task {
            if app.volume == nil { app.refreshVolume() }
            if let tab = LaunchOptions.tab { app.tab = tab }
            if let mode = LaunchOptions.mode { app.visualizerMode = mode }
            if let path = LaunchOptions.scanPath, app.phase == .idle {
                app.startScan(path: path)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.phase {
        case .idle:
            WelcomeView()
        case .scanning, .analyzing:
            ScanProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Back") { app.phase = .idle }
            }
        case .ready:
            switch app.tab {
            case .explore: ExploreView()
            case .saveSpace: SaveSpaceDashboardView()
            case .history: SnapshotDiffView()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var app = app
        ToolbarItem(placement: .navigation) {
            ScanTargetMenu()
        }
        ToolbarItem(placement: .principal) {
            Picker("Workspace", selection: $app.tab) {
                ForEach(AppState.Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .disabled(app.phase != .ready)
            .frame(width: 360)
        }
        ToolbarItem(placement: .primaryAction) {
            if app.isBusy {
                Button {
                    app.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop scanning")
            } else {
                Button {
                    app.startScan(path: app.root?.path ?? app.scanRootPath)
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Scan \(abbreviatePath(app.root?.path ?? app.scanRootPath)) again")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

/// Launch arguments (also used for automated visual checks):
///   --scan <path>   start scanning on launch
///   --tab explore|saveSpace|history
///   --mode sunburst|treemap
enum LaunchOptions {
    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static var scanPath: String? { value(after: "--scan").map { ($0 as NSString).expandingTildeInPath } }
    static var tab: AppState.Tab? { value(after: "--tab").flatMap(AppState.Tab.init(rawValue:)) }
    static var mode: VisualizerMode? { value(after: "--mode").flatMap(VisualizerMode.init(rawValue:)) }
}

// MARK: - Explore

struct ExploreView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if let result = app.result, result.unreadableCount > 0 {
                PermissionBanner(count: result.unreadableCount)
            }
            HSplitView {
                VisualizerPane()
                    .frame(minWidth: 480, idealWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
                VSplitView {
                    TreeTableView()
                        .frame(minHeight: 220, idealHeight: 420)
                    NodeDetailInspector()
                        .frame(minHeight: 240, idealHeight: 340)
                        .background(Theme.panel.opacity(0.6))
                }
                .frame(minWidth: 400, idealWidth: 520, maxWidth: 820)
            }
        }
    }
}

private struct PermissionBanner: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill").foregroundStyle(Theme.warning)
            Text("\(count) folder\(count == 1 ? " was" : "s were") off-limits (macOS privacy protection). Totals there are a lower bound.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Grant Full Disk Access…") { SystemActions.openFullDiskAccessSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Theme.warning.opacity(0.07))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// MARK: - Scan target

struct ScanTargetMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            Button {
                app.startScan(path: NSHomeDirectory())
            } label: {
                Label("Home Folder", systemImage: "house")
            }
            Button {
                app.startScan(path: "/")
            } label: {
                Label("Macintosh HD (entire disk)", systemImage: "internaldrive")
            }
            Divider()
            Button {
                if let path = FolderPicker.choose() { app.startScan(path: path) }
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)
        } label: {
            Label(abbreviatePath(app.root?.path ?? app.scanRootPath), systemImage: "scope")
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .disabled(app.isBusy)
        .help("Choose what to scan")
    }
}

@MainActor
enum FolderPicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder for KlaD to analyze"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 26) {
            KlaDGlyph()
                .frame(width: 132, height: 132)
            VStack(spacing: 8) {
                Text("KlaD")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("APFS storage intelligence for developers")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 14) {
                WelcomeAction(symbol: "house.fill", title: "Scan Home", subtitle: abbreviatePath(NSHomeDirectory())) {
                    app.startScan(path: NSHomeDirectory())
                }
                WelcomeAction(symbol: "internaldrive.fill", title: "Entire Disk", subtitle: "Macintosh HD") {
                    app.startScan(path: "/")
                }
                WelcomeAction(symbol: "folder.fill.badge.plus", title: "Choose Folder", subtitle: "Any directory") {
                    if let path = FolderPicker.choose() { app.startScan(path: path) }
                }
            }
            HStack(spacing: 18) {
                promise("eye", "Read-only scan")
                promise("icloud.slash", "Never downloads iCloud files")
                promise("square.on.square", "Clone- & snapshot-aware")
                promise("trash", "Deletes only to the Trash")
            }
            .padding(.top, 6)
        }
        .padding(40)
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
    }
}

private struct WelcomeAction: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .frame(width: 170, height: 132)
            .glassPanel(radius: 14, fill: hovering ? Theme.panelRaised : Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
    }
}

/// The KlaD mark: concentric category arcs.
struct KlaDGlyph: View {
    var animate = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !animate)) { timeline in
            let phase = animate ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) / 12 * 2 * .pi : 0
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let rings: [[(UInt32, Double)]] = [
                    [(0x06B6D4, 0.34), (0x8B5CF6, 0.22), (0x3B82F6, 0.18), (0xF59E0B, 0.14), (0x10B981, 0.12)],
                    [(0x06B6D4, 0.2), (0x0EA5E9, 0.14), (0x8B5CF6, 0.16), (0xF97316, 0.12), (0x3B82F6, 0.1), (0xF59E0B, 0.1), (0x64748B, 0.18)],
                    [(0x06B6D4, 0.12), (0x22D3EE, 0.08), (0x8B5CF6, 0.1), (0xA78BFA, 0.06), (0xF97316, 0.08), (0x3B82F6, 0.1), (0xF59E0B, 0.06), (0x10B981, 0.08), (0x64748B, 0.32)],
                ]
                for (ringIndex, ring) in rings.enumerated() {
                    let inner = radius * (0.30 + CGFloat(ringIndex) * 0.235)
                    let outer = inner + radius * 0.205
                    var angle = phase * Double(ringIndex % 2 == 0 ? 1 : -1) * 0.5
                    for (hex, fraction) in ring {
                        let span = fraction * 2 * .pi
                        let path = SunburstGeometry.sectorPath(center: center, inner: inner, outer: outer,
                                                               start: angle + 0.02, end: angle + span - 0.02)
                        context.fill(path, with: .color(Color(hex: hex).opacity(1 - Double(ringIndex) * 0.18)))
                        angle += span
                    }
                }
                let core = Path(ellipseIn: CGRect(x: center.x - radius * 0.2, y: center.y - radius * 0.2, width: radius * 0.4, height: radius * 0.4))
                context.fill(core, with: .color(Theme.obsidian))
                context.stroke(core, with: .color(Theme.accent.opacity(0.6)), lineWidth: 1.5)
            }
        }
        .shadow(color: Theme.accent.opacity(0.25), radius: 24)
    }
}

// MARK: - Scan progress

struct ScanProgressView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let p = app.progress
        VStack(spacing: 24) {
            KlaDGlyph(animate: true)
                .frame(width: 150, height: 150)
            VStack(spacing: 6) {
                Text(app.phase == .analyzing ? "Classifying & building intelligence…" : "Scanning \(abbreviatePath(app.scanRootPath))")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(abbreviatePath(p.currentPath))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 560)
            }
            HStack(spacing: 28) {
                MetricReadout(label: "Files", value: formatCount(p.filesScanned))
                MetricReadout(label: "Folders", value: formatCount(p.directoriesScanned))
                MetricReadout(label: "Allocated", value: formatBytes(p.allocatedBytes), tint: Theme.accent)
                if p.cloudStubBytes > 0 {
                    MetricReadout(label: "In iCloud", value: formatBytes(p.cloudStubBytes), tint: Theme.info)
                }
                MetricReadout(label: "Rate", value: "\(formatCount(UInt64(p.itemsPerSecond)))/s")
                MetricReadout(label: "Elapsed", value: String(format: "%.1fs", p.elapsed))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .glassPanel(radius: 12)
            Button("Stop") { app.cancelScan() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Text("Using getattrlistbulk(2): one syscall returns hundreds of entries with APFS private sizes, clone IDs and iCloud flags.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(40)
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(toast.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(toast.detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassPanel(radius: 12, fill: Theme.panelRaised)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}
