// SimilarFolderTests.swift
import Testing
import Foundation
@testable import KlaDIntelligence
import KlaDModels

private let KiB: UInt64 = 1 << 10
private let MiB: UInt64 = 1 << 20

private func file(_ name: String, kib: UInt64, mtime: Int64 = 1_700_000_000) -> FileTreeNode {
    .file(name, logical: kib * KiB, modificationTime: mtime)
}

/// A "project" folder holding `names.count` files of `kib` KiB each.
private func folder(_ name: String, files names: [String], kib: UInt64 = 512, mtime: Int64 = 1_700_000_000) -> FileTreeNode {
    .directory(name, modificationTime: mtime, children: names.map { file($0, kib: kib, mtime: mtime) })
}

private let standardFiles = ["main.c", "util.c", "util.h", "Makefile", "README.md", "notes.txt", "data.bin", "icon.png", "lib.a", "config.ini"]

/// A parent folder made unique by a marker file, so parents never match each other.
private func parent(_ name: String, _ children: [FileTreeNode]) -> FileTreeNode {
    .directory(name, children: children + [file("only-\(name).bin", kib: 4 + UInt64(name.utf8.reduce(0) { $0 &+ Int($1) } % 97))])
}

private func finish(_ root: FileTreeNode) -> FileTreeNode {
    root.recomputeAggregates()
    return root
}

private func detect(_ root: FileTreeNode, minimum: UInt64 = 1 * MiB) -> [SimilarFolderGroup] {
    SimilarFolderDetector().findSimilarFolders(in: root, minimumBytes: minimum)
}

