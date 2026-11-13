// SettingsView.swift — the Settings window.

import SwiftUI
import KlaDModels

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ExclusionSettings()
                .tabItem { Label("Exclusions", systemImage: "eye.slash") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 440)
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Picker("Appearance", selection: $app.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Update automatically when files change", isOn: $app.liveUpdates)
            Toggle("Use low priority for background updates", isOn: $app.gentleRescans)
            Picker("Keep scan history", selection: $app.historyLimit) {
                Text("10 scans").tag(10)
                Text("30 scans").tag(30)
                Text("60 scans").tag(60)
                Text("120 scans").tag(120)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExclusionSettings: View {
    @Environment(AppState.self) private var app
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                List(app.excludedPaths, id: \.self, selection: $selection) { path in
                    Label(abbreviatePath(path), systemImage: "folder")
                }
                .frame(minHeight: 200)
                HStack {
                    Button {
                        if let path = FolderPicker.choose(), !app.excludedPaths.contains(path) { app.excludedPaths.append(path) }
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let selection { app.excludedPaths.removeAll { $0 == selection } }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("Excluded folders aren't scanned. Changes apply to the next scan.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section {
                Label("KlaD only reads file sizes and dates. It never reads file contents, except when you ask it to find duplicates.", systemImage: "eye")
                Label("KlaD never needs Full Disk Access.", systemImage: "lock.open")
                Label("System files and the folders below are never opened, changed or deleted.", systemImage: "lock.shield")
                Label("KlaD can only move items inside your home folder to the Trash, after checking them again.", systemImage: "trash")
                Label("Nothing leaves your Mac.", systemImage: "network.slash")
            }
            Section("Never Opened") {
                ForEach(SystemPolicy.protectedLocations(home: NSHomeDirectory())) { location in
                    LabeledContent(location.title) {
                        Text(abbreviatePath(location.path)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
