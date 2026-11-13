// AppUninstaller.swift — remove an app completely: the bundle, its data in
// ~/Library, and its cached preferences (so a reinstall starts clean).
//
// Safety:
//   • Only user-installed apps in /Applications or ~/Applications; never Apple's
//     (SystemPolicy.mayUninstall).
//   • Leftovers are matched by exact bundle id (or the id followed by ".") or the
//     exact app name, and every one must pass SystemPolicy.mayModify — so the
//     app's sandbox containers (macOS-protected) are listed but never touched.
//   • Everything goes to the Trash via NSWorkspace (Put Back works; macOS asks
//     for an administrator password when the app is owned by the system).
//   • The app must not be running.

import AppKit
import Foundation
import KlaDModels
import KlaDScanner

struct InstalledApp: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    let version: String?

    var url: URL { URL(fileURLWithPath: path) }
}

struct UninstallItem: Identifiable, Hashable {
    enum Kind: String {
        case application = "Application"
        case support = "Application Support"
        case caches = "Caches"
        case preferences = "Preferences"
        case logs = "Logs"
        case webData = "Web Data"
        case savedState = "Saved State"
        case launchAgent = "Launch Agent"
        case scripts = "Application Scripts"
        case container = "Container (protected)"
    }

    var id: String { path }
    let path: String
    let kind: Kind
    var bytes: UInt64?
    /// Protected by macOS: shown for transparency, never removed by KlaD.
    let isProtected: Bool
}

struct UninstallResult {
    let removed: [String]
    let failed: [(path: String, message: String)]
    let clearedPreferenceDomain: Bool
}

@MainActor
@Observable
final class AppUninstaller {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoadingApps = false
    var selectedAppID: String? {
        didSet { if selectedAppID != oldValue { loadItems() } }
    }
    private(set) var items: [UninstallItem] = []
    private(set) var isMeasuring = false
    var excluded: Set<String> = []
    private(set) var isRemoving = false
    var lastResult: UninstallResult?
    private(set) var lastUninstalledName = ""

    @ObservationIgnored private let scanner = BulkAPFSScanner()
    @ObservationIgnored private var measureTask: Task<Void, Never>?
    private let home = NSHomeDirectory()

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    var removableItems: [UninstallItem] {
        items.filter { !$0.isProtected && !excluded.contains($0.path) }
    }

    var removableBytes: UInt64 { removableItems.reduce(0) { $0 + ($1.bytes ?? 0) } }

