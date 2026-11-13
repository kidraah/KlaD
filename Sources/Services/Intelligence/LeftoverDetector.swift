// LeftoverDetector.swift — KlaDIntelligence
//
// Hints about app data whose app is no longer installed. Looks ONLY at the direct children of
// a fixed list of ~/Library folders, using the scanned tree (no disk I/O). Everything is a
// hint ("review first"): the data may belong to an app installed elsewhere or under another name.
//
// A child is reported only when ALL hold:
//   • it is not Apple's / a system or developer-tool name (deny-lists below);
//   • no installed app matches its bundle id or name;
//   • nothing inside changed for 90+ days (`context.now`);
//   • allocated ≥ `context.minimumRecommendationBytes`;
//   • `SystemPolicy.mayModify` allows trashing that path.

import Foundation
import KlaDModels

public struct LeftoverDetector: LeftoverDetecting {
    public init() {}

    static let minimumAgeDays = 90

    private struct Source {
        let relativePath: String
        /// Used in ruleIDs: "leftover.<kind>".
        let kind: String
        /// Human name of the folder ("Application Support").
        let display: String
        let category: StorageCategory
    }

    private static let sources: [Source] = [
        Source(relativePath: "Library/Caches", kind: "caches", display: "Caches", category: .caches),
        Source(relativePath: "Library/Application Support", kind: "application_support", display: "Application Support", category: .applications),
        Source(relativePath: "Library/Logs", kind: "logs", display: "Logs", category: .applications),
        Source(relativePath: "Library/HTTPStorages", kind: "http_storages", display: "HTTP Storages", category: .applications),
        Source(relativePath: "Library/WebKit", kind: "webkit", display: "WebKit", category: .applications),
        Source(relativePath: "Library/Saved Application State", kind: "saved_state", display: "Saved Application State", category: .applications),
    ]

    // MARK: - Deny-lists (lower-case)

    /// Exact names that are never an app's leftover: Apple/system services, shared vendor folders and
    /// developer-tool caches (those are covered by the developer rules, not by "uninstalled app" hints).
    private static let deniedNames: Set<String> = [
        "crashreporter", "addressbook", "icloud", "knowledge", "clouddocs", "dock", "syncservices", "animoji",
        "fileprovider", "apple", "mobilesync", "cloudkit", "diagnosticreports", "familycircle", "geoservices",
        "differentialprivacy", "identityservices", "networkserviceproxy", "tipsd", "siri", "spotlight",
        "quicklook", "coreparsec", "homebrew", "pip", "yarn", "pnpm", "npm", "cocoapods", "go-build", "swiftpm",
        "node-gyp", "typescript", "org.swift.swiftpm", "google", "microsoft", "adobe", "jetbrains", "mozilla",
        "package cache", "caches", "logs", ".ds_store", ".localized",
    ]
    private static let deniedPrefixes: [String] = ["com.apple.", "callhistory"]

