// ClassificationPolicyTests.swift
//
// SystemPolicy enforcement inside ClassificationEngine: protected nodes, opaque nodes, mayModify.
import Testing
import Foundation
@testable import KlaDIntelligence
import KlaDModels

private let home = "/Users/tester"
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let MiB: UInt64 = 1 << 20
private let old = Int64(now.timeIntervalSince1970) - 100 * 86_400

private let context = ClassificationContext(homeDirectory: home, now: now)

private func file(_ name: String, mib: UInt64 = 2) -> FileTreeNode {
    .file(name, logical: mib * MiB, modificationTime: old)
}

private func dir(_ name: String, _ children: [FileTreeNode]) -> FileTreeNode {
    .directory(name, modificationTime: old, children: children)
}

/// A scanner-style protected directory: flagged, childless, carrying its APFS-accounted bytes.
private func protectedDirectory(_ name: String, bytes: UInt64) -> FileTreeNode {
    let node = FileTreeNode(
        name: name, kind: .directory,
        metrics: StorageMetrics(logicalBytes: bytes, allocatedBytes: bytes, privateBytes: bytes, fileCount: 0),
        flags: .protectedLocation, modificationTime: old
    )
    return node
}

private func sealedSystem(bytes: UInt64) -> FileTreeNode {
    .opaque(
        "macOS System (sealed)", bytes: bytes, category: .system,
        annotation: NodeAnnotation(ruleID: "system.sealed_volume", title: "macOS System", safety: .doNotDelete, group: .system, reason: "Sealed system volume")
    )
}

private func sum(_ totals: [StorageCategory: StorageMetrics]) -> StorageMetrics {
    totals.values.reduce(StorageMetrics.zero) { $0 + $1 }
}

@Suite("Classification — system policy")
struct ClassificationPolicyTests {
    @Test func protectedLocationsAreAnnotatedDoNotDeleteAndNeverRecommended() throws {
        let mail = protectedDirectory("Mail", bytes: 8_000 * MiB)
        let safari = protectedDirectory("Safari", bytes: 500 * MiB)
        let containers = protectedDirectory("Containers", bytes: 3_000 * MiB)
        let root = FileTreeNode.directory(home, children: [
            dir("Library", [mail, safari, containers]),
            dir("Projects", [dir("app", [file("package.json"), dir("node_modules", [file("a.js", mib: 4)])])]),
        ])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: context)

        let mailAnnotation = try #require(mail.annotation)
        #expect(mailAnnotation.ruleID == "system.protected_location")
        #expect(mailAnnotation.title == "Mail")
        #expect(mailAnnotation.safety == .doNotDelete)
        #expect(mailAnnotation.group == .system)
        #expect(mailAnnotation.reason == "Your email and attachments.")
        #expect(mail.category == .documents)                    // SystemPolicy's category for Mail
        #expect(safari.category == .applications)
        #expect(safari.annotation?.title == "Safari")
        #expect(containers.annotation?.title == "App Containers")

