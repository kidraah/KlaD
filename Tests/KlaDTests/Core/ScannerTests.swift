// ScannerTests.swift — KlaDCoreTests
//
// Real-APFS fixture tests for the getattrlistbulk scanner plus the model
// invariants the UI relies on.

import Darwin
import Foundation
import Testing
@testable import KlaDModels
@testable import KlaDScanner

/// A temp directory with an APFS clone, a hard link, a sparse file and nesting.
private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("klad-core-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 3 << 20)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 2654435761 >> 13) }
        try Data(bytes).write(to: root.appendingPathComponent("original.bin"))
        try Data(bytes.prefix(1 << 20)).write(to: root.appendingPathComponent("nested/one-mb.bin"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("nested/deeper/small.txt"))
        // APFS clone (shares every block with original.bin).
        let rc = clonefile(root.appendingPathComponent("original.bin").path, root.appendingPathComponent("clone.bin").path, 0)
        precondition(rc == 0, "clonefile failed: \(errno)")
        // Hard link (same inode as one-mb.bin).
        try fm.linkItem(at: root.appendingPathComponent("nested/one-mb.bin"), to: root.appendingPathComponent("hardlink.bin"))
        // Sparse file: 256 MiB logical, 64 KiB written at the end.
        let fd = open(root.appendingPathComponent("sparse.bin").path, O_CREAT | O_WRONLY, 0o644)
        precondition(fd >= 0)
        let tail = [UInt8](repeating: 7, count: 64 << 10)
        _ = tail.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t((256 << 20) - (64 << 10))) }
        close(fd)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// Σ st_blocks·512 over unique inodes, like du.
    func duAllocated() -> UInt64 {
        var seen = Set<UInt64>()
        var total: UInt64 = 0
        let enumerator = FileManager.default.enumerator(atPath: root.path)!
        while let relative = enumerator.nextObject() as? String {
            var st = stat()
            guard lstat(root.appendingPathComponent(relative).path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            if seen.insert(UInt64(st.st_ino)).inserted { total += UInt64(st.st_blocks) * 512 }
        }
        return total
    }
}

@Suite("Bulk APFS scanner on a real fixture")
struct ScannerTests {
    private func scan(_ path: String) async throws -> ScanResult {
        try await BulkAPFSScanner().scan(ScanOptions(rootPath: path)) { _ in }
    }

    @Test func attributePackingMatchesLstat() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let report = ScannerDiagnostics.verifyAttributePacking(directory: fixture.root.path)
        #expect(report.rows.count == 5)   // original, clone, hardlink, sparse, nested/
        #expect(report.mismatchCount == 0, "\(report)")
        #expect(report.privateSizeReturned == report.rows.count)
    }

    @Test func totalsMatchDuAndCountHardLinksOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await scan(fixture.root.path)
        let m = result.root.metrics
        #expect(m.allocatedBytes == fixture.duAllocated())
        #expect(m.fileCount == 6)              // original, clone, hardlink, sparse, one-mb, small
        #expect(m.directoryCount == 2)
        #expect(result.hardLinkDuplicateCount == 1)
        #expect(result.privateSizeSupported)
        #expect(result.root.name == ScanSession.resolve(fixture.root.path))
    }

    @Test func cloneSparseAndHardLinkAccounting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try await scan(fixture.root.path).root
        let clone = try #require(root.child(named: "clone.bin"))
        let original = try #require(root.child(named: "original.bin"))
        #expect(clone.flags.contains(.sharesAllBlocks))
        #expect(clone.cloneID != 0 && clone.cloneID == original.cloneID)
        #expect(clone.metrics.privateBytes == 0, "a pure clone frees nothing when deleted")
        #expect(clone.metrics.allocatedBytes == 3 << 20)

        let sparse = try #require(root.child(named: "sparse.bin"))
        #expect(sparse.flags.contains(.sparse))
        #expect(sparse.metrics.logicalBytes == 256 << 20)
        #expect(sparse.metrics.allocatedBytes < 1 << 20)

        let linkA = try #require(root.child(named: "hardlink.bin"))
        let linkB = try #require(root.descendant(atPath: root.path + "/nested/one-mb.bin"))
        #expect(linkA.flags.contains(.hardLinked) && linkB.flags.contains(.hardLinked))
        #expect(linkA.metrics.privateBytes == 0 && linkB.metrics.privateBytes == 0)
        #expect([linkA, linkB].filter { $0.flags.contains(.hardLinkDuplicate) }.count == 1)
    }

    @Test func childrenAreSortedAndAggregatesConsistent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try await scan(fixture.root.path).root
        root.walk { node in
            if node.isDirectory {
                var sum = StorageMetrics.zero
                for child in node.children { sum.add(child.aggregateContribution) }
                #expect(sum == node.metrics, "aggregate mismatch at \(node.path)")
                let sizes = node.children.map(\.metrics.allocatedBytes)
                #expect(sizes == sizes.sorted(by: >))
            }
            return .continue
        }
    }

    @Test func rescanSubtreeMatchesFullScan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let full = try await scan(fixture.root.path).root
        let nestedPath = full.path + "/nested"
        let fresh = try await BulkAPFSScanner().rescanSubtree(atPath: nestedPath, options: ScanOptions(rootPath: nestedPath))
        #expect(fresh.name == "nested")
        let original = try #require(full.descendant(atPath: nestedPath))
        #expect(fresh.metrics.fileCount == original.metrics.fileCount)
        // In the full scan the hard link at the root was seen first and carries the
        // bytes; scanned alone, nested/one-mb.bin is the primary sighting.
        let linkBytes: UInt64 = 1 << 20
        #expect(fresh.metrics.logicalBytes == original.metrics.logicalBytes + linkBytes)
        // Splice it back: ancestors stay consistent.
        let before = full.metrics
        #expect(original.replace(with: fresh))
        #expect(full.metrics.fileCount == before.fileCount)
        #expect(fresh.parent === full)
        #expect(fresh.path == nestedPath)
    }

    @Test func excludedPathsAreNotDescended() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let resolved = ScanSession.resolve(fixture.root.path)
        let result = try await BulkAPFSScanner().scan(ScanOptions(rootPath: resolved, excludedPaths: [resolved + "/nested"])) { _ in }
        let nested = try #require(result.root.child(named: "nested"))
        #expect(nested.flags.contains(.excluded))
        #expect(nested.children.isEmpty)
    }

    @Test func rejectsMissingRoot() async {
        await #expect(throws: ScannerError.self) {
            _ = try await BulkAPFSScanner().scan(ScanOptions(rootPath: "/definitely/not/here-\(UUID())")) { _ in }
        }
    }

    @Test func datalessGuardEngagesOnThread() {
        #expect(DatalessMaterializationGuard.engageForCurrentThread())
    }
}

