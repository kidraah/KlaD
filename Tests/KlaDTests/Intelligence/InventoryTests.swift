// InventoryTests.swift
import Testing
import Foundation
@testable import KlaDIntelligence
import KlaDModels

private let KiB: UInt64 = 1 << 10

private func file(_ name: String, kib: UInt64, flags: NodeFlags = [], category: StorageCategory = .other) -> FileTreeNode {
    let node = FileTreeNode.file(name, logical: kib * KiB, flags: flags)
    node.category = category
    return node
}

private func dir(_ name: String, _ children: [FileTreeNode]) -> FileTreeNode {
    .directory(name, children: children)
}

private func finish(_ root: FileTreeNode) -> FileTreeNode {
    root.recomputeAggregates()
    return root
}

@Suite("Inventory — largest files")
struct LargestFilesTests {
    @Test func matchesAFullSort() {
        var children: [FileTreeNode] = []
        var generator = SystemRandomNumberGenerator()
        for d in 0..<20 {
            var files: [FileTreeNode] = []
            for i in 0..<50 {
                files.append(file("f\(d)_\(i).bin", kib: UInt64.random(in: 1...2000, using: &generator)))
            }
            children.append(dir("d\(d)", files))
        }
        let root = finish(dir("/Users/t", children))

        var expected: [(UInt64, String)] = []
        root.walkWithPaths { node, path in
            if node.kind == .file { expected.append((node.metrics.allocatedBytes, path)) }
            return .continue
        }
        expected.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }

        let result = InventoryReporter().largestFiles(in: root, limit: 25, measure: .allocated)
        #expect(result.count == 25)
        #expect(result.map(\.path) == expected.prefix(25).map(\.1))
        #expect(result.map(\.metrics.allocatedBytes) == expected.prefix(25).map(\.0))
    }

    @Test func limitLargerThanFileCountReturnsEverything() {
        let root = finish(dir("/r", [file("a", kib: 8), file("b", kib: 4)]))
        let result = InventoryReporter().largestFiles(in: root, limit: 100, measure: .allocated)
        #expect(result.map(\.path) == ["/r/a", "/r/b"])
        #expect(InventoryReporter().largestFiles(in: root, limit: 0, measure: .allocated).isEmpty)
    }

    @Test func equalSizesAreOrderedByPathDeterministically() {
        let root = finish(dir("/r", [file("c", kib: 8), file("a", kib: 8), file("b", kib: 8), file("d", kib: 8)]))
        let result = InventoryReporter().largestFiles(in: root, limit: 2, measure: .allocated)
        #expect(result.map(\.path) == ["/r/a", "/r/b"])
    }

    @Test func skipsHardLinkDuplicatesOpaqueDirectoriesSymlinksAndPlaceholders() {
        let opaque = FileTreeNode.opaque(
            "macOS System (sealed)", bytes: 50_000_000_000, category: .system,
            annotation: NodeAnnotation(ruleID: "system.sealed", title: "macOS", safety: .doNotDelete, group: .system, reason: "sealed")
        )
        let symlink = FileTreeNode(name: "link", kind: .symlink, metrics: StorageMetrics(logicalBytes: 9_999_999, allocatedBytes: 9_999_999, privateBytes: 9_999_999, fileCount: 1))
        let root = finish(dir("/r", [
            file("real.bin", kib: 100),
            file("dup.bin", kib: 5000, flags: [.hardLinked, .hardLinkDuplicate]),
            file("stub.mov", kib: 9000, flags: .cloudPlaceholder),
            symlink,
            opaque,
        ]))
        let allocated = InventoryReporter().largestFiles(in: root, limit: 10, measure: .allocated)
        #expect(allocated.map(\.path) == ["/r/real.bin"])

        // Logical measure keeps placeholders (they have a logical size) but never duplicates.
        let logical = InventoryReporter().largestFiles(in: root, limit: 10, measure: .logical)
        #expect(logical.map(\.path) == ["/r/stub.mov", "/r/real.bin"])
    }

    @Test func carriesCategoryAndModificationTime() {
        let node = FileTreeNode.file("movie.mov", logical: 1 << 20, modificationTime: 1234)
        node.category = .media
        let root = finish(dir("/r", [node]))
        let entry = InventoryReporter().largestFiles(in: root, limit: 1, measure: .allocated).first
        #expect(entry?.category == .media)
        #expect(entry?.modificationTime == 1234)
    }

    @Test func handlesVeryDeepTrees() {
        var current = file("leaf.bin", kib: 64)
        for i in 0..<400 { current = dir("d\(i)", [current]) }
        let root = finish(dir("/deep", [current]))
        let result = InventoryReporter().largestFiles(in: root, limit: 1, measure: .allocated)
        #expect(result.count == 1)
        #expect(result[0].path.hasSuffix("/leaf.bin"))
    }
}

