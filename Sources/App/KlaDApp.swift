// KlaDApp.swift — entry point. Follows the system appearance and accent color.

import AppKit
import SwiftUI
import KlaDModels
import KlaDScanner
import KlaDStorageOps

@main
struct KlaDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState(
        cache: try? ScanCacheStore(directory: ScanCacheStore.defaultDirectory()),
        forecaster: StorageForecaster()
    )

    var body: some Scene {
        WindowGroup("KlaD", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            SidebarCommands()
            InspectorCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Analyze Macintosh HD") { app.open(.disk) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Analyze Home Folder") { app.open(.home) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Analyze Folder…") {
                    if let path = FolderPicker.choose() { app.open(app.addLocation(path: path)) }
                }
                .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Rescan") { app.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(app.currentLocation == nil || app.isBusy)
            }
            CommandGroup(after: .toolbar) {
                Picker("Chart", selection: $app.visualizerMode) {
                    ForEach(VisualizerMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Size By", selection: $app.measure) {
                    ForEach(SizeMeasure.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Color By", selection: $app.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
                }
                Button("Zoom Out") { app.drillUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Kernel-level guarantee: nothing in this process can materialize an
        // iCloud placeholder (SF_DATALESS) — reads fail instead of downloading.
        DatalessMaterializationGuard.engageProcessWide()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
