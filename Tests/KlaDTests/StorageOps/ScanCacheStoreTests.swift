// ScanCacheStoreTests.swift
import CryptoKit
import Foundation
import Testing
import KlaDModels
@testable import KlaDStorageOps

// MARK: - Tree helpers

/// Iteratively compares two trees field by field. Returns the first difference, or nil.
private func firstDifference(_ a: FileTreeNode, _ b: FileTreeNode) -> String? {
    var stack: [(FileTreeNode, FileTreeNode, String)] = [(a, b, a.name)]
    while let (x, y, path) = stack.popLast() {
        if x.name != y.name { return "\(path): name \(x.name) ≠ \(y.name)" }
        if x.kind != y.kind { return "\(path): kind" }
        if x.flags != y.flags { return "\(path): flags \(x.flags) ≠ \(y.flags)" }
        if x.fileID != y.fileID { return "\(path): fileID" }
        if x.deviceID != y.deviceID { return "\(path): deviceID" }
        if x.modificationTime != y.modificationTime { return "\(path): mtime" }
        if x.cloneID != y.cloneID { return "\(path): cloneID" }
        if x.errorCode != y.errorCode { return "\(path): errorCode" }
        if x.metrics != y.metrics { return "\(path): metrics \(x.metrics) ≠ \(y.metrics)" }
        if x.newestModificationTime != y.newestModificationTime { return "\(path): newestModificationTime" }
        if x.children.count != y.children.count { return "\(path): child count \(x.children.count) ≠ \(y.children.count)" }
        for (cx, cy) in zip(x.children, y.children) {
            if cy.parent !== y { return "\(path)/\(cy.name): parent link not wired" }
            stack.append((cx, cy, path + "/" + cx.name))
        }
    }
    return nil
}

/// A small tree that exercises every field the format stores.
private func sampleTree(rootName: String = "/Users/test/Project") -> FileTreeNode {
    let big = FileTreeNode.file("big.bin", logical: 5_000_000, modificationTime: 1_700_000_500, fileID: 11, cloneID: 77)
    big.flags.insert([.mayShareBlocks, .sharesAllBlocks])
    let clone = FileTreeNode.file("clone.bin", logical: 5_000_000, modificationTime: 1_700_000_400, fileID: 12, cloneID: 77)
    clone.flags.insert([.mayShareBlocks, .sharesAllBlocks])
    let stub = FileTreeNode.file("evicted.mov", logical: 9_000_000, flags: [.cloudPlaceholder], modificationTime: 1_600_000_000, fileID: 13)
    let hardA = FileTreeNode.file("link-a", logical: 100, modificationTime: 1_650_000_000, fileID: 14)
    hardA.flags.insert(.hardLinked)
    let hardB = FileTreeNode.file("link-b", logical: 100, flags: [.hardLinked, .hardLinkDuplicate], modificationTime: 1_650_000_000, fileID: 14)
    let symlink = FileTreeNode(name: "alias", kind: .symlink,
                               metrics: StorageMetrics(logicalBytes: 12, allocatedBytes: 0, privateBytes: 0, fileCount: 1),
                               fileID: 15, deviceID: 16, modificationTime: 1_660_000_000)
    let fifo = FileTreeNode(name: "pipe", kind: .other,
                            metrics: StorageMetrics(fileCount: 1), fileID: 16, deviceID: 16, modificationTime: 1_660_000_001)
    let unreadable = FileTreeNode(name: "locked", kind: .directory, flags: [.unreadable, .protectedLocation],
                                  fileID: 17, deviceID: 16, modificationTime: 1_610_000_000, errorCode: 1)
    let opaque = FileTreeNode.opaque("macOS", bytes: 12_345_678_901, category: .system,
                                     annotation: NodeAnnotation(ruleID: "x", title: "macOS", safety: .doNotDelete, group: .system, reason: "r"))
    let unicode = FileTreeNode.file("résumé 日本語 🌲.txt", logical: 1234, modificationTime: 1_690_000_000, fileID: 18)
    let inner = FileTreeNode.directory("src", modificationTime: 1_680_000_000, flags: [.package], fileID: 19,
                                       children: [big, clone, hardA, hardB])
    let empty = FileTreeNode.directory("empty", modificationTime: 1_500_000_000, fileID: 20)
    let root = FileTreeNode.directory(rootName, modificationTime: 1_700_001_000, fileID: 2,
                                      children: [inner, stub, symlink, fifo, unreadable, opaque, unicode, empty])
    // The scanner stamps one device on everything; vary it here to prove it round-trips.
    root.recomputeAggregates(sortChildren: true)
    return root
}