@Suite("Inventory — file types")
struct FileTypeTests {
    @Test func groupsByLowercasedExtension() {
        let root = finish(dir("/r", [
            file("a.MOV", kib: 1000, category: .media),
            file("b.mov", kib: 3000, category: .media),
            file("c.txt", kib: 4),
        ]))
        let types = InventoryReporter().fileTypes(in: root, limit: 10)
        #expect(types.map(\.key) == ["mov", "txt"])
        #expect(types[0].fileCount == 2)
        #expect(types[0].metrics.allocatedBytes == (1000 + 3000) * KiB)
        #expect(types[0].largestPath == "/r/b.mov")
        #expect(types[0].category == .media)
    }

    @Test func noExtensionAndDotfilesShareTheEmptyKey() {
        let root = finish(dir("/r", [
            file("Makefile", kib: 4),
            file(".zshrc", kib: 8),
            file(".gitignore", kib: 4),
            file("trailingdot.", kib: 4),
            file("real.sh", kib: 4),
        ]))
        let types = InventoryReporter().fileTypes(in: root, limit: 10)
        let none = types.first { $0.key == "" }
        #expect(none?.fileCount == 4)
        #expect(none?.largestPath == "/r/.zshrc")
        #expect(types.contains { $0.key == "sh" })
        #expect(!types.contains { $0.key == "zshrc" || $0.key == "gitignore" })
    }

    @Test func longExtensionsAreSupported() {
        let root = finish(dir("/r", [
            file("Foo.SwiftModule", kib: 40), file("Bar.swiftmodule", kib: 40), file("x.mobileprovision", kib: 4),
        ]))
        let types = InventoryReporter().fileTypes(in: root, limit: 10)
        #expect(types.first?.key == "swiftmodule")
        #expect(types.first?.fileCount == 2)
        #expect(types.contains { $0.key == "mobileprovision" })
    }

    @Test func largestFirstAndLimited() {
        let root = finish(dir("/r", [
            file("a.aaa", kib: 10), file("b.bbb", kib: 300), file("c.ccc", kib: 50), file("d.ddd", kib: 20),
        ]))
        let types = InventoryReporter().fileTypes(in: root, limit: 2)
        #expect(types.map(\.key) == ["bbb", "ccc"])
    }

    @Test func categoryIsTheMostCommonByBytes() {
        let root = finish(dir("/r", [
            file("1.dat", kib: 100, category: .media),
            file("2.dat", kib: 900, category: .documents),
            file("3.dat", kib: 200, category: .media),
        ]))
        #expect(InventoryReporter().fileTypes(in: root, limit: 5).first?.category == .documents)
    }

    @Test func hardLinkDuplicatesCountAsFilesButNotBytes() {
        let root = finish(dir("/r", [
            file("a.bin", kib: 100),
            file("b.bin", kib: 100, flags: [.hardLinked, .hardLinkDuplicate]),
        ]))
        let type = InventoryReporter().fileTypes(in: root, limit: 5).first
        #expect(type?.fileCount == 2)
        #expect(type?.metrics.allocatedBytes == 100 * KiB)
    }

    @Test func skipsOpaqueNodes() {
        let opaque = FileTreeNode.opaque(
            "System", bytes: 1 << 30, category: .system,
            annotation: NodeAnnotation(ruleID: "system.sealed", title: "System", safety: .doNotDelete, group: .system, reason: "")
        )
        let root = finish(dir("/r", [file("a.txt", kib: 4), opaque]))
        let types = InventoryReporter().fileTypes(in: root, limit: 5)
        #expect(types.map(\.key) == ["txt"])
    }

    @Test func millionsOfNodesAreFast() {
        // 100 × 100 × 60 = 600 000 files (the 3 M-node release budget is < 1 s; debug gets generous slack).
        let extensions = ["txt", "mov", "swift", "o", "json", "png", "", "gguf", "dmg", "swiftmodule"]
        var top: [FileTreeNode] = []
        for a in 0..<100 {
            var mid: [FileTreeNode] = []
            for b in 0..<100 {
                var leaves: [FileTreeNode] = []
                leaves.reserveCapacity(60)
                for c in 0..<60 {
                    let ext = extensions[(a + b + c) % extensions.count]
                    leaves.append(.file(ext.isEmpty ? "f\(c)" : "f\(c).\(ext)", logical: UInt64(1 + c) * 4096))
                }
                mid.append(dir("m\(b)", leaves))
            }
            top.append(dir("t\(a)", mid))
        }
        let root = finish(dir("/big", top))
        let clock = ContinuousClock()
        var types: [FileTypeSummary] = []
        var largest: [LargeFileEntry] = []
        let elapsed = clock.measure {
            types = InventoryReporter().fileTypes(in: root, limit: 20)
            largest = InventoryReporter().largestFiles(in: root, limit: 100, measure: .allocated)
        }
        print("⏱ inventory over \(root.metrics.fileCount) files in \(elapsed)")
        #expect(types.count == extensions.count)
        #expect(largest.count == 100)
        #expect(elapsed < .seconds(20))
    }
}
