// SnapshotHistoryService.swift — KlaDStorageOps
//
// SQLite-backed history of scan snapshots + the "where did my space go?" diff.
// Uses the raw SQLite3 C API (WAL, prepared statements, one transaction per save).

import Foundation
import SQLite3
import KlaDModels

// MARK: - Errors

public enum SnapshotHistoryError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case sqlite(code: Int32, message: String)
    case notFound(UUID)

    public var description: String {
        switch self {
        case let .sqlite(code, message): return "SQLite error \(code): \(message)"
        case let .notFound(id): return "No stored snapshot with id \(id.uuidString)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Service

public actor SnapshotHistoryService: SnapshotHistoryStoring {
    private static let schemaVersion: Int32 = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Owns the connection so the (nonisolated) deinit can close it.
    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close_v2(pointer) }
    }

    private let connection: Connection
    private var db: OpaquePointer { connection.pointer }

    /// Opens (creating if needed) the database at `databaseURL`, including its
    /// parent directory and the v1 schema.
    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close_v2(handle) }
            throw SnapshotHistoryError.sqlite(code: rc, message: message)
        }
        do {
            try Self.configure(opened)
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
        self.connection = Connection(opened)
    }

    /// `~/Library/Application Support/KlaD/history.sqlite`
    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KlaD", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    // MARK: Schema

    private static func configure(_ db: OpaquePointer) throws {
        sqlite3_busy_timeout(db, 5_000)
        // journal_mode returns a row, so go through a statement.
        try runStatement(db, "PRAGMA journal_mode=WAL")
        try runStatement(db, "PRAGMA foreign_keys=ON")
        try runStatement(db, "PRAGMA synchronous=NORMAL")

        let version = try queryInt(db, "PRAGMA user_version")
        if version > schemaVersion {
            throw SnapshotHistoryError.sqlite(
                code: SQLITE_MISMATCH,
                message: "History database schema v\(version) is newer than supported v\(schemaVersion)")
        }
        try exec(db, """
        CREATE TABLE IF NOT EXISTS snapshots(
          id TEXT PRIMARY KEY, root_path TEXT NOT NULL, started_at REAL NOT NULL, completed_at REAL NOT NULL,
          logical INTEGER, allocated INTEGER, private INTEGER, cloud INTEGER, file_count INTEGER, dir_count INTEGER,
          volume_json BLOB, entry_count INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS snapshots_root_time ON snapshots(root_path, completed_at DESC);
        CREATE TABLE IF NOT EXISTS entries(
          snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
          path TEXT NOT NULL, depth INTEGER NOT NULL, is_dir INTEGER NOT NULL,
          logical INTEGER, allocated INTEGER, private INTEGER, cloud INTEGER, file_count INTEGER, dir_count INTEGER,
          seq INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(snapshot_id, path)) WITHOUT ROWID;
        """)
        if version < schemaVersion {
            try exec(db, "PRAGMA user_version=\(schemaVersion)")
        }
    }

    // MARK: SnapshotHistoryStoring

    public func save(_ snapshot: ScanSnapshot) async throws {
        try exec(db, "BEGIN IMMEDIATE")
        do {
            try insert(snapshot)
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    public func summaries(rootPath: String?) async throws -> [ScanSnapshotSummary] {
        var sql = """
        SELECT id, root_path, started_at, completed_at, logical, allocated, private, cloud, file_count, dir_count, entry_count
        FROM snapshots
        """
        if rootPath != nil { sql += " WHERE root_path = ?1" }
        sql += " ORDER BY completed_at DESC, started_at DESC, id"
        let stmt = try Statement(db, sql)
        if let rootPath { try stmt.bind(text: rootPath, at: 1) }
        var result: [ScanSnapshotSummary] = []
        while try stmt.step() {
            if let summary = Self.readSummary(stmt) { result.append(summary) }
        }
        return result
    }

    public func load(id: UUID) async throws -> ScanSnapshot? {
        guard let summary = try loadSummary(id: id) else { return nil }
        let volumeStmt = try Statement(db, "SELECT volume_json FROM snapshots WHERE id = ?1")
        try volumeStmt.bind(text: id.uuidString, at: 1)
        var volume: VolumeSpaceReport?
        if try volumeStmt.step(), let data = volumeStmt.blob(at: 0) {
            volume = try? JSONDecoder().decode(VolumeSpaceReport.self, from: data)
        }
        let entries = try loadEntries(id: id, ordered: true)
        return ScanSnapshot(
            id: summary.id, rootPath: summary.rootPath, startedAt: summary.startedAt,
            completedAt: summary.completedAt, totals: summary.totals, volume: volume, entries: entries)
    }

    public func diff(baseID: UUID, currentID: UUID, significanceBytes: UInt64) async throws -> SnapshotDiff {
        guard let base = try loadSummary(id: baseID) else { throw SnapshotHistoryError.notFound(baseID) }
        guard let current = try loadSummary(id: currentID) else { throw SnapshotHistoryError.notFound(currentID) }
        let baseEntries = try loadEntries(id: baseID, ordered: false)
        let currentEntries = try loadEntries(id: currentID, ordered: false)
        let (changes, hotspots) = Self.computeDiff(
            base: baseEntries, current: currentEntries, significanceBytes: significanceBytes)
        return SnapshotDiff(base: base, current: current, changes: changes, hotspots: hotspots)
    }

    public func delete(id: UUID) async throws {
        let stmt = try Statement(db, "DELETE FROM snapshots WHERE id = ?1")
        try stmt.bind(text: id.uuidString, at: 1)
        _ = try stmt.step()
    }

    public func prune(keepingLatest count: Int) async throws {
        let keep = max(0, count)
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let stmt = try Statement(db, """
            DELETE FROM snapshots WHERE id IN (
              SELECT id FROM (
                SELECT id, ROW_NUMBER() OVER (PARTITION BY root_path ORDER BY completed_at DESC, started_at DESC, id) AS rn
                FROM snapshots)
              WHERE rn > ?1)
            """)
            try stmt.bind(int: Int64(keep), at: 1)
            _ = try stmt.step()
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    // MARK: Writing

    private func insert(_ snapshot: ScanSnapshot) throws {
        let idText = snapshot.id.uuidString

        // Replace semantics: drop any previous version (entries cascade).
        let del = try Statement(db, "DELETE FROM snapshots WHERE id = ?1")
        try del.bind(text: idText, at: 1)
        _ = try del.step()

        let head = try Statement(db, """
        INSERT INTO snapshots(id, root_path, started_at, completed_at, logical, allocated, private, cloud,
                              file_count, dir_count, volume_json, entry_count)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
        """)
        try head.bind(text: idText, at: 1)
        try head.bind(text: snapshot.rootPath, at: 2)
        try head.bind(double: snapshot.startedAt.timeIntervalSince1970, at: 3)
        try head.bind(double: snapshot.completedAt.timeIntervalSince1970, at: 4)
        try Self.bindMetrics(head, snapshot.totals, firstIndex: 5)
        if let volume = snapshot.volume {
            try head.bind(blob: try JSONEncoder().encode(volume), at: 11)
        } else {
            try head.bindNull(at: 11)
        }
        try head.bind(int: Int64(snapshot.entries.count), at: 12)
        _ = try head.step()

        let row = try Statement(db, """
        INSERT OR REPLACE INTO entries(snapshot_id, path, depth, is_dir, logical, allocated, private, cloud,
                                       file_count, dir_count, seq)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        """)
        for (index, entry) in snapshot.entries.enumerated() {
            try row.bind(text: idText, at: 1)
            try row.bind(text: entry.path, at: 2)
            try row.bind(int: Int64(entry.depth), at: 3)
            try row.bind(int: entry.isDirectory ? 1 : 0, at: 4)
            try Self.bindMetrics(row, entry.metrics, firstIndex: 5)
            try row.bind(int: Int64(index), at: 11)
            _ = try row.step()
            try row.reset()
        }
    }

    private static func bindMetrics(_ stmt: Statement, _ m: StorageMetrics, firstIndex i: Int32) throws {
        try stmt.bind(int: Int64(bitPattern: m.logicalBytes), at: i)
        try stmt.bind(int: Int64(bitPattern: m.allocatedBytes), at: i + 1)
        try stmt.bind(int: Int64(bitPattern: m.privateBytes), at: i + 2)
        try stmt.bind(int: Int64(bitPattern: m.cloudStubBytes), at: i + 3)
        try stmt.bind(int: Int64(m.fileCount), at: i + 4)
        try stmt.bind(int: Int64(m.directoryCount), at: i + 5)
    }

    // MARK: Reading

    /// Reads metrics from six consecutive columns starting at `first`.
    private static func readMetrics(_ stmt: Statement, first: Int32) -> StorageMetrics {
        StorageMetrics(
            logicalBytes: UInt64(bitPattern: stmt.int(at: first)),
            allocatedBytes: UInt64(bitPattern: stmt.int(at: first + 1)),
            privateBytes: UInt64(bitPattern: stmt.int(at: first + 2)),
            cloudStubBytes: UInt64(bitPattern: stmt.int(at: first + 3)),
            fileCount: UInt32(truncatingIfNeeded: stmt.int(at: first + 4)),
            directoryCount: UInt32(truncatingIfNeeded: stmt.int(at: first + 5)))
    }

    private static func readSummary(_ stmt: Statement) -> ScanSnapshotSummary? {
        guard let idText = stmt.text(at: 0), let id = UUID(uuidString: idText) else { return nil }
        return ScanSnapshotSummary(
            id: id,
            rootPath: stmt.text(at: 1) ?? "",
            startedAt: Date(timeIntervalSince1970: stmt.double(at: 2)),
            completedAt: Date(timeIntervalSince1970: stmt.double(at: 3)),
            totals: readMetrics(stmt, first: 4),
            entryCount: Int(stmt.int(at: 10)))
    }

    private func loadSummary(id: UUID) throws -> ScanSnapshotSummary? {
        let stmt = try Statement(db, """
        SELECT id, root_path, started_at, completed_at, logical, allocated, private, cloud, file_count, dir_count, entry_count
        FROM snapshots WHERE id = ?1
        """)
        try stmt.bind(text: id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return Self.readSummary(stmt)
    }

    private func loadEntries(id: UUID, ordered: Bool) throws -> [SnapshotEntry] {
        let stmt = try Statement(db, """
        SELECT path, depth, is_dir, logical, allocated, private, cloud, file_count, dir_count
        FROM entries WHERE snapshot_id = ?1\(ordered ? " ORDER BY seq" : "")
        """)
        try stmt.bind(text: id.uuidString, at: 1)
        var entries: [SnapshotEntry] = []
        while try stmt.step() {
            entries.append(SnapshotEntry(
                path: stmt.text(at: 0) ?? "",
                depth: Int(stmt.int(at: 1)),
                isDirectory: stmt.int(at: 2) != 0,
                metrics: Self.readMetrics(stmt, first: 3)))
        }
        return entries
    }

    // MARK: Diff

    static func computeDiff(
        base: [SnapshotEntry], current: [SnapshotEntry], significanceBytes: UInt64
    ) -> (changes: [DirectoryDelta], hotspots: [DirectoryDelta]) {
        var baseByPath: [String: SnapshotEntry] = [:]
        baseByPath.reserveCapacity(base.count)
        for entry in base { baseByPath[entry.path] = entry }
        var currentByPath: [String: SnapshotEntry] = [:]
        currentByPath.reserveCapacity(current.count)
        for entry in current { currentByPath[entry.path] = entry }

        var changes: [DirectoryDelta] = []
        func consider(_ path: String) {
            let before = baseByPath[path]
            let after = currentByPath[path]
            guard let reference = after ?? before else { return }
            let beforeAllocated = before?.metrics.allocatedBytes ?? 0
            let afterAllocated = after?.metrics.allocatedBytes ?? 0
            let kind: DeltaKind
            if before == nil { kind = .appeared }
            else if after == nil { kind = .disappeared }
            else if afterAllocated > beforeAllocated { kind = .grew }
            else if afterAllocated < beforeAllocated { kind = .shrank }
            else { kind = .unchanged }
            let delta = DirectoryDelta(
                path: path, depth: reference.depth, isDirectory: reference.isDirectory,
                before: before?.metrics, after: after?.metrics, kind: kind)
            if delta.allocatedDelta != 0 { changes.append(delta) }
        }
        for path in baseByPath.keys { consider(path) }
        for path in currentByPath.keys where baseByPath[path] == nil { consider(path) }

        changes.sort(by: Self.byMagnitude)

        // Index changed entries by parent path for the domination test.
        var childrenByParent: [String: [DirectoryDelta]] = [:]
        for change in changes {
            if let parent = parentPath(of: change.path) {
                childrenByParent[parent, default: []].append(change)
            }
        }
        let hotspots = changes.filter { change in
            guard change.allocatedDelta.magnitude >= significanceBytes else { return false }
            let delta = change.allocatedDelta
            let threshold = 0.8 * Double(delta.magnitude)
            for child in childrenByParent[change.path] ?? [] where child.depth == change.depth + 1 {
                let childDelta = child.allocatedDelta
                if (childDelta > 0) == (delta > 0), Double(childDelta.magnitude) >= threshold { return false }
            }
            return true
        }
        return (changes, hotspots)
    }

    private static func byMagnitude(_ a: DirectoryDelta, _ b: DirectoryDelta) -> Bool {
        let ma = a.allocatedDelta.magnitude, mb = b.allocatedDelta.magnitude
        return ma != mb ? ma > mb : a.path < b.path
    }

    private static func parentPath(of path: String) -> String? {
        guard path.count > 1 else { return nil }
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        guard p.count > 1, let slash = p.lastIndex(of: "/") else { return nil }
        return slash == p.startIndex ? "/" : String(p[..<slash])
    }

    // MARK: SQLite helpers

    fileprivate static func error(_ db: OpaquePointer, _ code: Int32) -> SnapshotHistoryError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(db)))
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws { try Self.exec(db, sql) }

    fileprivate static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "sqlite3_exec failed"
            sqlite3_free(errorMessage)
            throw SnapshotHistoryError.sqlite(code: rc, message: message)
        }
    }

    fileprivate static func runStatement(_ db: OpaquePointer, _ sql: String) throws {
        let stmt = try Statement(db, sql)
        while try stmt.step() {}
    }

    fileprivate static func queryInt(_ db: OpaquePointer, _ sql: String) throws -> Int32 {
        let stmt = try Statement(db, sql)
        guard try stmt.step() else { return 0 }
        return Int32(truncatingIfNeeded: stmt.int(at: 0))
    }

    /// A prepared statement, finalized on deinit. Only used inside the actor.
    fileprivate final class Statement {
        private let db: OpaquePointer
        private var stmt: OpaquePointer?

        init(_ db: OpaquePointer, _ sql: String) throws {
            self.db = db
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK else { throw SnapshotHistoryService.error(db, rc) }
        }

        deinit { sqlite3_finalize(stmt) }

        private func check(_ rc: Int32) throws {
            guard rc == SQLITE_OK else { throw SnapshotHistoryService.error(db, rc) }
        }

        func bind(text: String, at i: Int32) throws {
            try check(sqlite3_bind_text(stmt, i, text, -1, SnapshotHistoryService.transient))
        }
        func bind(int: Int64, at i: Int32) throws { try check(sqlite3_bind_int64(stmt, i, int)) }
        func bind(double: Double, at i: Int32) throws { try check(sqlite3_bind_double(stmt, i, double)) }
        func bindNull(at i: Int32) throws { try check(sqlite3_bind_null(stmt, i)) }
        func bind(blob: Data, at i: Int32) throws {
            try blob.withUnsafeBytes { raw in
                try check(sqlite3_bind_blob(stmt, i, raw.baseAddress, Int32(raw.count), SnapshotHistoryService.transient))
            }
        }

        /// Returns true when a row is available, false when done.
        func step() throws -> Bool {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SnapshotHistoryService.error(db, rc)
            }
        }

        func reset() throws {
            try check(sqlite3_reset(stmt))
            try check(sqlite3_clear_bindings(stmt))
        }

        func int(at i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(at i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(at i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func blob(at i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}