private func sampleMeta(_ root: FileTreeNode, scannedAt: Double = 1_700_002_000, fsEventsID: UInt64 = 987_654_321) -> ScanCacheMeta {
    ScanCacheMeta(rootPath: root.name, scannedAt: Date(timeIntervalSince1970: scannedAt), fsEventsID: fsEventsID,
                  privateSizeSupported: true, unreadableCount: 1, nodeCount: 0)
}

/// Builds a deterministic synthetic tree of ~`targetNodes` nodes, iteratively (no recursion).
private func syntheticTree(targetNodes: Int, fanout: Int = 12, rootName: String = "/synthetic") -> (root: FileTreeNode, count: Int) {
    var generator = SeededGenerator(seed: 2024)
    let root = FileTreeNode(name: rootName, kind: .directory, fileID: 1, deviceID: 16, modificationTime: 1_700_000_000)
    var count = 1
    var queue: [FileTreeNode] = [root]
    var head = 0
    while head < queue.count, count < targetNodes {
        let directory = queue[head]; head += 1
        var children: [FileTreeNode] = []
        for index in 0..<fanout where count < targetNodes {
            let random = generator.next()
            if index % 4 == 0 {
                let child = FileTreeNode(name: "dir\(count)", kind: .directory, fileID: UInt64(count) + 100,
                                         deviceID: 16, modificationTime: 1_690_000_000 + Int64(random % 10_000_000))
                children.append(child)
                queue.append(child)
            } else {
                let logical = random % 50_000_000
                let allocated = (logical + 4095) / 4096 * 4096
                let child = FileTreeNode(
                    name: "file-\(count).dat", kind: .file,
                    metrics: StorageMetrics(logicalBytes: logical, allocatedBytes: allocated, privateBytes: allocated, fileCount: 1),
                    flags: index % 7 == 0 ? [.mayShareBlocks] : [], fileID: UInt64(count) + 100, deviceID: 16,
                    modificationTime: 1_690_000_000 + Int64(random % 10_000_000), cloneID: index % 11 == 0 ? random % 1000 : 0)
                children.append(child)
            }
            count += 1
        }
        directory.setChildren(children)
    }
    root.recomputeAggregates(sortChildren: true)
    return (root, count)
}

/// Wraps a raw (uncompressed) body in a .kladscan container exactly as the format describes.
private func container(
    raw: [UInt8], nodeCount: UInt64, magic: String = "KLAD", version: UInt16 = 1, rawLength: UInt64? = nil, checksum: UInt64? = nil
) throws -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
    let compressed = try (Data(raw) as NSData).compressed(using: .lzfse) as Data
    var file = Data(magic.utf8)
    file.append(contentsOf: le(version))
    file.append(contentsOf: le(nodeCount))
    file.append(contentsOf: le(rawLength ?? UInt64(raw.count)))
    file.append(contentsOf: le(UInt64(compressed.count)))
    file.append(contentsOf: le(checksum ?? ScanCacheStore.checksum(raw)))
    file.append(compressed)
    return file
}

private struct RawNode {
    var kind: UInt8 = 1
    var name = "/root"
    var childCount: UInt32 = 0
    var nameLengthOverride: UInt16?
    var metrics = true