@Suite("Similar folders")
struct SimilarFolderTests {
    @Test func identicalCopiesAreFoundWithDifferentNames() {
        // The user's real layout: samsung old/kd, samsung old/New folder (7)/kd - Copy, duplicate/
        let root = finish(.directory("/Users/t", children: [
            .directory("samsung old", children: [
                folder("kd", files: standardFiles, mtime: 1_600_000_000),
                .directory("New folder (7)", children: [folder("kd - Copy", files: standardFiles, mtime: 1_700_000_000)]),
            ]),
            folder("duplicate", files: standardFiles, mtime: 1_710_000_000),
        ]))
        let groups = detect(root)
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.kind == .identicalContents)
        #expect(group.similarity == 1.0)
        #expect(group.folders.count == 3)
        #expect(group.folders.first?.path == "/Users/t/samsung old/kd")      // original: oldest, not copy-named
        #expect(Set(group.folders.map(\.path)) == [
            "/Users/t/samsung old/kd", "/Users/t/samsung old/New folder (7)/kd - Copy", "/Users/t/duplicate",
        ])
        let expected = group.folders.dropFirst().reduce(UInt64(0)) { $0 + $1.metrics.privateBytes }
        #expect(group.reclaimableBytes == expected)
        #expect(group.reclaimableBytes == 2 * 10 * 512 * KiB)
        #expect(group.title == "kd")
    }

    @Test func nameVariantsAreMatchedWithJaccard() {
        let variantFiles = Array(standardFiles.dropLast()) + ["config-new.ini"]          // 9 shared of 11 → 0.82
        let root = finish(.directory("/Users/t", children: [
            .directory("a", children: [folder("kd", files: standardFiles)]),
            .directory("b", children: [folder("KD copy 2", files: variantFiles, kib: 520)]),
            .directory("c", children: [folder("kd_v2", files: variantFiles, kib: 500)]),
            .directory("d", children: [folder("kd (3)", files: variantFiles, kib: 510)]),
        ]))
        let groups = detect(root)
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.kind == .nameVariants)
        #expect(group.folders.count == 4)
        #expect(group.similarity >= 0.8 && group.similarity < 1.0)
        #expect(group.folders.first?.path == "/Users/t/a/kd")
    }

    @Test(arguments: ["kd - Copy", "kd copy", "kd copy 2", "kd_v2", "kd-v3", "kd v4", "KD", "kd (2)", "kd 2", "kd_old", "kd old", "kd_backup", "kd-final"])
    func normalisationStripsCopyDecorations(variant: String) {
        #expect(FolderNames.normalize(variant).key == "kd")
    }

    @Test func normalisationKeepsMeaningfulNames() {
        #expect(FolderNames.normalize("2019").key == "2019")
        #expect(FolderNames.normalize("copy").key == "copy")
        #expect(FolderNames.normalize("old").key == "old")
        #expect(FolderNames.normalize("kd2").key == "kd2")
        #expect(FolderNames.normalize("  Spaced   Name ").key == "spaced name")
        #expect(FolderNames.normalize("kd").isVariant == false)
        #expect(FolderNames.normalize("kd - Copy").isVariant)
        #expect(FolderNames.baseName(of: "My Project - Copy (2)") == "My Project")
    }

    @Test func genericNamesNeverMatchOnNameAlone() {
        // Same generic name, similar-but-not-identical contents ⇒ no group.
        let nearly = Array(standardFiles.dropLast()) + ["other.ini"]
        let alsoNearly = Array(standardFiles.dropLast()) + ["another.ini"]
        let root = finish(.directory("/Users/t", children: [
            parent("a", [folder("New folder", files: standardFiles)]),
            parent("b", [folder("New folder (2)", files: nearly)]),
            parent("c", [folder("Untitled folder", files: alsoNearly, kib: 512)]),
        ]))
        #expect(detect(root).isEmpty)
    }

    @Test func genericNamesMatchWhenContentsAreIdentical() {
        let root = finish(.directory("/Users/t", children: [
            .directory("a", children: [folder("New folder", files: standardFiles)]),
            .directory("b", children: [folder("New folder (2)", files: standardFiles)]),
        ]))
        let groups = detect(root)
        #expect(groups.count == 1)
        #expect(groups[0].kind == .identicalContents)
    }

    @Test func sameTopLevelButDifferentSubfolderContentsIsNotIdentical() {
        // Both projects have src/ + docs/ of equal sizes, but the files inside differ.
        func project(_ name: String, tag: String) -> FileTreeNode {
            .directory(name, children: [
                folder("src", files: ["\(tag)1.c", "\(tag)2.c", "\(tag)3.c"], kib: 600),
                folder("docs", files: ["\(tag)1.md", "\(tag)2.md", "\(tag)3.md"], kib: 600),
            ])
        }
        let root = finish(.directory("/Users/t", children: [project("alpha", tag: "a"), project("beta", tag: "b")]))
        #expect(detect(root).isEmpty)

        let twin = finish(.directory("/Users/t", children: [project("alpha", tag: "a"), project("alpha copy", tag: "a")]))
        let groups = detect(twin)
        #expect(groups.count == 1)
        #expect(groups[0].kind == .identicalContents)
    }

    @Test func dissimilarContentsAreNotMatched() {
        let other = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt", "g.txt", "h.txt", "i.txt", "j.txt"]
        let root = finish(.directory("/Users/t", children: [
            .directory("a", children: [folder("kd", files: standardFiles)]),
            .directory("b", children: [folder("kd - Copy", files: other)]),
        ]))
        #expect(detect(root).isEmpty)
    }

    @Test func sizesMoreThanFifteenPercentApartAreNotNameVariants() {
        let variantFiles = Array(standardFiles.dropLast()) + ["extra.ini"]
        let root = finish(.directory("/Users/t", children: [
            .directory("a", children: [folder("kd", files: standardFiles, kib: 512)]),
            .directory("b", children: [folder("kd copy", files: variantFiles, kib: 700)]),
        ]))
        #expect(detect(root).isEmpty)
    }

    @Test func parentMatchSuppressesChildMatches() {
        let inner = folder("assets", files: standardFiles)
        let innerCopy = folder("assets", files: standardFiles)
        let root = finish(.directory("/Users/t", children: [
            .directory("proj", children: [inner, file("a.txt", kib: 64)]),
            .directory("proj - Copy", children: [innerCopy, file("a.txt", kib: 64)]),
        ]))
        let groups = detect(root)
        #expect(groups.count == 1)
        #expect(Set(groups[0].folders.map(\.path)) == ["/Users/t/proj", "/Users/t/proj - Copy"])
    }

    @Test func aFolderAndItsOwnAncestorAreNeverTogether() {
        // "x/kd" contains another "kd" with the same file list: they must not be reported as a pair.
        let root = finish(.directory("/Users/t", children: [
            .directory("kd", children: [folder("kd", files: standardFiles)]),
            .directory("elsewhere", children: [folder("kd copy", files: standardFiles)]),
        ]))
        for group in detect(root) {
            let paths = group.folders.map(\.path)
            for a in paths { for b in paths where a != b { #expect(!b.hasPrefix(a + "/")) } }
        }
    }

    @Test func originalFirstOrdering() {
        let root = finish(.directory("/Users/t", children: [
            parent("z", [folder("project copy", files: standardFiles, mtime: 1_000_000_000)]),   // copy-named, oldest
            parent("y", [folder("project", files: standardFiles, mtime: 1_700_000_000)]),        // newer original
            parent("x", [folder("project", files: standardFiles, mtime: 1_500_000_000)]),        // older original
        ]))
        let groups = detect(root)
        #expect(groups.count == 1)
        #expect(groups[0].folders.map(\.path) == ["/Users/t/x/project", "/Users/t/y/project", "/Users/t/z/project copy"])
    }

    @Test func shortestPathBreaksModificationTies() {
        let root = finish(.directory("/Users/t", children: [
            parent("deep", [parent("er", [folder("p", files: standardFiles)])]),
            parent("top", [folder("p", files: standardFiles)]),
        ]))
        let groups = detect(root)
        #expect(groups.first?.folders.first?.path == "/Users/t/top/p")
    }

    @Test func cleanupTargetsAndTheirContentsAreSkipped() {
        let nm1 = folder("node_modules", files: standardFiles)
        nm1.annotation = NodeAnnotation(ruleID: "node.node_modules", title: "node_modules", safety: .safeToClear, group: .buildArtifacts, reason: "")
        let nm2 = folder("node_modules", files: standardFiles)
        nm2.annotation = NodeAnnotation(ruleID: "node.node_modules", title: "node_modules", safety: .safeToClear, group: .buildArtifacts, reason: "")
        // Nested identical folder INSIDE a cleanup target is skipped too.
        let nested1 = FileTreeNode.directory("build", children: [folder("pkg", files: standardFiles)])
        nested1.annotation = NodeAnnotation(ruleID: "x", title: "x", safety: .reviewFirst, group: .buildArtifacts, reason: "")
        let nested2 = FileTreeNode.directory("build", children: [folder("pkg", files: standardFiles)])
        nested2.annotation = NodeAnnotation(ruleID: "x", title: "x", safety: .reviewFirst, group: .buildArtifacts, reason: "")
        let root = finish(.directory("/Users/t", children: [
            parent("a", [nm1, nested1]),
            parent("b", [nm2, nested2]),
        ]))
        #expect(detect(root).isEmpty)
    }

    @Test func packagesProtectedAndOpaqueNodesAreSkipped() {
        let pkgA = folder("Thing.app", files: standardFiles); pkgA.flags.insert(.package)
        let pkgB = folder("Thing.app", files: standardFiles); pkgB.flags.insert(.package)
        let protA = folder("Mail", files: standardFiles); protA.flags.insert(.protectedLocation)
        let protB = folder("Mail", files: standardFiles); protB.flags.insert(.protectedLocation)
        let root = finish(.directory("/Users/t", children: [
            parent("a", [pkgA, protA]),
            parent("b", [pkgB, protB]),
        ]))
        #expect(detect(root).isEmpty)
    }

    @Test func smallFoldersBelowTheMinimumAreIgnored() {
        let root = finish(.directory("/Users/t", children: [
            .directory("a", children: [folder("kd", files: ["a", "b"], kib: 4)]),
            .directory("b", children: [folder("kd - Copy", files: ["a", "b"], kib: 4)]),
        ]))
        #expect(detect(root, minimum: 1 * MiB).isEmpty)
        #expect(detect(root, minimum: 4 * KiB).count == 1)
    }

    @Test func groupsAreSortedByReclaimableAndIdsAreStable() {
        let big = ["a1", "a2", "a3", "a4"]
        let small = ["b1", "b2", "b3", "b4"]
        func build() -> FileTreeNode {
            finish(.directory("/Users/t", children: [
                .directory("p", children: [folder("small", files: small, kib: 300), folder("big", files: big, kib: 3000)]),
                .directory("q", children: [folder("small copy", files: small, kib: 300), folder("big copy", files: big, kib: 3000)]),
            ]))
        }
        let first = detect(build())
        let second = detect(build())
        #expect(first.count == 2)
        #expect(first[0].title == "big")
        #expect(first[0].reclaimableBytes > first[1].reclaimableBytes)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == 2)
    }

    @Test func twoThousandCopiesOfOneFolderAreOneGroup() {
        var children: [FileTreeNode] = []
        for i in 0..<2000 { children.append(folder("kd \(i + 1)", files: ["a.c", "b.c"], kib: 600)) }
        let root = finish(.directory("/Users/t", children: children))
        let groups = detect(root)
        #expect(groups.count == 1)
        #expect(groups[0].folders.count == 2000)
    }

    @Test func twoHundredThousandDirectoriesAreFast() {
        // 40 000 projects × (project + src + docs + assets + tests) = 200 000 directories.
        var projects: [FileTreeNode] = []
        projects.reserveCapacity(40_000)
        for p in 0..<40_000 {
            let unique = p % 4_000            // every project exists 10 times (identical copies) under different names
            let children: [FileTreeNode] = ["src", "docs", "assets", "tests"].map { sub in
                .directory(sub, children: [file("f\(unique)_\(sub).dat", kib: 8), file("g\(unique).dat", kib: 8)])
            }
            projects.append(.directory(p < 4_000 ? "proj\(unique)" : "proj\(unique) copy \(p / 4_000)", children: children))
        }
        let root = finish(.directory("/Users/t", children: projects))
        let clock = ContinuousClock()
        var groups: [SimilarFolderGroup] = []
        let elapsed = clock.measure { groups = detect(root, minimum: 4 * KiB) }
        print("⏱ similar folders over \(root.metrics.directoryCount) directories in \(elapsed) → \(groups.count) groups")
        #expect(groups.count == 4_000)
        #expect(groups.allSatisfy { $0.folders.count == 10 })
        #expect(elapsed < .seconds(30))
    }

    @Test func largeNameBucketsStayBounded() {
        // 3 000 folders all called "src" with unrelated contents: must finish quickly and report nothing.
        var children: [FileTreeNode] = []
        for i in 0..<3_000 {
            children.append(.directory("p\(i)", children: [folder("src", files: (0..<12).map { "u\(i)_\($0).c" }, kib: 100)]))
        }
        let root = finish(.directory("/Users/t", children: children))
        let clock = ContinuousClock()
        var groups: [SimilarFolderGroup] = []
        let elapsed = clock.measure { groups = detect(root, minimum: 1 * MiB) }
        #expect(groups.isEmpty)
        #expect(elapsed < .seconds(20))
    }
}
