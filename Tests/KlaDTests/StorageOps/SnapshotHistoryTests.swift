// SnapshotHistoryTests.swift
import Foundation
import SQLite3
import Testing
import KlaDModels
@testable import KlaDStorageOps

private let GB: UInt64 = 1 << 30

private func metrics(_ allocated: UInt64, files: UInt32 = 1) -> StorageMetrics {
    StorageMetrics(logicalBytes: allocated, allocatedBytes: allocated, privateBytes: allocated / 2,
                   cloudStubBytes: 7, fileCount: files, directoryCount: 2)
}

private func entry(_ path: String, _ depth: Int, _ allocated: UInt64, dir: Bool = true) -> SnapshotEntry {
    SnapshotEntry(path: path, depth: depth, isDirectory: dir, metrics: metrics(allocated))
}

private func snapshot(
    root: String = "/r", completed: Double, entries: [SnapshotEntry], id: UUID = UUID(), volume: VolumeSpaceReport? = nil
) -> ScanSnapshot {
    ScanSnapshot(id: id, rootPath: root, startedAt: Date(timeIntervalSince1970: completed - 10),
                 completedAt: Date(timeIntervalSince1970: completed),
                 totals: entries.first?.metrics ?? .zero, volume: volume, entries: entries)
}

private func makeService(_ scratch: ScratchDir) throws -> SnapshotHistoryService {
    try SnapshotHistoryService(databaseURL: scratch.url.appendingPathComponent("db/history.sqlite"))
}

