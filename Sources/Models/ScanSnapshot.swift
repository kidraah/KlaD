// ScanSnapshot.swift — KlaDModels
//
// Compact, persistable summaries of a scan (directory/file aggregates above a
// size threshold) used by the SQLite history and the "Where did my space go?"
// diff view.

import Foundation

/// One persisted row: an item's aggregate at scan time.
public struct SnapshotEntry: Sendable, Hashable, Codable {
    /// Absolute path.
    public var path: String
    /// Depth below the scan root (root = 0).
    public var depth: Int
    public var isDirectory: Bool
    public var metrics: StorageMetrics

    public init(path: String, depth: Int, isDirectory: Bool, metrics: StorageMetrics) {
        self.path = path
        self.depth = depth
        self.isDirectory = isDirectory
        self.metrics = metrics
    }
}

/// Which items `ScanSnapshot.capture` records.
public struct SnapshotCapturePolicy: Sendable, Hashable, Codable {
    /// Items smaller than this (allocated) are not recorded. Default 16 MiB.
    public var minimumAllocatedBytes: UInt64
    /// Maximum depth below the root. Default 12.
    public var maxDepth: Int
    /// Hard cap on rows (breadth-first, so shallow items win). Default 25 000.
    public var maxEntries: Int

    public init(minimumAllocatedBytes: UInt64 = 16 << 20, maxDepth: Int = 12, maxEntries: Int = 25_000) {
        self.minimumAllocatedBytes = minimumAllocatedBytes
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
    }

    public static let `default` = SnapshotCapturePolicy()
}

public struct ScanSnapshot: Sendable, Identifiable, Hashable, Codable {
    public var id: UUID
    /// Absolute path of the scan root.
    public var rootPath: String
    public var startedAt: Date
    public var completedAt: Date
    /// Root aggregate.
    public var totals: StorageMetrics
    public var volume: VolumeSpaceReport?
    /// Breadth-first rows; `entries[0]` is the root.
    public var entries: [SnapshotEntry]

    public init(
        id: UUID = UUID(),
        rootPath: String,
        startedAt: Date,
        completedAt: Date,
        totals: StorageMetrics,
        volume: VolumeSpaceReport?,
        entries: [SnapshotEntry]
    ) {
        self.id = id
        self.rootPath = rootPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.totals = totals
        self.volume = volume
        self.entries = entries
    }

    public var summary: ScanSnapshotSummary {
        ScanSnapshotSummary(id: id, rootPath: rootPath, startedAt: startedAt, completedAt: completedAt,
                            totals: totals, entryCount: entries.count)
    }

    /// Captures a snapshot from an aggregated, size-sorted tree (breadth-first;
    /// children are size-sorted so each directory's scan stops at the first
    /// child below the threshold). Must run before publication or on the MainActor
    /// (see FileTreeNode threading contract).
    public static func capture(
        from root: FileTreeNode,
        id: UUID = UUID(),
        startedAt: Date,
        completedAt: Date,
        volume: VolumeSpaceReport?,
        policy: SnapshotCapturePolicy = .default
    ) -> ScanSnapshot {
        var entries: [SnapshotEntry] = []
        entries.reserveCapacity(min(policy.maxEntries, 4096))
        var queue: [(node: FileTreeNode, path: String, depth: Int)] = [(root, root.path, 0)]
        var head = 0
        while head < queue.count, entries.count < policy.maxEntries {
            let (node, nodePath, depth) = queue[head]
            head += 1
            entries.append(SnapshotEntry(path: nodePath, depth: depth, isDirectory: node.isDirectory, metrics: node.metrics))
            guard node.isDirectory, depth < policy.maxDepth else { continue }
            let prefix = nodePath.hasSuffix("/") ? nodePath : nodePath + "/"
            for child in node.children {
                if child.metrics.allocatedBytes < policy.minimumAllocatedBytes {
                    // Sorted descending: everything after is smaller too — unless the
                    // tree wasn't sorted, in which case keep checking.
                    if isSortedBySize(node) { break } else { continue }
                }
                if child.flags.contains(.hardLinkDuplicate) { continue }
                queue.append((child, prefix + child.name, depth + 1))
            }
        }
        return ScanSnapshot(id: id, rootPath: root.path, startedAt: startedAt, completedAt: completedAt,
                            totals: root.metrics, volume: volume, entries: entries)
    }

