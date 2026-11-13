// AppUninstallerView.swift — remove an app and everything it left behind.

import AppKit
import SwiftUI
import KlaDModels

struct AppUninstallerView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let uninstaller = app.uninstaller
        @Bindable var bindable = uninstaller
        HSplitView {
            List(selection: $bindable.selectedAppID) {
                ForEach(uninstaller.apps) { installed in
                    HStack(spacing: 8) {
                        Image(nsImage: FileIcons.pathIcon(installed.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(installed.name).lineLimit(1)
                            if let version = installed.version {
                                Text(version).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(installed.id)
                }
            }
            .overlay {
                if uninstaller.isLoadingApps && uninstaller.apps.isEmpty {
                    ProgressView()
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            Group {
                if let selected = uninstaller.selectedApp {
                    AppDetail(uninstaller: uninstaller, installed: selected)
                } else {
                    ContentUnavailableView("Select an App", systemImage: "trash.square",
                                           description: Text("KlaD removes the app together with its caches, settings and support files, so a reinstall starts clean."))
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if uninstaller.apps.isEmpty { uninstaller.loadApps() } }
        .alert(resultTitle(uninstaller), isPresented: Binding(
            get: { uninstaller.lastResult != nil },
            set: { if !$0 { uninstaller.lastResult = nil } }
        )) {
            Button("OK") { uninstaller.lastResult = nil }
        } message: {
            Text(resultMessage(uninstaller.lastResult))
        }
    }

    private func resultTitle(_ uninstaller: AppUninstaller) -> String {
        guard let result = uninstaller.lastResult else { return "" }
        return result.failed.isEmpty ? "“\(uninstaller.lastUninstalledName)” Was Uninstalled" : "Some Items Couldn't Be Removed"
    }

    private func resultMessage(_ result: UninstallResult?) -> String {
        guard let result else { return "" }
        var lines = ["\(result.removed.count) item\(result.removed.count == 1 ? "" : "s") moved to the Trash."]
        if result.clearedPreferenceDomain { lines.append("Its saved settings were cleared, so a reinstall starts fresh.") }
        for failure in result.failed.prefix(5) {
            lines.append("\(abbreviatePath(failure.path)): \(failure.message)")
        }
        return lines.joined(separator: "\n")
    }
}

private struct AppDetail: View {
    let uninstaller: AppUninstaller
    let installed: InstalledApp
    @State private var confirming = false

    var body: some View {
        let running = uninstaller.isRunning(installed)
        let removable = uninstaller.items.filter { !$0.isProtected }
        let protectedItems = uninstaller.items.filter(\.isProtected)
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: FileIcons.pathIcon(installed.path))
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(installed.name).font(.title2.weight(.semibold))
                        Text([installed.version.map { "Version \($0)" }, installed.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            if running {
                Section {
                    HStack {
                        Label("\(installed.name) is running. Quit it before uninstalling.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Quit \(installed.name)") { uninstaller.quit(installed) }
                    }
                }
            }

            Section {
                ForEach(removable) { item in
                    Toggle(isOn: Binding(
                        get: { !uninstaller.excluded.contains(item.path) },
                        set: { include in
                            if include { uninstaller.excluded.remove(item.path) } else { uninstaller.excluded.insert(item.path) }
                        }
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.kind.rawValue)
                                Text(abbreviatePath(item.path))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if let bytes = item.bytes {
                                Text(formatBytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(item.kind == .application)
                    .contextMenu { Button("Show in Finder") { SystemActions.reveal(item.path) } }
                }
            } header: {
                Text("Will Be Moved to the Trash")
            } footer: {
                Text("Items are matched by the app's exact bundle identifier or name. You can put anything back from the Trash.")
            }

            if !protectedItems.isEmpty {
                Section {
                    ForEach(protectedItems) { item in
                        HStack {
                            Label(abbreviatePath(item.path), systemImage: "lock.fill")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Show in Finder") { SystemActions.reveal(item.path) }
                        }
                    }
                } header: {
                    Text("Protected by macOS")
                } footer: {
                    Text("This is the app's private, sandboxed data. KlaD never opens or removes protected data; delete it in Finder if you want it gone too.")
                }
            }

            Section {
                LabeledContent("Total", value: uninstaller.isMeasuring ? "Measuring…" : formatBytes(uninstaller.removableBytes))
                HStack {
                    Spacer()
                    Button("Uninstall \(installed.name)…", role: .destructive) { confirming = true }
                        .disabled(running || uninstaller.isRemoving || uninstaller.removableItems.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Uninstall “\(installed.name)”?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) {
                Task { await uninstaller.uninstall() }
            }
        } message: {
            Text("The app and \(max(0, uninstaller.removableItems.count - 1)) related item\(uninstaller.removableItems.count == 2 ? "" : "s") will be moved to the Trash, and its saved settings cleared.")
        }
    }
}
