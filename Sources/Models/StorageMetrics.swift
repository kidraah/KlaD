// StorageMetrics.swift — KlaDModels
//
// The APFS storage model. On APFS a single "size" is misleading:
//
//   • logicalBytes   ATTR_FILE_TOTALSIZE  — the content length a file reports.
//   • allocatedBytes ATTR_FILE_ALLOCSIZE  — physical blocks allocated (0 for evicted
//                                            iCloud stubs, < logical for sparse files).
//   • privateBytes   ATTR_CMNEXT_PRIVATESIZE — bytes NOT trapped in an APFS clone or
//                                            snapshot: what deleting frees *immediately*.
//                                            Falls back to allocatedBytes when the volume
//                                            can't answer (flagged per node).
//   • cloudStubBytes logical bytes of SF_DATALESS placeholders (0 B on the SSD).
//
// sharedBytes = allocated − private: blocks pinned by clones, snapshots or hard links.

import Foundation

/// Per-node APFS accounting. For a file these are the file's own values; for a
/// directory they are the aggregate of all descendants (hard-link duplicates are
/// counted once, see `NodeFlags.hardLinkDuplicate`).
public struct StorageMetrics: Sendable, Hashable, Codable {
    /// Content length (ATTR_FILE_TOTALSIZE). Includes cloud placeholders.
    public var logicalBytes: UInt64
    /// Physical blocks allocated on disk (ATTR_FILE_ALLOCSIZE).
    public var allocatedBytes: UInt64
    /// Bytes freed immediately on deletion (ATTR_CMNEXT_PRIVATESIZE, else allocated).
    public var privateBytes: UInt64
    /// Logical bytes of SF_DATALESS (iCloud / File Provider) placeholders.
    public var cloudStubBytes: UInt64
    /// Number of non-directory items (a file node has `fileCount == 1`).
    public var fileCount: UInt32
    /// Number of descendant directories (excluding the node itself).
    public var directoryCount: UInt32

    public init(
        logicalBytes: UInt64 = 0,
        allocatedBytes: UInt64 = 0,
        privateBytes: UInt64 = 0,
        cloudStubBytes: UInt64 = 0,
        fileCount: UInt32 = 0,
        directoryCount: UInt32 = 0
    ) {
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.privateBytes = privateBytes
        self.cloudStubBytes = cloudStubBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
    }

    public static let zero = StorageMetrics()

    /// Allocated bytes that would NOT be freed immediately on deletion — trapped in
    /// APFS clones, local snapshots, or hard links held elsewhere.
    @inlinable public var sharedBytes: UInt64 {
        allocatedBytes > privateBytes ? allocatedBytes - privateBytes : 0
    }

    /// Files + directories.
    @inlinable public var itemCount: UInt64 { UInt64(fileCount) + UInt64(directoryCount) }

    /// True when nothing is stored (no bytes of any kind).
    @inlinable public var isEmpty: Bool {
        logicalBytes == 0 && allocatedBytes == 0 && privateBytes == 0 && cloudStubBytes == 0
    }

    /// Reads the metric selected by `measure`.
    @inlinable public func value(for measure: SizeMeasure) -> UInt64 {
        switch measure {
        case .allocated: return allocatedBytes
        case .reclaimable: return privateBytes
        case .logical: return logicalBytes
        }
    }

    @inlinable public mutating func add(_ other: StorageMetrics) {
        logicalBytes &+= other.logicalBytes
        allocatedBytes &+= other.allocatedBytes
        privateBytes &+= other.privateBytes
        cloudStubBytes &+= other.cloudStubBytes
        fileCount &+= other.fileCount
        directoryCount &+= other.directoryCount
    }

    /// Saturating subtraction (never underflows).
    @inlinable public mutating func subtract(_ other: StorageMetrics) {
        logicalBytes = logicalBytes > other.logicalBytes ? logicalBytes - other.logicalBytes : 0
        allocatedBytes = allocatedBytes > other.allocatedBytes ? allocatedBytes - other.allocatedBytes : 0
        privateBytes = privateBytes > other.privateBytes ? privateBytes - other.privateBytes : 0
        cloudStubBytes = cloudStubBytes > other.cloudStubBytes ? cloudStubBytes - other.cloudStubBytes : 0
        fileCount = fileCount > other.fileCount ? fileCount - other.fileCount : 0
        directoryCount = directoryCount > other.directoryCount ? directoryCount - other.directoryCount : 0
    }

    @inlinable public static func + (lhs: StorageMetrics, rhs: StorageMetrics) -> StorageMetrics {
        var result = lhs
        result.add(rhs)
        return result
    }

    @inlinable public static func += (lhs: inout StorageMetrics, rhs: StorageMetrics) {
        lhs.add(rhs)
    }
}

/// Which size a visualizer / table sizes things by.
public enum SizeMeasure: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    /// Physical blocks on disk (default — matches "what's using my SSD").
    case allocated
    /// Private bytes — what deleting would free immediately.
    case reclaimable
    /// Logical content length (what Finder's "size" shows; includes cloud stubs).
    case logical

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .allocated: return "Allocated"
        case .reclaimable: return "Reclaimable"
        case .logical: return "Logical"
        }
    }

    public var explanation: String {
        switch self {
        case .allocated: return "Physical APFS blocks on the SSD"
        case .reclaimable: return "Private bytes freed immediately if deleted (not shared with clones or snapshots)"
        case .logical: return "Reported content length, including iCloud placeholders"
        }
    }
}

