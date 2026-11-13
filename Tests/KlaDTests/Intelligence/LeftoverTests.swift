// LeftoverTests.swift
import Testing
import Foundation
@testable import KlaDIntelligence
import KlaDModels

private let home = "/Users/tester"
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: Int64 = 86_400
private let MiB: UInt64 = 1 << 20

private func ago(_ days: Int64) -> Int64 { Int64(now.timeIntervalSince1970) - days * day }

/// A folder with one file of `mib` MiB last modified `days` days ago.
private func item(_ name: String, mib: UInt64 = 5, days: Int64 = 200) -> FileTreeNode {
    .directory(name, modificationTime: ago(days), children: [
        .file("data.bin", logical: mib * MiB, modificationTime: ago(days)),
    ])
}

private func library(caches: [FileTreeNode] = [], support: [FileTreeNode] = [], logs: [FileTreeNode] = [],
                     http: [FileTreeNode] = [], webkit: [FileTreeNode] = [], saved: [FileTreeNode] = []) -> FileTreeNode {
    func parent(_ name: String, _ children: [FileTreeNode]) -> FileTreeNode? {
        children.isEmpty ? nil : .directory(name, modificationTime: ago(1), children: children)
    }
    let lib = FileTreeNode.directory("Library", children: [
        parent("Caches", caches), parent("Application Support", support), parent("Logs", logs),
        parent("HTTPStorages", http), parent("WebKit", webkit), parent("Saved Application State", saved),
    ].compactMap { $0 })
    let root = FileTreeNode.directory(home, children: [lib])
    root.recomputeAggregates()
    return root
}

private let context = ClassificationContext(homeDirectory: home, now: now)
private let noApps = InstalledApps(bundleIDs: [], names: [])

private func leftovers(_ root: FileTreeNode, installed: InstalledApps = noApps, ctx: ClassificationContext = context) -> [CleanupRecommendation] {
    LeftoverDetector().findLeftovers(in: root, context: ctx, installed: installed)
}

@Suite("App leftovers")
struct LeftoverTests {
    @Test func reportsDataOfAnUninstalledApp() throws {
        let root = library(caches: [item("com.ghost.Phantom", mib: 20)], support: [item("Phantom", mib: 8)])
        let result = leftovers(root)
        #expect(result.count == 2)
        let cache = try #require(result.first { $0.ruleID == "leftover.caches" })
        #expect(cache.path == home + "/Library/Caches/com.ghost.Phantom")
        #expect(cache.title == "Phantom (no longer installed)")
        #expect(cache.group == .appLeftovers)
        #expect(cache.category == .caches)
        #expect(cache.safety == .reviewFirst)
        #expect(cache.action.isTrashable)
        #expect(cache.isTrashable)
        #expect(cache.evidence.map(\.kind) == [.runtimeState, .knownLocation])
        #expect(cache.evidence[0].detail == "No installed app matches com.ghost.phantom")
        #expect(cache.evidence[1].detail == "Caches data, unchanged for 200 days")
        #expect(cache.warnings == ["Hints only: this may be settings or data of an app installed elsewhere or under another name."])
        #expect(cache.metrics.allocatedBytes == 20 * MiB)
        let support = try #require(result.first { $0.ruleID == "leftover.application_support" })
        #expect(support.category == .applications)
        #expect(support.title == "Phantom (no longer installed)")
        #expect(result.map(\.path) == [cache.path, support.path])      // largest first
    }

    @Test func installedAppByBundleIDIsExcluded() {
        let root = library(caches: [item("com.foo.Bar")], saved: [item("com.foo.Bar.savedState")])
        let apps = InstalledApps(bundleIDs: ["com.foo.bar"], names: [])
        #expect(leftovers(root, installed: apps).isEmpty)
    }

    @Test func installedAppByNameIsExcluded() {
        let root = library(support: [item("Slack"), item("Google Chrome"), item("Spotify")])
        let apps = InstalledApps(bundleIDs: [], names: ["slack", "google chrome"])
        let result = leftovers(root, installed: apps)
        #expect(result.map(\.path) == [home + "/Library/Application Support/Spotify"])
    }

    @Test func bundleIDPrefixSuffixAndLastComponentMatches() {
        let root = library(caches: [
            item("com.foo.bar.helper"),       // helper of installed com.foo.bar
            item("com.vendor.Notes"),         // last component equals installed name
            item("com.other.thing"),
        ])
        let apps = InstalledApps(bundleIDs: ["com.foo.bar"], names: ["notes"])
        #expect(leftovers(root, installed: apps).map(\.path) == [home + "/Library/Caches/com.other.thing"])
    }