    private static let bundleSuffixes = [".savedstate", ".binarycookies", ".plist"]
    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "app", "co", "dev", "ai", "me", "us", "de", "uk", "fr", "jp", "cn", "ru", "edu", "gov",
    ]

    // MARK: - Detection

    public func findLeftovers(in root: FileTreeNode, context: ClassificationContext, installed: InstalledApps) -> [CleanupRecommendation] {
        let home = SystemPolicy.normalize(context.homeDirectory)
        let matcher = InstalledMatcher(installed)
        let nowSeconds = context.now.timeIntervalSince1970
        var results: [CleanupRecommendation] = []

        for source in Self.sources {
            let parentPath = home + "/" + source.relativePath
            guard let parent = root.descendant(atPath: parentPath),
                  parent.kind == .directory, !parent.isOpaque, !parent.isProtectedLocation else { continue }

            for child in parent.children {
                if child.isOpaque || child.isProtectedLocation { continue }
                if child.kind != .directory && child.kind != .file { continue }
                if child.name.hasPrefix(".") { continue }

                let allocated = child.metrics.allocatedBytes
                guard allocated >= context.minimumRecommendationBytes else { continue }

                let identity = Self.identity(ofChildNamed: child.name)
                if Self.isDenied(identity: identity, name: child.name) { continue }
                if matcher.matches(identity) { continue }

                // Folder dates are ignored by `newestModificationTime`: only file content counts.
                let ageDays = Int(((nowSeconds - Double(child.newestModificationTime)) / 86_400).rounded(.down))
                guard ageDays >= Self.minimumAgeDays else { continue }

                let path = parentPath + "/" + child.name
                guard SystemPolicy.mayModify(path, home: home) else { continue }

                results.append(Self.recommendation(
                    for: child, path: path, parentPath: parentPath, source: source, identity: identity, ageDays: ageDays
                ))
            }
        }

        results.sort { a, b in
            if a.reclaimableBytes != b.reclaimableBytes { return a.reclaimableBytes > b.reclaimableBytes }
            return a.path < b.path
        }
        return results
    }

    // MARK: - Identity

    struct AppIdentity {
        /// Lower-cased bundle id ("com.foo.bar") or plain name ("slack").
        var id: String
        /// Lower-cased last component for reverse-DNS ids, else equal to `id`.
        var shortName: String
        /// Name to show ("Bar", "Slack").
        var displayName: String
        var isBundleID: Bool
    }

    static func identity(ofChildNamed name: String) -> AppIdentity {
        var base = name
        var lower = name.lowercased()
        var stripped = true
        while stripped {
            stripped = false
            for suffix in bundleSuffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
                base = String(base.dropLast(suffix.count))
                lower = String(lower.dropLast(suffix.count))
                stripped = true
            }
        }
        let components = lower.split(separator: ".", omittingEmptySubsequences: true)
        let looksLikeBundleID = components.count >= 3
            || (components.count == 2 && topLevelDomains.contains(String(components[0])))
        if looksLikeBundleID, let last = components.last {
            let displayParts = base.split(separator: ".", omittingEmptySubsequences: true)
            return AppIdentity(id: lower, shortName: String(last), displayName: String(displayParts.last ?? Substring(base)), isBundleID: true)
        }
        return AppIdentity(id: lower, shortName: lower, displayName: base, isBundleID: false)
    }

    static func isDenied(identity: AppIdentity, name: String) -> Bool {
        let lower = name.lowercased()
        if deniedNames.contains(lower) || deniedNames.contains(identity.id) { return true }
        for prefix in deniedPrefixes where lower.hasPrefix(prefix) || identity.id.hasPrefix(prefix) { return true }
        return false
    }

    // MARK: - Installed-app matching

    private struct InstalledMatcher {
        let bundleIDs: Set<String>
        let bundleList: [String]
        let names: Set<String>
        let squashedNames: Set<String>

        init(_ installed: InstalledApps) {
            bundleIDs = Set(installed.bundleIDs.map { $0.lowercased() })
            bundleList = Array(bundleIDs)
            names = Set(installed.names.map { $0.lowercased() })
            squashedNames = Set(names.map(Self.squash))
        }

        /// "Google Chrome" / "google-chrome" / "GoogleChrome" → "googlechrome".
        static func squash(_ text: String) -> String {
            String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }

        func matches(_ identity: AppIdentity) -> Bool {
            if bundleIDs.contains(identity.id) { return true }
            if names.contains(identity.id) || names.contains(identity.shortName) { return true }
            let squashed = Self.squash(identity.shortName)
            if !squashed.isEmpty && squashedNames.contains(squashed) { return true }
            if identity.isBundleID {
                // Helpers / extensions / data of an installed app share its bundle id as prefix or suffix
                // (either direction: "com.foo.bar.helper" vs "com.foo.bar", "com.foo.bar" vs "com.foo.bar.mac").
                for installedID in bundleList {
                    if installedID.hasPrefix(identity.id + ".") || installedID.hasSuffix("." + identity.id) { return true }
                    if identity.id.hasPrefix(installedID + ".") || identity.id.hasSuffix("." + installedID) { return true }
                }
            }
            return false
        }
    }

    // MARK: - Output

    private static func recommendation(
        for node: FileTreeNode, path: String, parentPath: String, source: Source, identity: AppIdentity, ageDays: Int
    ) -> CleanupRecommendation {
        var signals: [SupportingSignal] = [.inactive(days: ageDays)]
        let allocated = node.metrics.allocatedBytes
        if allocated > 0 && node.metrics.sharedBytes &* 4 > allocated { signals.append(.cloneSharedContent) }

        let appLabel = identity.isBundleID ? identity.id : identity.displayName
        return CleanupRecommendation(
            ruleID: "leftover." + source.kind,
            title: "\(identity.displayName) (no longer installed)",
            path: path,
            category: source.category,
            safety: .reviewFirst,
            group: .appLeftovers,
            metrics: node.metrics,
            rationale: "No installed app matches “\(appLabel)”, and nothing in this \(source.display) item has changed for \(ageDays) days.",
            evidence: [
                Evidence(kind: .runtimeState, detail: "No installed app matches \(appLabel)"),
                Evidence(kind: .knownLocation, detail: "\(source.display) data, unchanged for \(ageDays) days", path: parentPath),
            ],
            signals: signals,
            action: .moveToTrash,
            regenerateCommand: nil,
            warnings: ["Hints only: this may be settings or data of an app installed elsewhere or under another name."],
            identity: node.identity
        )
    }
}