    func bytes() -> [UInt8] {
        func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        var out: [UInt8] = [kind]
        out += le(UInt32(0)) + le(UInt64(1)) + le(Int32(1)) + le(Int64(1)) + le(UInt64(0)) + le(Int32(0))
        out += le(nameLengthOverride ?? UInt16(name.utf8.count))
        out += Array(name.utf8)
        out += le(childCount)
        if kind != 1, metrics { out += le(UInt64(1)) + le(UInt64(1)) + le(UInt64(1)) + le(UInt64(0)) }
        return out
    }
}

private func store(_ scratch: ScratchDir) throws -> ScanCacheStore {
    try ScanCacheStore(directory: scratch.url.appendingPathComponent("cache"))
}

@Suite("ScanCacheStore")
struct ScanCacheStoreTests {
    // MARK: Round trip

    @Test func roundTripPreservesEveryField() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let cache = try store(scratch)
        let root = sampleTree()
        let meta = sampleMeta(root)
        try await cache.save(root, meta: meta)

        let (loaded, loadedMeta) = try #require(try await cache.load(rootPath: root.name))
        #expect(firstDifference(root, loaded) == nil, "\(firstDifference(root, loaded) ?? "")")
        #expect(loaded.metrics == root.metrics)
        #expect(loaded.parent == nil)
        #expect(loadedMeta.rootPath == meta.rootPath)
        #expect(loadedMeta.fsEventsID == 987_654_321)
        #expect(loadedMeta.scannedAt == meta.scannedAt)
        #expect(loadedMeta.privateSizeSupported && loadedMeta.unreadableCount == 1)
        #expect(loadedMeta.nodeCount == 1 + 8 + 4 + 0)   // root + its 8 children + src's 4 children