    private static func isSortedBySize(_ node: FileTreeNode) -> Bool {
        var previous = UInt64.max
        for child in node.children {
            if child.metrics.allocatedBytes > previous { return false }
            previous = child.metrics.allocatedBytes
        }
        return true
    }
}

/// Lightweight listing row for the history picker.
public struct ScanSnapshotSummary: Sendable, Identifiable, Hashable, Codable {
    public var id: UUID
    public var rootPath: String
    public var startedAt: Date
    public var completedAt: Date
    public var totals: StorageMetrics
    public var entryCount: Int

    public init(id: UUID, rootPath: String, startedAt: Date, completedAt: Date, totals: StorageMetrics, entryCount: Int) {
        self.id = id
        self.rootPath = rootPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.totals = totals
        self.entryCount = entryCount
    }
}

/// How an item changed between two snapshots.
public enum DeltaKind: String, Sendable, Codable, Hashable {
    case grew
    case shrank
    /// Present (above threshold) now, absent before.
    case appeared
    /// Present before, absent (or below threshold) now.
    case disappeared
    case unchanged
}

public struct DirectoryDelta: Sendable, Identifiable, Hashable, Codable {
    public var id: String { path }
    public var path: String
    public var depth: Int
    public var isDirectory: Bool
    /// nil when absent / below the capture threshold in the base snapshot.
    public var before: StorageMetrics?
    /// nil when absent / below the capture threshold in the current snapshot.
    public var after: StorageMetrics?
    public var kind: DeltaKind

    public init(path: String, depth: Int, isDirectory: Bool, before: StorageMetrics?, after: StorageMetrics?, kind: DeltaKind) {
        self.path = path
        self.depth = depth
        self.isDirectory = isDirectory
        self.before = before
        self.after = after
        self.kind = kind
    }

    /// Signed change in allocated bytes (missing side counts as 0).
    public var allocatedDelta: Int64 {
        Int64(bitPattern: after?.allocatedBytes ?? 0) - Int64(bitPattern: before?.allocatedBytes ?? 0)
    }

    public var logicalDelta: Int64 {
        Int64(bitPattern: after?.logicalBytes ?? 0) - Int64(bitPattern: before?.logicalBytes ?? 0)
    }

    public var privateDelta: Int64 {
        Int64(bitPattern: after?.privateBytes ?? 0) - Int64(bitPattern: before?.privateBytes ?? 0)
    }
}

public struct SnapshotDiff: Sendable, Hashable {
    public var base: ScanSnapshotSummary
    public var current: ScanSnapshotSummary
    /// Every path present in either snapshot whose allocated size changed,
    /// sorted by |allocatedDelta| descending.
    public var changes: [DirectoryDelta]
    /// The *explanatory* subset: deltas ≥ the significance threshold that are NOT
    /// mostly explained (≥ 80 %) by a single descendant's delta — i.e. the
    /// deepest directories where growth actually happened. Sorted by
    /// |allocatedDelta| descending.
    public var hotspots: [DirectoryDelta]

    public init(base: ScanSnapshotSummary, current: ScanSnapshotSummary, changes: [DirectoryDelta], hotspots: [DirectoryDelta]) {
        self.base = base
        self.current = current
        self.changes = changes
        self.hotspots = hotspots
    }

    /// Root-level change in allocated bytes.
    public var totalAllocatedDelta: Int64 {
        Int64(bitPattern: current.totals.allocatedBytes) - Int64(bitPattern: base.totals.allocatedBytes)
    }
}
