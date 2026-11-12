// KlaDApp.swift — entry point

import AppKit
import SwiftUI
import KlaDModels
import KlaDScanner

@main
struct KlaDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("KlaD", id: "main") {
            MainWorkspaceView()
                .environment(app)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1480, height: 940)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Home Folder") { app.startScan(path: NSHomeDirectory()) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Scan Entire Disk") { app.startScan(path: "/") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Choose Folder…") {
                    if let path = FolderPicker.choose() { app.startScan(path: path) }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Visualize") {
                Button("Sunburst") { app.visualizerMode = .sunburst }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Treemap") { app.visualizerMode = .treemap }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("Zoom Out") { app.drillUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Picker("Size By", selection: $app.measure) {
                    ForEach(SizeMeasure.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Kernel-level guarantee: nothing in this process can materialize an
        // iCloud placeholder (SF_DATALESS) — reads fail instead of downloading.
        DatalessMaterializationGuard.engageProcessWide()
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