    @Test func appleAndSystemDataIsNeverReported() {
        let names = ["com.apple.Safari", "com.apple.dt.Xcode", "CrashReporter", "AddressBook", "iCloud", "Knowledge",
                     "CloudDocs", "Dock", "SyncServices", "Animoji", "FileProvider", "Apple", "CallHistoryDB", "MobileSync",
                     "com.apple.Safari.savedState"]
        let root = library(caches: names.map { item($0) }, support: names.map { item($0) })
        #expect(leftovers(root).isEmpty)
    }

    @Test func recentlyModifiedDataIsExcluded() {
        let root = library(caches: [item("com.ghost.Fresh", days: 89), item("com.ghost.Stale", days: 90)])
        let result = leftovers(root)
        #expect(result.map(\.path) == [home + "/Library/Caches/com.ghost.Stale"])
    }

    @Test func ageComesFromFilesNotFolderDates() {
        // Folder touched yesterday (Finder metadata), but every file is old ⇒ still a leftover.
        let node = FileTreeNode.directory("com.ghost.Quiet", modificationTime: ago(1), children: [
            .file("x.bin", logical: 5 * MiB, modificationTime: ago(300)),
        ])
        #expect(leftovers(library(caches: [node])).count == 1)
    }

    @Test func smallItemsAreExcluded() {
        let root = library(caches: [item("com.ghost.Tiny", mib: 0), item("com.ghost.Big", mib: 3)])
        #expect(leftovers(root).map(\.path) == [home + "/Library/Caches/com.ghost.Big"])
        let strict = ClassificationContext(homeDirectory: home, now: now, minimumRecommendationBytes: 10 * MiB)
        #expect(leftovers(root, ctx: strict).isEmpty)
    }

    @Test func protectedAndOpaqueNodesAreNeverReported() {
        let protectedNode = item("MobileSync", mib: 50)
        protectedNode.flags.insert(.protectedLocation)
        let flagged = item("Ghost", mib: 50)
        flagged.flags.insert(.protectedLocation)
        let faceTime = item("FaceTime", mib: 50)           // protected by SystemPolicy path even without a flag
        let root = library(support: [protectedNode, flagged, faceTime])
        #expect(leftovers(root).isEmpty)
    }

    @Test func onlyTheSixLibraryFoldersAreInspected() {
        let documents = FileTreeNode.directory("Documents", modificationTime: ago(1), children: [item("com.ghost.NotHere")])
        let preferences = FileTreeNode.directory("Preferences", modificationTime: ago(1), children: [item("com.ghost.NotHereEither")])
        let lib = FileTreeNode.directory("Library", children: [preferences])
        let root = FileTreeNode.directory(home, children: [documents, lib])
        root.recomputeAggregates()
        #expect(leftovers(root).isEmpty)
    }

    @Test func onlyDirectChildrenAreExamined() {
        let nested = FileTreeNode.directory("Vendor", modificationTime: ago(1), children: [item("com.ghost.Deep", mib: 9)])
        let root = library(support: [nested])
        // "Vendor" itself is a direct child but holds com.ghost.Deep only (it is the unit reported).
        let result = leftovers(root)
        #expect(result.map(\.path) == [home + "/Library/Application Support/Vendor"])
    }

    @Test func worksWhenTheTreeRootIsTheWholeDisk() {
        let lib = FileTreeNode.directory("Library", children: [
            .directory("Caches", modificationTime: ago(1), children: [item("com.ghost.Phantom")]),
        ])
        let root = FileTreeNode.directory("/", children: [.directory("Users", children: [.directory("tester", children: [lib])])])
        root.recomputeAggregates()
        #expect(leftovers(root).count == 1)
    }

    @Test func identityParsing() {
        let a = LeftoverDetector.identity(ofChildNamed: "com.foo.Bar.savedState")
        #expect(a.id == "com.foo.bar" && a.shortName == "bar" && a.displayName == "Bar" && a.isBundleID)
        let b = LeftoverDetector.identity(ofChildNamed: "com.foo.Bar.binarycookies")
        #expect(b.id == "com.foo.bar")
        let c = LeftoverDetector.identity(ofChildNamed: "Slack")
        #expect(c.id == "slack" && c.displayName == "Slack" && !c.isBundleID)
        let d = LeftoverDetector.identity(ofChildNamed: "Mozilla.org")
        #expect(!d.isBundleID)
    }
}