    func isRunning(_ app: InstalledApp) -> Bool {
        guard let id = app.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    func quit(_ app: InstalledApp) {
        guard let id = app.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }

    // MARK: Discovery

    func loadApps() {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        let home = self.home
        Task.detached(priority: .userInitiated) {
            var found: [InstalledApp] = []
            for folder in SystemPolicy.applicationFolders(home: home) {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
                for name in names where name.hasSuffix(".app") {
                    let path = folder + "/" + name
                    let info = Self.infoPlist(of: path)
                    let bundleID = info["CFBundleIdentifier"] as? String
                    guard SystemPolicy.mayUninstall(appPath: path, bundleID: bundleID, home: home) else { continue }
                    let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? String(name.dropLast(4))
                    found.append(InstalledApp(path: path, name: display, bundleID: bundleID,
                                              version: info["CFBundleShortVersionString"] as? String))
                }
            }
            found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            await MainActor.run { [found] in
                self.apps = found
                self.isLoadingApps = false
            }
        }
    }

    nonisolated private static func infoPlist(of appPath: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: appPath + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    // MARK: Leftovers

    private func loadItems() {
        measureTask?.cancel()
        excluded = []
        lastResult = nil
        guard let app = selectedApp else {
            items = []
            return
        }
        items = Self.findItems(for: app, home: home)
        isMeasuring = true
        let scanner = self.scanner
        let paths = items.filter { !$0.isProtected }.map(\.path)
        measureTask = Task { [weak self] in
            for path in paths {
                if Task.isCancelled { return }
                let bytes = await Self.size(of: path, scanner: scanner)
                guard let self, self.selectedAppID == app.id,
                      let index = self.items.firstIndex(where: { $0.path == path }) else { continue }
                self.items[index].bytes = bytes
            }
            self?.isMeasuring = false
        }
    }

    /// Exact-match leftovers in ~/Library for this app.
    static func findItems(for app: InstalledApp, home: String) -> [UninstallItem] {
        let fm = FileManager.default
        let lib = home + "/Library"
        var items = [UninstallItem(path: app.path, kind: .application, bytes: nil, isProtected: false)]
        var seen: Set<String> = [app.path]
        let id = app.bundleID
        let names = Set([app.name, (app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")])

        func add(_ path: String, _ kind: UninstallItem.Kind) {
            guard !seen.contains(path) else { return }
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            seen.insert(path)
            let isProtected = !SystemPolicy.mayModify(path, home: home)
            items.append(UninstallItem(path: path, kind: kind, bytes: nil, isProtected: isProtected))
        }
        /// Entries of `folder` named exactly like the bundle id, or starting with "<id>.".
        func addMatching(in folder: String, _ kind: UninstallItem.Kind, includeNames: Bool) {
            guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { return }
            for entry in entries {
                var match = false
                if let id {
                    let lower = entry.lowercased(), lowerID = id.lowercased()
                    match = lower == lowerID || lower.hasPrefix(lowerID + ".")
                }
                if !match && includeNames { match = names.contains(entry) }
                if match { add(folder + "/" + entry, kind) }
            }
        }

        addMatching(in: lib + "/Application Support", .support, includeNames: true)
        addMatching(in: lib + "/Caches", .caches, includeNames: true)
        addMatching(in: lib + "/Logs", .logs, includeNames: true)
        addMatching(in: lib + "/HTTPStorages", .webData, includeNames: false)
        addMatching(in: lib + "/WebKit", .webData, includeNames: false)
        addMatching(in: lib + "/Saved Application State", .savedState, includeNames: false)
        addMatching(in: lib + "/Preferences", .preferences, includeNames: false)
        addMatching(in: lib + "/Preferences/ByHost", .preferences, includeNames: false)
        addMatching(in: lib + "/LaunchAgents", .launchAgent, includeNames: false)
        addMatching(in: lib + "/Application Scripts", .scripts, includeNames: false)
        // Sandboxed data: listed (macOS-protected), never opened or removed.
        if let id { add(lib + "/Containers/" + id, .container) }
        return items
    }

    private static func size(of path: String, scanner: BulkAPFSScanner) async -> UInt64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR { return UInt64(st.st_blocks) * 512 }
        let node = try? await scanner.rescanSubtree(atPath: path, options: ScanOptions(rootPath: path, lowPriority: true))
        return node?.metrics.allocatedBytes ?? 0
    }

    // MARK: Removal

    func uninstall() async {
        guard let app = selectedApp, !isRemoving, !isRunning(app) else { return }
        isRemoving = true
        defer { isRemoving = false }
        let targets = removableItems
        var removed: [String] = []
        var failed: [(String, String)] = []
        for item in targets {
            // Re-check the policy right before touching anything.
            let allowed = item.kind == .application
                ? SystemPolicy.mayUninstall(appPath: item.path, bundleID: app.bundleID, home: home)
                : SystemPolicy.mayModify(item.path, home: home)
            guard allowed else {
                failed.append((item.path, "Not allowed by KlaD's safety policy"))
                continue
            }
            do {
                _ = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: item.path)])
                removed.append(item.path)
            } catch {
                failed.append((item.path, error.localizedDescription))
            }
        }
        // cfprefsd keeps preferences cached even after the file is gone, and
        // hands them back on reinstall. Empty the domain so the cache is dropped.
        var cleared = false
        if let id = app.bundleID, removed.contains(app.path) {
            let domain = id as CFString
            if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String], !keys.isEmpty {
                CFPreferencesSetMultiple(nil, keys as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? [String], !keys.isEmpty {
                CFPreferencesSetMultiple(nil, keys as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            }
            cleared = CFPreferencesAppSynchronize(domain)
        }
        if removed.contains(app.path) {
            apps.removeAll { $0.id == app.id }
            selectedAppID = nil
            items = []
        } else {
            items.removeAll { removed.contains($0.path) }
        }
        // Set last: changing the selection resets it.
        lastResult = UninstallResult(removed: removed, failed: failed.map { (path: $0.0, message: $0.1) }, clearedPreferenceDomain: cleared)
        lastUninstalledName = app.name
    }
}