private func countRows(_ scratch: ScratchDir, table: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(scratch.url.appendingPathComponent("db/history.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(stmt) }
    return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
}

@Suite("SnapshotHistoryService")
struct SnapshotHistoryTests {
    @Test func defaultURLShape() {
        let url = SnapshotHistoryService.defaultDatabaseURL()
        #expect(url.path.hasSuffix("KlaD/history.sqlite"))
    }

    @Test func saveLoadRoundTrip() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        let volume = VolumeSpaceReport(
            volumePath: "/", volumeName: "Macintosh HD", fileSystemType: "apfs", deviceIdentifier: "disk3s1",
            totalCapacity: 1 << 40, availableCapacity: 1 << 38, availableForImportantUsage: 1 << 39,
            availableForOpportunisticUsage: 1 << 39, containerReference: "disk3", localSnapshotNames: ["a", "b"],
            supportsCloneMapping: true, supportsPrivateSize: true, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        // Deliberately not path-sorted, with extreme values, to prove order + bit patterns survive.
        let big = StorageMetrics(logicalBytes: UInt64.max, allocatedBytes: UInt64.max - 1, privateBytes: 1 << 63,
                                 cloudStubBytes: 5, fileCount: UInt32.max, directoryCount: 9)
        let entries = [
            SnapshotEntry(path: "/r", depth: 0, isDirectory: true, metrics: big),
            entry("/r/zeta", 1, 5 * GB), entry("/r/alpha", 1, 3 * GB),
            entry("/r/zeta/file.bin", 2, GB, dir: false),
        ]
        let snap = snapshot(completed: 1_700_000_100.25, entries: entries, volume: volume)
        try await service.save(snap)

        let loaded = try #require(try await service.load(id: snap.id))
        #expect(loaded == snap)
        #expect(loaded.entries == entries)
        #expect(loaded.volume == volume)
        #expect(loaded.totals == big)
        #expect(try await service.load(id: UUID()) == nil)
    }

    @Test func saveReplacesSameID() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        let id = UUID()
        try await service.save(snapshot(completed: 100, entries: [entry("/r", 0, GB), entry("/r/a", 1, GB)], id: id))
        try await service.save(snapshot(completed: 200, entries: [entry("/r", 0, 2 * GB)], id: id))
        let loaded = try #require(try await service.load(id: id))
        #expect(loaded.entries.count == 1)
        #expect(try await service.summaries(rootPath: nil).count == 1)
        #expect(countRows(scratch, table: "entries") == 1)
    }

    @Test func summariesNewestFirstAndFiltered() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        let a1 = snapshot(root: "/a", completed: 100, entries: [entry("/a", 0, GB)])
        let a2 = snapshot(root: "/a", completed: 300, entries: [entry("/a", 0, GB)])
        let b1 = snapshot(root: "/b", completed: 200, entries: [entry("/b", 0, GB)])
        for s in [a1, b1, a2] { try await service.save(s) }

        let all = try await service.summaries(rootPath: nil)
        #expect(all.map(\.id) == [a2.id, b1.id, a1.id])
        let onlyA = try await service.summaries(rootPath: "/a")
        #expect(onlyA.map(\.id) == [a2.id, a1.id])
        #expect(onlyA.first == a2.summary)
        #expect(try await service.summaries(rootPath: "/nope").isEmpty)
    }

    @Test func diffKinds() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        let base = snapshot(completed: 100, entries: [
            entry("/r", 0, 50 * GB), entry("/r/grew", 1, 10 * GB), entry("/r/shrank", 1, 20 * GB),
            entry("/r/gone", 1, 4 * GB), entry("/r/same", 1, 6 * GB),
        ])
        let current = snapshot(completed: 200, entries: [
            entry("/r", 0, 55 * GB), entry("/r/grew", 1, 14 * GB), entry("/r/shrank", 1, 17 * GB),
            entry("/r/new", 1, 9 * GB), entry("/r/same", 1, 6 * GB),
        ])
        try await service.save(base); try await service.save(current)
        let diff = try await service.diff(baseID: base.id, currentID: current.id, significanceBytes: 1)

        let byPath = Dictionary(uniqueKeysWithValues: diff.changes.map { ($0.path, $0) })
        #expect(byPath["/r/grew"]?.kind == .grew)
        #expect(byPath["/r/shrank"]?.kind == .shrank)
        #expect(byPath["/r/new"]?.kind == .appeared)
        #expect(byPath["/r/gone"]?.kind == .disappeared)
        #expect(byPath["/r/same"] == nil)
        #expect(byPath["/r/new"]?.before == nil)
        #expect(byPath["/r/gone"]?.after == nil)
        #expect(byPath["/r/gone"]?.allocatedDelta == -Int64(4 * GB))
        // Sorted by |delta| descending: new 9, root 5, grew 4, gone 4 (path tiebreak), shrank 3.
        let magnitudes = diff.changes.map { $0.allocatedDelta.magnitude }
        #expect(magnitudes == magnitudes.sorted(by: >))
        #expect(diff.changes.first?.path == "/r/new")
        #expect(diff.totalAllocatedDelta == Int64(5 * GB))
        #expect(diff.base == base.summary)
        #expect(diff.current == current.summary)
    }

    @Test func hotspotDominationChain() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        // root +10 GB, a +9.5 GB, a/b +9 GB: only the deepest (a/b) is a hotspot.
        let base = snapshot(completed: 100, entries: [
            entry("/r", 0, 100 * GB), entry("/r/a", 1, 50 * GB), entry("/r/a/b", 2, 20 * GB),
        ])
        var current = base
        current.id = UUID(); current.completedAt = Date(timeIntervalSince1970: 200)
        current.entries = [
            entry("/r", 0, 110 * GB), entry("/r/a", 1, 50 * GB + GB * 19 / 2), entry("/r/a/b", 2, 29 * GB),
        ]
        try await service.save(base); try await service.save(current)
        let diff = try await service.diff(baseID: base.id, currentID: current.id, significanceBytes: GB)
        #expect(diff.changes.count == 3)
        #expect(diff.hotspots.map(\.path) == ["/r/a/b"])
    }

    @Test func parentWithTwoSplitChildrenIsItselfAHotspot() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        let base = snapshot(completed: 100, entries: [
            entry("/r", 0, 100 * GB), entry("/r/p", 1, 30 * GB), entry("/r/p/c1", 2, 10 * GB), entry("/r/p/c2", 2, 10 * GB),
        ])
        let current = snapshot(completed: 200, entries: [
            entry("/r", 0, 110 * GB), entry("/r/p", 1, 40 * GB), entry("/r/p/c1", 2, 15 * GB), entry("/r/p/c2", 2, 15 * GB),
        ])
        try await service.save(base); try await service.save(current)
        let diff = try await service.diff(baseID: base.id, currentID: current.id, significanceBytes: GB)
        // root (+10) is dominated by p (+10, 100 %); p (+10) has children at 50 % each ⇒ survives.
        #expect(Set(diff.hotspots.map(\.path)) == ["/r/p", "/r/p/c1", "/r/p/c2"])
        #expect(diff.hotspots.first?.path == "/r/p")
    }

    @Test func hotspotsRespectSignificanceAndSign() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        // Parent grows +10, but its only changed child *shrinks* by 10 ⇒ opposite sign does not dominate.
        let base = snapshot(completed: 100, entries: [entry("/r", 0, 50 * GB), entry("/r/x", 1, 20 * GB)])
        let current = snapshot(completed: 200, entries: [entry("/r", 0, 60 * GB), entry("/r/x", 1, 10 * GB)])
        try await service.save(base); try await service.save(current)
        let diff = try await service.diff(baseID: base.id, currentID: current.id, significanceBytes: GB)
        #expect(Set(diff.hotspots.map(\.path)) == ["/r", "/r/x"])
        let strict = try await service.diff(baseID: base.id, currentID: current.id, significanceBytes: 11 * GB)
        #expect(strict.hotspots.isEmpty)
    }

    @Test func diffThrowsForMissingID() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        let snap = snapshot(completed: 100, entries: [entry("/r", 0, GB)])
        try await service.save(snap)
        let missing = UUID()
        do {
            _ = try await service.diff(baseID: snap.id, currentID: missing, significanceBytes: 0)
            Issue.record("expected notFound")
        } catch let SnapshotHistoryError.notFound(id) {
            #expect(id == missing)
        }
        do {
            _ = try await service.diff(baseID: missing, currentID: snap.id, significanceBytes: 0)
            Issue.record("expected notFound")
        } catch let SnapshotHistoryError.notFound(id) {
            #expect(id == missing)
        }
    }

    @Test func pruneKeepsNewestPerRoot() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        var aIDs: [UUID] = [], bIDs: [UUID] = []
        for i in 0..<4 {
            let a = snapshot(root: "/a", completed: Double(100 + i), entries: [entry("/a", 0, GB)])
            aIDs.append(a.id); try await service.save(a)
        }
        for i in 0..<2 {
            let b = snapshot(root: "/b", completed: Double(500 + i), entries: [entry("/b", 0, GB)])
            bIDs.append(b.id); try await service.save(b)
        }
        try await service.prune(keepingLatest: 2)
        let a = try await service.summaries(rootPath: "/a")
        #expect(a.map(\.id) == [aIDs[3], aIDs[2]])
        #expect(try await service.summaries(rootPath: "/b").count == 2)
        #expect(countRows(scratch, table: "entries") == 4)
        try await service.prune(keepingLatest: 0)
        #expect(try await service.summaries(rootPath: nil).isEmpty)
    }

    @Test func deleteCascadesEntries() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        let s1 = snapshot(completed: 100, entries: [entry("/r", 0, GB), entry("/r/a", 1, GB)])
        let s2 = snapshot(completed: 200, entries: [entry("/r", 0, GB), entry("/r/b", 1, GB)])
        try await service.save(s1); try await service.save(s2)
        #expect(countRows(scratch, table: "entries") == 4)
        try await service.delete(id: s1.id)
        #expect(countRows(scratch, table: "entries") == 2)
        #expect(try await service.load(id: s1.id) == nil)
        try await service.delete(id: s1.id) // idempotent
        #expect(try await service.summaries(rootPath: nil).map(\.id) == [s2.id])
    }

    @Test func reopeningKeepsData() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let snap = snapshot(completed: 100, entries: [entry("/r", 0, GB)])
        do {
            let service = try makeService(scratch)
            try await service.save(snap)
        }
        let reopened = try makeService(scratch)
        #expect(try await reopened.load(id: snap.id) == snap)
    }

    @Test func saves25kEntriesQuickly() async throws {
        let scratch = try ScratchDir("hist"); defer { scratch.cleanup() }
        let service = try makeService(scratch)
        var entries = [entry("/big", 0, 100 * GB)]
        for i in 1..<25_000 { entries.append(entry("/big/dir\(i / 100)/item\(i)", 2, UInt64(i) << 20, dir: i % 7 == 0)) }
        let snap = snapshot(root: "/big", completed: 100, entries: entries)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await service.save(snap) }
        print("save(25_000 entries) took \(elapsed)")
        // The brief targets < 1 s in release; allow slack for unoptimized test builds.
        #expect(elapsed < .seconds(5))
        let loaded = try #require(try await service.load(id: snap.id))
        #expect(loaded.entries.count == 25_000)
        #expect(loaded.entries == entries)
    }
}