        // Spot checks on semantics the aggregation must restore.
        let src = try #require(loaded.child(named: "src"))
        #expect(src.flags.contains(.package))
        #expect(src.metrics.fileCount == 4)
        let opaque = try #require(loaded.child(named: "macOS"))
        #expect(opaque.isOpaque && opaque.metrics.fileCount == 0 && opaque.metrics.allocatedBytes == 12_345_678_901)
        #expect(opaque.annotation == nil, "annotations are not stored")
        let stub = try #require(loaded.child(named: "evicted.mov"))
        #expect(stub.metrics.cloudStubBytes == 9_000_000 && stub.metrics.allocatedBytes == 0)
        let hardDuplicate = try #require(src.child(named: "link-b"))
        #expect(hardDuplicate.flags.contains(.hardLinkDuplicate) && hardDuplicate.aggregateContribution.allocatedBytes == 0)
        #expect(try #require(loaded.child(named: "locked")).errorCode == 1)
        #expect(loaded.flags.contains(.incompleteSubtree), "unreadable child ⇒ incomplete subtree is re-derived")
        #expect(loaded.child(named: "résumé 日本語 🌲.txt") != nil)
        #expect(loaded.descendant(atPath: root.name + "/src/big.bin")?.cloneID == 77)
    }

    @Test func childrenComeBackSortedBySize() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let cache = try store(scratch)
        let root = sampleTree()
        try await cache.save(root, meta: sampleMeta(root))
        let loaded = try #require(try await cache.load(rootPath: root.name)).root
        let sizes = loaded.children.map(\.metrics.allocatedBytes)
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test func missingCacheLoadsAsNil() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let cache = try store(scratch)
        #expect(try await cache.load(rootPath: "/never/scanned") == nil)
        #expect(await cache.cachedScans().isEmpty)
        try await cache.remove(rootPath: "/never/scanned")   // harmless
    }

    @Test func fileNamingAndAtomicity() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let directory = scratch.url.appendingPathComponent("cache")
        let cache = try ScanCacheStore(directory: directory)
        let root = sampleTree()
        try await cache.save(root, meta: sampleMeta(root))
        try await cache.save(root, meta: sampleMeta(root, fsEventsID: 5))   // overwrite

        let expectedHash = SHA256.hash(data: Data(root.name.utf8)).map { String(format: "%02x", $0) }.joined()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == [expectedHash + ".json", expectedHash + ".kladscan"], "no temp files may be left behind: \(names)")

        let data = try Data(contentsOf: directory.appendingPathComponent(expectedHash + ".kladscan"))
        #expect(Array(data.prefix(4)) == Array("KLAD".utf8))
        #expect(UInt16(data[4]) | UInt16(data[5]) << 8 == 1, "little-endian version 1")
        #expect(try #require(try await cache.load(rootPath: root.name)).meta.fsEventsID == 5)
    }

    @Test func cachedScansNewestFirstAndRemove() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let directory = scratch.url.appendingPathComponent("cache")
        let cache = try ScanCacheStore(directory: directory)
        let a = sampleTree(rootName: "/a"), b = sampleTree(rootName: "/b"), c = sampleTree(rootName: "/c")
        try await cache.save(a, meta: sampleMeta(a, scannedAt: 1000))
        try await cache.save(c, meta: sampleMeta(c, scannedAt: 3000))
        try await cache.save(b, meta: sampleMeta(b, scannedAt: 2000))
        #expect(await cache.cachedScans().map(\.rootPath) == ["/c", "/b", "/a"])

        try await cache.remove(rootPath: "/b")
        #expect(await cache.cachedScans().map(\.rootPath) == ["/c", "/a"])
        #expect(try await cache.load(rootPath: "/b") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 4, "both files of /b are gone")

        // An orphaned sidecar (no .kladscan) is not listed.
        let hashB = ScanCacheStore.hash(of: "/a")
        try FileManager.default.removeItem(at: directory.appendingPathComponent(hashB + ".kladscan"))
        #expect(await cache.cachedScans().map(\.rootPath) == ["/c"])
        #expect(try await cache.load(rootPath: "/a") == nil)
    }

    @Test func survivesReopeningTheDirectory() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let directory = scratch.url.appendingPathComponent("cache")
        let root = sampleTree()
        try await ScanCacheStore(directory: directory).save(root, meta: sampleMeta(root))
        let loaded = try #require(try await ScanCacheStore(directory: directory).load(rootPath: root.name))
        #expect(firstDifference(root, loaded.root) == nil)
    }

    @Test func defaultDirectoryShape() {
        #expect(ScanCacheStore.defaultDirectory().path.hasSuffix("Library/Caches/KlaD/Scans"))
    }

    @Test func overlongNamesAreRejectedOnSave() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let cache = try store(scratch)
        let root = FileTreeNode.directory("/r", children: [FileTreeNode.file(String(repeating: "x", count: 1025), logical: 1)])
        root.recomputeAggregates()
        await #expect(throws: ScanCacheError.self) { try await cache.save(root, meta: sampleMeta(root)) }
        #expect(try await cache.load(rootPath: "/r") == nil, "a failed save leaves nothing behind")
    }

    @Test func deepChainsDoNotRecurse() {
        // 50 000 levels: encode and decode must be iterative. (Releasing such a tree recurses in ARC,
        // so everything runs on a thread with a large stack.)
        let depth = 50_000
        let outcome = LockedBox<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            defer { done.signal() }
            do {
                let root = FileTreeNode(name: "/deep", kind: .directory, fileID: 1)
                var cursor = root
                for level in 0..<depth {
                    let next = FileTreeNode(name: "d", kind: .directory, fileID: UInt64(level) + 2)
                    cursor.setChildren([next])
                    cursor = next
                }
                cursor.setChildren([FileTreeNode.file("leaf.bin", logical: 100_000, fileID: 999)])
                root.recomputeAggregates()
                let (raw, count) = try ScanCacheStore.encode(root)
                let file = try container(raw: raw, nodeCount: count)
                let loaded = try ScanCacheStore.decode(file)
                if count != UInt64(depth) + 2 { outcome.mutate { $0 = "count \(count)" } }
                else if loaded.metrics != root.metrics { outcome.mutate { $0 = "metrics differ" } }
                else if loaded.metrics.directoryCount != UInt32(depth) { outcome.mutate { $0 = "directoryCount \(loaded.metrics.directoryCount)" } }
                else { outcome.mutate { $0 = "ok" } }
                // Tear down iteratively-ish: detach from the bottom so ARC never recurses deeply.
                for tree in [root, loaded] {
                    var chain: [FileTreeNode] = []
                    var node: FileTreeNode? = tree
                    while let current = node { chain.append(current); node = current.children.first }
                    for current in chain.reversed() { current.setChildren([]) }
                }
            } catch {
                outcome.mutate { $0 = "error \(error)" }
            }
        }
        thread.stackSize = 256 << 20
        thread.start()
        done.wait()
        #expect(outcome.value == "ok", "\(outcome.value ?? "nil")")
    }

    // MARK: Corruption

    private func writeRaw(_ data: Data, for rootPath: String, in scratch: ScratchDir, meta: ScanCacheMeta? = nil) throws -> ScanCacheStore {
        let directory = scratch.url.appendingPathComponent("cache")
        let cache = try ScanCacheStore(directory: directory)
        let hash = ScanCacheStore.hash(of: rootPath)
        try data.write(to: directory.appendingPathComponent(hash + ".kladscan"))
        let meta = meta ?? ScanCacheMeta(rootPath: rootPath, scannedAt: Date(), fsEventsID: 1, privateSizeSupported: true,
                                         unreadableCount: 0, nodeCount: 1)
        try JSONEncoder().encode(meta).write(to: directory.appendingPathComponent(hash + ".json"))
        return cache
    }

    private func expectCorrupt(_ data: Data, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try ScanCacheStore.decode(data)
            Issue.record("\(label): expected a ScanCacheError", sourceLocation: sourceLocation)
        } catch is ScanCacheError {
            // expected
        } catch {
            Issue.record("\(label): wrong error type \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func malformedBodiesThrowTypedErrors() throws {
        let valid = RawNode().bytes()

        // sanity: the hand-built container is itself valid
        #expect(throws: Never.self) { _ = try ScanCacheStore.decode(try container(raw: RawNode(kind: 1).bytes(), nodeCount: 1)) }

        expectCorrupt(try container(raw: valid, nodeCount: 1, magic: "NOPE"), "bad magic")
        expectCorrupt(try container(raw: valid, nodeCount: 1, rawLength: 1 << 40), "absurd raw length")
        expectCorrupt(try container(raw: valid, nodeCount: 1, rawLength: UInt64(valid.count) + 5), "raw length lies (too long)")
        expectCorrupt(try container(raw: valid, nodeCount: 1, rawLength: UInt64(valid.count) - 1), "raw length lies (too short)")
        expectCorrupt(try container(raw: valid, nodeCount: 1, checksum: 12345), "bad checksum")
        expectCorrupt(try container(raw: valid, nodeCount: 0), "zero nodes")
        expectCorrupt(try container(raw: valid, nodeCount: 1 << 40), "absurd node count")
        expectCorrupt(try container(raw: valid, nodeCount: 5), "node count larger than the body")
        expectCorrupt(try container(raw: valid + valid, nodeCount: 1), "trailing data")
        expectCorrupt(try container(raw: RawNode(kind: 9).bytes(), nodeCount: 1), "unknown kind")
        expectCorrupt(try container(raw: RawNode(childCount: UInt32.max).bytes(), nodeCount: 1), "child count ≫ node count")
        expectCorrupt(try container(raw: RawNode(childCount: 3).bytes() + RawNode(name: "a").bytes(), nodeCount: 2), "children announced > nodes")
        expectCorrupt(try container(raw: RawNode(childCount: 2).bytes() + RawNode(name: "a").bytes(), nodeCount: 3), "missing child nodes")
        expectCorrupt(try container(raw: RawNode(nameLengthOverride: 5000).bytes(), nodeCount: 1), "name length 5000")
        expectCorrupt(try container(raw: RawNode(nameLengthOverride: 60).bytes(), nodeCount: 1), "name length beyond the body")
        expectCorrupt(try container(raw: RawNode(name: "").bytes(), nodeCount: 1), "empty root name")
        expectCorrupt(try container(raw: RawNode(childCount: 1).bytes() + RawNode(name: "a/b").bytes(), nodeCount: 2), "slash in name")
        expectCorrupt(try container(raw: RawNode(childCount: 1).bytes() + RawNode(name: "").bytes(), nodeCount: 2), "empty child name")
        expectCorrupt(try container(raw: RawNode(childCount: 1).bytes() + RawNode(kind: 0, name: "f", childCount: 1).bytes() + RawNode(name: "g").bytes(),
                                    nodeCount: 3), "file with children")
        expectCorrupt(try container(raw: [1, 2, 3], nodeCount: 1), "body too short for a node")
        expectCorrupt(Data(), "empty file")
        expectCorrupt(Data("KLAD".utf8), "header only")

        // A future version is reported as such.
        do {
            _ = try ScanCacheStore.decode(try container(raw: valid, nodeCount: 1, version: 2))
            Issue.record("version 2 must not load")
        } catch let error as ScanCacheError {
            #expect(error == .unsupportedVersion(2))
        }
    }

    @Test func wellFormedHandBuiltFileLoads() throws {
        // root dir with two leaf children (a file and a symlink), written by hand per the documented layout.
        let raw = RawNode(kind: 1, name: "/r", childCount: 2).bytes()
            + RawNode(kind: 0, name: "f").bytes() + RawNode(kind: 2, name: "l").bytes()
        let root = try ScanCacheStore.decode(try container(raw: raw, nodeCount: 3))
        #expect(root.name == "/r" && root.children.count == 2)
        #expect(root.metrics.fileCount == 2 && root.metrics.allocatedBytes == 2)
    }

    @Test func loadThrowsForCorruptFilesAndMismatchedMetadata() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let garbage = try writeRaw(Data("definitely not a scan".utf8), for: "/g", in: scratch)
        await #expect(throws: ScanCacheError.self) { _ = try await garbage.load(rootPath: "/g") }

        // Valid tree stored under another root's name ⇒ rejected.
        let valid = try container(raw: RawNode(name: "/other").bytes(), nodeCount: 1)
        let wrongRoot = try writeRaw(valid, for: "/expected", in: scratch)
        await #expect(throws: ScanCacheError.self) { _ = try await wrongRoot.load(rootPath: "/expected") }

        // Unreadable sidecar.
        let directory = scratch.url.appendingPathComponent("cache")
        try Data("{nope".utf8).write(to: directory.appendingPathComponent(ScanCacheStore.hash(of: "/g") + ".json"))
        await #expect(throws: ScanCacheError.self) { _ = try await garbage.load(rootPath: "/g") }
    }

    @Test func everyTruncationOfAValidFileThrows() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let cache = try store(scratch)
        let root = sampleTree()
        try await cache.save(root, meta: sampleMeta(root))
        let url = scratch.url.appendingPathComponent("cache/\(ScanCacheStore.hash(of: root.name)).kladscan")
        let valid = try Data(contentsOf: url)
        #expect(throws: Never.self) { _ = try ScanCacheStore.decode(valid) }

        for length in 0..<valid.count {
            expectCorrupt(valid.prefix(length), "truncated to \(length) of \(valid.count) bytes")
        }
    }

    @Test func randomByteFlipsNeverCrashAndNearlyAlwaysThrow() async throws {
        let (root, _) = syntheticTree(targetNodes: 400)
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let cache = try store(scratch)
        try await cache.save(root, meta: sampleMeta(root))
        let url = scratch.url.appendingPathComponent("cache/\(ScanCacheStore.hash(of: root.name)).kladscan")
        let valid = try Data(contentsOf: url)

        var generator = SeededGenerator(seed: 99)
        var threw = 0, loaded = 0
        let iterations = 600
        for _ in 0..<iterations {
            var corrupted = valid
            let flips = Int.random(in: 1...4, using: &generator)
            for _ in 0..<flips {
                let position = Int.random(in: 0..<corrupted.count, using: &generator)
                corrupted[position] ^= UInt8.random(in: 1...255, using: &generator)
            }
            do { _ = try ScanCacheStore.decode(corrupted); loaded += 1 }
            catch is ScanCacheError { threw += 1 }
            catch { Issue.record("non-ScanCacheError thrown: \(error)") }
        }
        print("byte-flip fuzz: \(threw) threw, \(loaded) loaded of \(iterations)")
        #expect(threw + loaded == iterations)
        #expect(threw >= iterations * 95 / 100, "the checksum should catch almost every flip")

        // Garbage appended / prepended.
        expectCorrupt(valid + Data([0, 1, 2]), "appended bytes")
        expectCorrupt(Data([0xFF]) + valid, "prepended byte")
    }

    @Test func fuzzedRawBodiesWithValidChecksumsNeverCrash() throws {
        // Bypass the checksum: corrupt the *raw* body, then re-wrap it, so the node decoder itself is fuzzed.
        let (root, _) = syntheticTree(targetNodes: 300)
        let (raw, count) = try ScanCacheStore.encode(root)
        var generator = SeededGenerator(seed: 5)
        var threw = 0, loaded = 0
        for _ in 0..<1500 {
            var body = raw
            switch Int.random(in: 0..<3, using: &generator) {
            case 0:   // flip bytes
                for _ in 0..<Int.random(in: 1...5, using: &generator) {
                    body[Int.random(in: 0..<body.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
            case 1:   // truncate
                body.removeLast(Int.random(in: 1..<min(body.count, 400), using: &generator))
            default:  // overwrite a run with 0xFF (huge counts / lengths)
                let start = Int.random(in: 0..<body.count - 8, using: &generator)
                for i in start..<start + 8 { body[i] = 0xFF }
            }
            let file = try container(raw: body, nodeCount: count)
            do { _ = try ScanCacheStore.decode(file); loaded += 1 }
            catch is ScanCacheError { threw += 1 }
            catch { Issue.record("non-ScanCacheError thrown: \(error)") }
        }
        print("raw-body fuzz: \(threw) threw, \(loaded) loaded")
        #expect(threw + loaded == 1500)
        #expect(threw > 0)
    }

    // MARK: Scale

    @Test func threeHundredThousandNodesRoundTripQuickly() async throws {
        let scratch = try ScratchDir("cache"); defer { scratch.cleanup() }
        let cache = try store(scratch)
        // KLAD_CACHE_BENCH_NODES=2500000 + a release build checks the 2.5 M-node target.
        let target = Int(ProcessInfo.processInfo.environment["KLAD_CACHE_BENCH_NODES"] ?? "") ?? 300_000
        let (root, count) = syntheticTree(targetNodes: target)
        #expect(count >= target)
        let meta = sampleMeta(root)
        let clock = ContinuousClock()

        let saveTime = try await clock.measure { try await cache.save(root, meta: meta) }
        let url = scratch.url.appendingPathComponent("cache/\(ScanCacheStore.hash(of: root.name)).kladscan")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)

        var loaded: (root: FileTreeNode, meta: ScanCacheMeta)?
        let loadTime = try await clock.measure { loaded = try await cache.load(rootPath: root.name) }
        let result = try #require(loaded)

        let bytesPerNode = Double(size) / Double(count)
        print("scan cache \(count) nodes: save \(saveTime), load \(loadTime), file \(size) bytes = \(String(format: "%.1f", bytesPerNode)) bytes/node")
        // Targets are for release builds (2.5 M nodes ≤ 3 s); generous slack for unoptimised test builds.
        #expect(saveTime < .seconds(20))
        #expect(loadTime < .seconds(20))
        #expect(bytesPerNode < 40)
        #expect(result.meta.nodeCount == count)
        #expect(result.root.metrics == root.metrics)
        #expect(firstDifference(root, result.root) == nil, "\(firstDifference(root, result.root) ?? "")")
    }
}