// MARK: - Volume / container accounting

/// One APFS volume inside a container (from `diskutil apfs list -plist`).
public struct APFSVolumeUsage: Sendable, Hashable, Codable, Identifiable {
    public var id: String { deviceIdentifier }
    public var deviceIdentifier: String          // "disk3s1"
    public var name: String                      // "Macintosh HD - Data"
    public var roles: [String]                   // ["Data"], ["System"], ["VM"], …
    public var capacityInUse: UInt64             // bytes consumed by this volume
    public var mountPoint: String?

    public init(deviceIdentifier: String, name: String, roles: [String], capacityInUse: UInt64, mountPoint: String?) {
        self.deviceIdentifier = deviceIdentifier
        self.name = name
        self.roles = roles
        self.capacityInUse = capacityInUse
        self.mountPoint = mountPoint
    }
}

/// What the volume (and its APFS container) says about space. Explains the gap
/// between "purgeable System Data" and space that is free right now.
public struct VolumeSpaceReport: Sendable, Hashable, Codable {
    public var volumePath: String                 // path the report was taken for
    public var volumeName: String                 // "Macintosh HD"
    public var fileSystemType: String             // "apfs"
    public var deviceIdentifier: String?          // "disk3s1"
    /// volumeTotalCapacityKey — the container ceiling as seen by this volume.
    public var totalCapacity: UInt64
    /// volumeAvailableCapacityKey — free *right now* (statfs f_bavail).
    public var availableCapacity: UInt64
    /// volumeAvailableCapacityForImportantUsageKey — free + purgeable the OS will reclaim on demand.
    public var availableForImportantUsage: UInt64
    /// volumeAvailableCapacityForOpportunisticUsageKey.
    public var availableForOpportunisticUsage: UInt64
    /// APFS container (e.g. "disk3") if known.
    public var containerReference: String?
    /// Container capacity ceiling, bytes.
    public var containerCapacity: UInt64?
    /// Container "Capacity Not Allocated", bytes.
    public var containerFree: UInt64?
    /// Volumes sharing the container.
    public var containerVolumes: [APFSVolumeUsage]
    /// Local APFS / Time Machine snapshot names on this volume group.
    public var localSnapshotNames: [String]
    /// VOL_CAP_FMT_CLONE_MAPPING — full clone tracking (CLONEID / CLONE_REFCNT valid).
    public var supportsCloneMapping: Bool
    /// Whether ATTR_CMNEXT_PRIVATESIZE answered for a probe file on this volume.
    public var supportsPrivateSize: Bool
    public var isCaseSensitive: Bool
    public var isSealedSystemVolume: Bool
    public var capturedAt: Date

    public init(
        volumePath: String,
        volumeName: String,
        fileSystemType: String,
        deviceIdentifier: String?,
        totalCapacity: UInt64,
        availableCapacity: UInt64,
        availableForImportantUsage: UInt64,
        availableForOpportunisticUsage: UInt64,
        containerReference: String? = nil,
        containerCapacity: UInt64? = nil,
        containerFree: UInt64? = nil,
        containerVolumes: [APFSVolumeUsage] = [],
        localSnapshotNames: [String] = [],
        supportsCloneMapping: Bool = false,
        supportsPrivateSize: Bool = false,
        isCaseSensitive: Bool = false,
        isSealedSystemVolume: Bool = false,
        capturedAt: Date = Date()
    ) {
        self.volumePath = volumePath
        self.volumeName = volumeName
        self.fileSystemType = fileSystemType
        self.deviceIdentifier = deviceIdentifier
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.availableForOpportunisticUsage = availableForOpportunisticUsage
        self.containerReference = containerReference
        self.containerCapacity = containerCapacity
        self.containerFree = containerFree
        self.containerVolumes = containerVolumes
        self.localSnapshotNames = localSnapshotNames
        self.supportsCloneMapping = supportsCloneMapping
        self.supportsPrivateSize = supportsPrivateSize
        self.isCaseSensitive = isCaseSensitive
        self.isSealedSystemVolume = isSealedSystemVolume
        self.capturedAt = capturedAt
    }

    /// Space in use (total − immediately available).
    public var usedCapacity: UInt64 {
        totalCapacity > availableCapacity ? totalCapacity - availableCapacity : 0
    }

    /// Purgeable space macOS will reclaim on demand (caches, evictable iCloud
    /// content, expiring snapshots) — counted as "used" by `df`.
    public var purgeableCapacity: UInt64 {
        availableForImportantUsage > availableCapacity ? availableForImportantUsage - availableCapacity : 0
    }

    /// Used space that is *not* purgeable.
    public var nonPurgeableUsedCapacity: UInt64 {
        usedCapacity > purgeableCapacity ? usedCapacity - purgeableCapacity : 0
    }
}