@Suite("FileTreeNode invariants")
struct FileTreeNodeTests {
    private func makeTree() -> FileTreeNode {
        let root = FileTreeNode.directory("/Users/t", children: [
            .directory("proj", children: [
                .file("package.json", logical: 500),
                .directory("node_modules", children: [.file("a.js", logical: 10_000), .file("b.js", logical: 20_000)]),
            ]),
            .file("movie.mov", logical: 5_000_000),
        ])
        root.recomputeAggregates()
        return root
    }

    @Test func removalPropagatesToAncestors() throws {
        let root = makeTree()
        let before = root.metrics
        let modules = try #require(root.descendant(atPath: "/Users/t/proj/node_modules"))
        let removed = modules.metrics
        #expect(modules.removeFromParent())
        #expect(root.metrics.allocatedBytes == before.allocatedBytes - removed.allocatedBytes)
        #expect(root.metrics.fileCount == before.fileCount - 2)
        #expect(root.metrics.directoryCount == before.directoryCount - 1)
        #expect(root.descendant(atPath: "/Users/t/proj/node_modules") == nil)
    }

    @Test func pathsAndLookup() throws {
        let root = makeTree()
        var paths: [String] = []
        root.walkWithPaths { node, path in
            #expect(node.path == path)
            paths.append(path)
            return .continue
        }
        #expect(paths.first == "/Users/t")
        #expect(paths.contains("/Users/t/proj/node_modules/b.js"))
        #expect(root.children.first?.name == "movie.mov")   // largest first
    }

    @Test func snapshotCaptureIsBreadthFirstAndThresholded() {
        let root = makeTree()
        let snapshot = ScanSnapshot.capture(from: root, startedAt: Date(), completedAt: Date(), volume: nil,
                                            policy: SnapshotCapturePolicy(minimumAllocatedBytes: 8_192, maxDepth: 4, maxEntries: 100))
        #expect(snapshot.entries.first?.path == "/Users/t")
        #expect(snapshot.entries.map(\.depth) == snapshot.entries.map(\.depth).sorted())
        #expect(!snapshot.entries.contains { $0.path.hasSuffix("package.json") })   // 4 KiB < 8 KiB
        #expect(snapshot.entries.contains { $0.path == "/Users/t/proj/node_modules" })
    }

    @Test func cloudPlaceholdersOccupyNoDisk() {
        let stub = FileTreeNode.file("big.mov", logical: 9_000_000_000, flags: [.cloudPlaceholder])
        #expect(stub.metrics.allocatedBytes == 0)
        #expect(stub.metrics.cloudStubBytes == 9_000_000_000)
        let candidates = DuplicateCandidate.collect(from: FileTreeNode.directory("/x", children: [stub]), minimumBytes: 1)
        #expect(candidates.isEmpty, "placeholders must never become hashing candidates")
    }
}