        let protectedPaths: Set<String> = [mail.path, safari.path, containers.path]
        #expect(!result.recommendations.contains { protectedPaths.contains($0.path) })
        #expect(result.recommendations.contains { $0.path == home + "/Projects/app/node_modules" })   // normal rules still run
        #expect(result.annotatedNodeCount >= 4)
    }

    @Test func protectedNodeNotInTheListFallsBackToSystem() throws {
        let odd = protectedDirectory("Mystery", bytes: 100 * MiB)
        let root = FileTreeNode.directory(home, children: [dir("Library", [odd])])
        root.recomputeAggregates()
        _ = ClassificationEngine().classify(root: root, context: context)
        let annotation = try #require(odd.annotation)
        #expect(annotation.safety == .doNotDelete)
        #expect(annotation.ruleID == "system.protected_location")
        #expect(odd.category == .system)
    }

    @Test func protectedAnnotationsSurviveReclassification() {
        let mail = protectedDirectory("Mail", bytes: 10 * MiB)
        let root = FileTreeNode.directory(home, children: [dir("Library", [mail])])
        root.recomputeAggregates()
        let engine = ClassificationEngine()
        _ = engine.classify(root: root, context: context)
        _ = engine.classify(root: root, context: context)
        #expect(mail.annotation?.safety == .doNotDelete)
        #expect(mail.annotation?.title == "Mail")
    }

    @Test func opaqueAnnotationsAndCategoriesArePreserved() throws {
        let system = sealedSystem(bytes: 12_000 * MiB)
        let original = try #require(system.annotation)
        let root = FileTreeNode.directory("/", children: [
            system,
            dir("Users", [dir("tester", [file("notes.txt")])]),
        ])
        root.recomputeAggregates()
        let engine = ClassificationEngine()
        let result = engine.classify(root: root, context: context)
        #expect(system.annotation === original)
        #expect(system.category == .system)
        #expect(!result.recommendations.contains { $0.path.contains("sealed") })

        // Re-classifying keeps the very same annotation object.
        _ = engine.classify(root: root, context: context)
        #expect(system.annotation === original)
        #expect(system.annotation?.ruleID == "system.sealed_volume")
    }

    @Test func opaqueNodesAreExcludedFromRuleEvaluation() {
        // A synthetic node deliberately named like a rule target must not be matched.
        let opaque = FileTreeNode.opaque(
            "node_modules", bytes: 900 * MiB, category: .other,
            annotation: NodeAnnotation(ruleID: "system.hidden", title: "Hidden", safety: .doNotDelete, group: .system, reason: "hidden space")
        )
        let root = FileTreeNode.directory(home, children: [dir("app", [file("package.json"), opaque])])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: context)
        #expect(opaque.annotation?.ruleID == "system.hidden")
        #expect(result.recommendations.isEmpty)
        #expect(opaque.category == .other)
    }

    @Test func categoryTotalsStillSumWithOpaqueAndProtectedNodes() {
        let root = FileTreeNode.directory(home, children: [
            sealedSystem(bytes: 7_000 * MiB),
            dir("Library", [protectedDirectory("Mail", bytes: 2_000 * MiB), protectedDirectory("Safari", bytes: 300 * MiB)]),
            dir("Projects", [dir("app", [file("package.json"), file("main.swift", mib: 5), dir("node_modules", [file("a.js", mib: 9), file("b.js", mib: 3)])])]),
            file("movie.mov", mib: 40),
        ])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: context)
        let total = sum(result.categoryTotals)
        #expect(total.allocatedBytes == root.metrics.allocatedBytes)
        #expect(total.logicalBytes == root.metrics.logicalBytes)
        #expect(total.privateBytes == root.metrics.privateBytes)
        #expect(total.fileCount == root.metrics.fileCount)
        #expect(result.categoryTotals[.system]?.allocatedBytes ?? 0 >= 7_000 * MiB)
    }

    @Test func trashIsDowngradedOutsideWhatSystemPolicyMayModify() {
        // node_modules directly below a fake /opt/x root: classic rule match, but not inside $HOME.
        let root = FileTreeNode.directory("/opt/x", children: [
            file("package.json"), file("package-lock.json"), dir("node_modules", [file("a.js", mib: 8)]),
        ])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: context)
        #expect(result.recommendations.isEmpty)
        #expect(root.child(named: "node_modules")?.annotation != nil)         // still identified…
        #expect(result.recommendations.allSatisfy { !$0.isTrashable })       // …but never offered for the Trash
    }

    @Test func theSameTreeInsideHomeStillGetsATrashableRecommendation() {
        let root = FileTreeNode.directory(home, children: [
            dir("Projects", [dir("x", [file("package.json"), file("package-lock.json"), dir("node_modules", [file("a.js", mib: 8)])])]),
        ])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: context)
        let rec = result.recommendations.first { $0.path == home + "/Projects/x/node_modules" }
        #expect(rec?.isTrashable == true)
    }

    @Test func nothingTrashableEverEscapesTheHomeFolder() {
        // Whole-disk style tree: user data under /Users/tester, plus system-ish and /opt content.
        let projectInHome = dir("x", [file("package.json"), file("package-lock.json"), dir("node_modules", [file("a.js", mib: 8)])])
        let projectInOpt = dir("y", [file("package.json"), file("package-lock.json"), dir("node_modules", [file("a.js", mib: 8)])])
        let root = FileTreeNode.directory("/", children: [
            dir("Users", [dir("tester", [dir("Projects", [projectInHome])])]),
            dir("opt", [projectInOpt]),
            dir("Applications", [dir("Foo.app", [file("x", mib: 30)])]),
        ])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: context)
        for rec in result.recommendations where rec.isTrashable {
            #expect(SystemPolicy.mayModify(rec.path, home: home), "\(rec.path) must not be trashable")
        }
        #expect(result.recommendations.contains { $0.path == "/Users/tester/Projects/x/node_modules" } == false
                || result.recommendations.contains { $0.path == "/Users/tester/Projects/x/node_modules" && $0.isTrashable })
        #expect(!result.recommendations.contains { $0.path.hasPrefix("/opt/") && $0.isTrashable })
    }

    @Test func guidedRecommendationsInProtectedAreasMayStay() {
        // A Docker.raw inside the protected Containers tree would never be scanned, but a guided rule
        // elsewhere under $HOME must keep working (guided actions never trash).
        let root = FileTreeNode.directory(home, children: [
            dir("Library", [dir("Containers", [dir("com.docker.docker", [dir("Data", [file("Docker.raw", mib: 500)])])])]),
        ])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: context)
        #expect(result.recommendations.allSatisfy { !$0.action.isTrashable })
    }

    @Test func classificationIsDeepTreeSafeWithPolicyNodes() {
        var current = file("leaf.txt")
        for i in 0..<300 { current = dir("d\(i)", [current]) }
        let root = FileTreeNode.directory("/", children: [sealedSystem(bytes: 100 * MiB), protectedDirectory("Mail", bytes: 10 * MiB), current])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: context)
        #expect(sum(result.categoryTotals).allocatedBytes == root.metrics.allocatedBytes)
    }
}
