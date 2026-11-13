// ServiceProtocols.swift — KlaDModels
//
// Strict interfaces between the scanner, the services
// and the UI. Implementations live in:
//
//   KlaDScanner       BulkAPFSScanner        : StorageScanning
//                      APFSVolumeInspector    : VolumeInspecting
//   KlaDIntelligence  DeveloperRulesCatalog  : DeveloperRulesCataloging
//                      ClassificationEngine   : StorageClassifying
//                      GitRepoInspector       : GitRepositoryInspecting
//   KlaDStorageOps    SnapshotHistoryService : SnapshotHistoryStoring
//                      DuplicateDetectorService : DuplicateDetecting
//                      SafeCleanupService     : SafeCleanupPerforming
//                      FSEventsMonitor        : FileSystemWatching
//
// GLOBAL INVARIANTS every implementation must honor:
//   1. NEVER open(), read, hash or extended-attribute-read a file whose
//      SF_DATALESS flag is set (NodeFlags.cloudPlaceholder) — that forces
//      fileproviderd/bird to download it from iCloud.
//   2. NEVER delete with FileManager.removeItem / unlink / rm. The only
//      deletion primitive is FileManager.default.trashItem(at:resultingItemURL:).
//   3. Never trash anything whose safety is guidedExternalAction, doNotDelete
//      or unknown.
//   4. Subprocesses (git, lsof, tmutil, diskutil…) always run with a hard
//      timeout and never block the MainActor.

import Foundation

// MARK: - Scanning (KlaDScanner)

public struct ScanOptions: Sendable, Hashable {
    /// Absolute path to scan.
    public var rootPath: String
    /// Descend into other mounted file systems (default false).
    public var crossMountPoints: Bool
    /// Absolute paths never descended (recorded as `.excluded`).
    public var excludedPaths: Set<String>
    /// Ask APFS for ATTR_CMNEXT_PRIVATESIZE (default true).
    public var requestPrivateSize: Bool
    /// Worker threads; 0 = automatic.
    public var concurrency: Int
    /// Gentle mode: utility QoS + throttled disk I/O (background rescans).
    public var lowPriority: Bool

    public init(
        rootPath: String,
        crossMountPoints: Bool = false,
        excludedPaths: Set<String> = [],
        requestPrivateSize: Bool = true,
        concurrency: Int = 0,
        lowPriority: Bool = false
    ) {
        self.rootPath = rootPath
        self.crossMountPoints = crossMountPoints
        self.excludedPaths = excludedPaths
        self.requestPrivateSize = requestPrivateSize
        self.concurrency = concurrency
        self.lowPriority = lowPriority
    }
}

public struct ScanProgress: Sendable, Hashable {
    public var filesScanned: UInt64
    public var directoriesScanned: UInt64
    public var allocatedBytes: UInt64
    public var logicalBytes: UInt64
    public var cloudStubBytes: UInt64
    public var unreadableCount: UInt64
    /// A recently scanned directory (for display).
    public var currentPath: String
    public var elapsed: TimeInterval

    public init(
        filesScanned: UInt64 = 0,
        directoriesScanned: UInt64 = 0,
        allocatedBytes: UInt64 = 0,
        logicalBytes: UInt64 = 0,
        cloudStubBytes: UInt64 = 0,
        unreadableCount: UInt64 = 0,
        currentPath: String = "",
        elapsed: TimeInterval = 0
    ) {
        self.filesScanned = filesScanned
        self.directoriesScanned = directoriesScanned
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.cloudStubBytes = cloudStubBytes
        self.unreadableCount = unreadableCount
        self.currentPath = currentPath
        self.elapsed = elapsed
    }

    public var itemsPerSecond: Double {
        elapsed > 0 ? Double(filesScanned + directoriesScanned) / elapsed : 0
    }
}

/// A directory the scanner could not read.
public struct ScanIssue: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var errorCode: Int32
    public var message: String

    public init(path: String, errorCode: Int32, message: String) {
        self.path = path
        self.errorCode = errorCode
        self.message = message
    }

    /// EPERM / EACCES — usually means Full Disk Access is missing.
    public var isPermissionDenied: Bool { errorCode == EPERM || errorCode == EACCES }
}

public struct ScanResult: Sendable {
    /// Aggregated, size-sorted tree. Categories are `.other` until classified.
    public let root: FileTreeNode
    public let options: ScanOptions
    public let startedAt: Date
    public let completedAt: Date
    /// First N unreadable directories.
    public let issues: [ScanIssue]
    public let unreadableCount: Int
    /// Whether ATTR_CMNEXT_PRIVATESIZE was honored by the volume.
    public let privateSizeSupported: Bool
    /// Hard-linked inodes seen more than once (counted once).
    public let hardLinkDuplicateCount: Int
    public let wasCancelled: Bool

    public init(
        root: FileTreeNode,
        options: ScanOptions,
        startedAt: Date,
        completedAt: Date,
        issues: [ScanIssue],
        unreadableCount: Int,
        privateSizeSupported: Bool,
        hardLinkDuplicateCount: Int,
        wasCancelled: Bool
    ) {
        self.root = root
        self.options = options
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.issues = issues
        self.unreadableCount = unreadableCount
        self.privateSizeSupported = privateSizeSupported
        self.hardLinkDuplicateCount = hardLinkDuplicateCount
        self.wasCancelled = wasCancelled
    }

    public var duration: TimeInterval { completedAt.timeIntervalSince(startedAt) }
}

public protocol StorageScanning: Sendable {
    /// Full scan. Honors Swift task cancellation (returns a partial tree with
    /// `wasCancelled == true`). `progress` is called at most ~10×/s from a
    /// background thread.
    func scan(_ options: ScanOptions, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult

    /// Rescans one directory subtree and returns a detached, aggregated node
    /// whose `name` is the directory's last path component (ready for
    /// `FileTreeNode.replace(with:)`).
    func rescanSubtree(atPath path: String, options: ScanOptions) async throws -> FileTreeNode
}

public protocol VolumeInspecting: Sendable {
    /// Volume + APFS container space report for the volume containing `path`.
    func report(forPath path: String) async -> VolumeSpaceReport?
}

// MARK: - Intelligence (KlaDIntelligence)

public struct ClassificationContext: Sendable, Hashable {
    /// The user's home directory ("/Users/me"), no trailing slash.
    public var homeDirectory: String
    /// "Now" for age computations (injectable for tests).
    public var now: Date
    /// Bundle identifiers of running applications (e.g. "com.apple.dt.Xcode").
    public var runningApplicationBundleIDs: Set<String>
    /// Days without modification before `.inactive(days:)` is attached. Default 30.
    public var inactivityThresholdDays: Int
    /// Installers in ~/Downloads older than this are recommended. Default 30.
    public var staleInstallerDays: Int
    /// Items smaller than this (allocated) are not recommended. Default 1 MiB.
    public var minimumRecommendationBytes: UInt64

    public init(
        homeDirectory: String,
        now: Date = Date(),
        runningApplicationBundleIDs: Set<String> = [],
        inactivityThresholdDays: Int = 30,
        staleInstallerDays: Int = 30,
        minimumRecommendationBytes: UInt64 = 1 << 20
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
        self.runningApplicationBundleIDs = runningApplicationBundleIDs
        self.inactivityThresholdDays = inactivityThresholdDays
        self.staleInstallerDays = staleInstallerDays
        self.minimumRecommendationBytes = minimumRecommendationBytes
    }
}

/// The result of evaluating the rules catalog against one node.
public struct RuleMatch: Sendable, Hashable {
    /// Stable id, dotted: "node.node_modules", "rust.target", "docker.raw".
    public var ruleID: String
    /// "node_modules (npm dependencies)".
    public var title: String
    public var category: StorageCategory
    public var safety: SafetyLevel
    public var group: RecommendationGroup
    public var rationale: String
    public var evidence: [Evidence]
    public var action: CleanupAction
    public var regenerateCommand: String?
    public var warnings: [String]
    /// Signals the rule itself knows (e.g. `.missingLockfile`).
    public var signals: [SupportingSignal]
    /// Emit a `CleanupRecommendation` (false = annotate/categorize only, e.g.
    /// protected system areas).
    public var recommend: Bool
    /// Keep evaluating rules inside this node (false for cleanup targets, so a
    /// node_modules nested inside a node_modules is never recommended twice).
    public var descend: Bool

    public init(
        ruleID: String,
        title: String,
        category: StorageCategory,
        safety: SafetyLevel,
        group: RecommendationGroup,
        rationale: String,
        evidence: [Evidence] = [],
        action: CleanupAction,
        regenerateCommand: String? = nil,
        warnings: [String] = [],
        signals: [SupportingSignal] = [],
        recommend: Bool = true,
        descend: Bool = false
    ) {
        self.ruleID = ruleID
        self.title = title
        self.category = category
        self.safety = safety
        self.group = group
        self.rationale = rationale
        self.evidence = evidence
        self.action = action
        self.regenerateCommand = regenerateCommand
        self.warnings = warnings
        self.signals = signals
        self.recommend = recommend
        self.descend = descend
    }
}

public protocol DeveloperRulesCataloging: Sendable {
    /// Evaluates every rule against `node` (located at absolute `path`).
    /// PURE: consults only the in-memory tree (the node, its children, its
    /// siblings via `node.parent`) and `context` — never the disk.
    func match(node: FileTreeNode, path: String, context: ClassificationContext) -> RuleMatch?

    /// Extension/name-based category for a file ("mov" → .media, "gguf" → .aiModels).
    func categoryHint(forFileNamed name: String) -> StorageCategory?
}

public struct ClassificationResult: Sendable {
    /// Sorted by `reclaimableBytes` descending.
    public var recommendations: [CleanupRecommendation]
    /// Σ of leaf (non-directory) contributions per category — no double counting.
    public var categoryTotals: [StorageCategory: StorageMetrics]
    /// Nodes that received a `NodeAnnotation`.
    public var annotatedNodeCount: Int

    public init(recommendations: [CleanupRecommendation], categoryTotals: [StorageCategory: StorageMetrics], annotatedNodeCount: Int) {
        self.recommendations = recommendations
        self.categoryTotals = categoryTotals
        self.annotatedNodeCount = annotatedNodeCount
    }
}

public protocol StorageClassifying: Sendable {
    /// Annotates `root` IN PLACE and returns recommendations:
    ///   • sets `category` on EVERY node (rule category > inherited ancestor rule
    ///     category > file-name hint > for directories, the dominant category of
    ///     their children by allocated bytes > `.other`);
    ///   • sets `annotation` on rule-matched nodes;
    ///   • emits one recommendation per matched node with `recommend == true`
    ///     and allocated ≥ `context.minimumRecommendationBytes`; adds `.inactive`
    ///     / `.recentlyModified` age signals and `.hardLinkedContent` /
    ///     `.cloneSharedContent` signals derived from the tree.
    /// Runs on a background task BEFORE the tree is published. Must be O(n).
    func classify(root: FileTreeNode, context: ClassificationContext) -> ClassificationResult
}

public struct GitRepositoryStatus: Sendable, Hashable {
    /// Absolute path of the working tree root.
    public var repositoryRoot: String
    /// Branch name, nil when detached / unknown.
    public var branch: String?
    /// `git status --porcelain` reported nothing.
    public var isClean: Bool
    /// Modified / staged tracked entries.
    public var changedCount: Int
    /// Untracked (non-ignored) entries.
    public var untrackedCount: Int
    public var lastCommitDate: Date?

    public init(repositoryRoot: String, branch: String?, isClean: Bool, changedCount: Int, untrackedCount: Int, lastCommitDate: Date?) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.isClean = isClean
        self.changedCount = changedCount
        self.untrackedCount = untrackedCount
        self.lastCommitDate = lastCommitDate
    }
}

public protocol GitRepositoryInspecting: Sendable {
    /// Status of the repository enclosing `path` (walks up for `.git`), or nil
    /// when not in a repo, git is unavailable, or the 3 s timeout hits. Cached
    /// per repository root.
    func status(forPath path: String) async -> GitRepositoryStatus?

    /// Badges for a recommendation at `path`: `.gitClean` /
    /// `.gitUncommittedChanges`, `.gitLastCommit`, or `.notGitRepository`.
    func supportingSignals(forPath path: String, now: Date) async -> [SupportingSignal]
}

// MARK: - Storage operations (KlaDStorageOps)

public protocol SnapshotHistoryStoring: Sendable {
    /// Persists a snapshot (replacing one with the same id).
    func save(_ snapshot: ScanSnapshot) async throws
    /// Summaries, newest first; filtered to `rootPath` when non-nil.
    func summaries(rootPath: String?) async throws -> [ScanSnapshotSummary]
    func load(id: UUID) async throws -> ScanSnapshot?
    /// Diff of two stored snapshots. `significanceBytes` is the hotspot threshold.
    func diff(baseID: UUID, currentID: UUID, significanceBytes: UInt64) async throws -> SnapshotDiff
    func delete(id: UUID) async throws
    /// Keeps the newest `count` snapshots per root path; deletes the rest.
    func prune(keepingLatest count: Int) async throws
}

/// A value-type copy of a file node, gathered from the tree on the caller's
/// side so the detector never touches the live tree.
public struct DuplicateCandidate: Sendable, Hashable {
    public var path: String
    public var logicalBytes: UInt64
    public var allocatedBytes: UInt64
    public var privateBytes: UInt64
    public var flags: NodeFlags
    public var fileID: UInt64
    public var deviceID: Int32
    public var cloneID: UInt64
    public var modificationTime: Int64

    public init(path: String, logicalBytes: UInt64, allocatedBytes: UInt64, privateBytes: UInt64, flags: NodeFlags,
                fileID: UInt64, deviceID: Int32, cloneID: UInt64, modificationTime: Int64) {
        self.path = path
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.privateBytes = privateBytes
        self.flags = flags
        self.fileID = fileID
        self.deviceID = deviceID
        self.cloneID = cloneID
        self.modificationTime = modificationTime
    }

    /// Collects regular files ≥ `minimumBytes` that are eligible for hashing:
    /// excludes cloud placeholders, zero-allocation files, hard-link duplicates,
    /// symlinks and anything inside a package bundle.
    public static func collect(from root: FileTreeNode, minimumBytes: UInt64, home: String = NSHomeDirectory()) -> [DuplicateCandidate] {
        var result: [DuplicateCandidate] = []
        root.walkWithPaths { node, nodePath in
            if node.kind == .directory {
                // Children are size-sorted; still must descend (sizes are aggregates).
                if node.metrics.allocatedBytes < minimumBytes { return .skipChildren }
                if node.flags.contains(.package) || node.isProtectedLocation || node.isOpaque { return .skipChildren }
                return .continue
            }
            guard node.kind == .file,
                  SystemPolicy.mayModify(nodePath, home: home),
                  node.metrics.logicalBytes >= minimumBytes,
                  node.metrics.allocatedBytes > 0,
                  !node.flags.contains(.cloudPlaceholder),
                  !node.flags.contains(.hardLinkDuplicate)
            else { return .continue }
            result.append(DuplicateCandidate(
                path: nodePath,
                logicalBytes: node.metrics.logicalBytes,
                allocatedBytes: node.metrics.allocatedBytes,
                privateBytes: node.metrics.privateBytes,
                flags: node.flags,
                fileID: node.fileID,
                deviceID: node.deviceID,
                cloneID: node.cloneID,
                modificationTime: node.modificationTime
            ))
            return .continue
        }
        return result
    }
}

public struct DuplicateScanOptions: Sendable, Hashable {
    /// Files smaller than this are ignored. Default 1 MiB.
    public var minimumBytes: UInt64
    /// Stop after hashing this many bytes in total (safety valve). Default 64 GiB.
    public var maxBytesToHash: UInt64

    public init(minimumBytes: UInt64 = 1 << 20, maxBytesToHash: UInt64 = 64 << 30) {
        self.minimumBytes = minimumBytes
        self.maxBytesToHash = maxBytesToHash
    }
}

public struct DuplicateScanProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable { case groupingBySize, edgeHashing, fullHashing, finished }
    public var phase: Phase
    public var filesProcessed: Int
    public var filesTotal: Int
    public var bytesHashed: UInt64

    public init(phase: Phase, filesProcessed: Int, filesTotal: Int, bytesHashed: UInt64) {
        self.phase = phase
        self.filesProcessed = filesProcessed
        self.filesTotal = filesTotal
        self.bytesHashed = bytesHashed
    }
}

public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    /// Hex SHA-256 of the content.
    public var id: String { contentHash }
    public var contentHash: String
    /// Logical size of each copy.
    public var fileSize: UInt64
    /// Absolute paths, ≥ 2, sorted (oldest modification first when known).
    public var paths: [String]
    /// Σ privateBytes of all copies except the one kept (the first path).
    public var reclaimableBytes: UInt64

    public init(contentHash: String, fileSize: UInt64, paths: [String], reclaimableBytes: UInt64) {
        self.contentHash = contentHash
        self.fileSize = fileSize
        self.paths = paths
        self.reclaimableBytes = reclaimableBytes
    }
}

public protocol DuplicateDetecting: Sendable {
    /// size → 4 KiB head+tail edge hash → full SHA-256 (CryptoKit, streamed).
    /// Skips `.cloudPlaceholder` and allocated == 0, re-checks SF_DATALESS via
    /// lstat immediately before opening, opens with O_NOFOLLOW, and treats files
    /// sharing a non-zero `cloneID` as ONE copy (APFS clones already share
    /// blocks — deleting one frees nothing). Honors task cancellation.
    func findDuplicates(
        among candidates: [DuplicateCandidate],
        options: DuplicateScanOptions,
        progress: (@Sendable (DuplicateScanProgress) -> Void)?
    ) async throws -> [DuplicateGroup]
}

/// What the UI asks the cleanup service to trash.
public struct CleanupTarget: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var displayName: String
    public var safety: SafetyLevel
    /// Identity at scan time — re-verified (fileID + deviceID; mtime drift → warning).
    public var identity: NodeIdentity
    /// Size snapshot at scan time.
    public var metrics: StorageMetrics
    /// Apps that must not be running (e.g. ["com.apple.dt.Xcode"] for DerivedData).
    public var conflictingApplicationBundleIDs: [String]
    public var isDirectory: Bool

    public init(path: String, displayName: String, safety: SafetyLevel, identity: NodeIdentity, metrics: StorageMetrics,
                conflictingApplicationBundleIDs: [String] = [], isDirectory: Bool) {
        self.path = path
        self.displayName = displayName
        self.safety = safety
        self.identity = identity
        self.metrics = metrics
        self.conflictingApplicationBundleIDs = conflictingApplicationBundleIDs
        self.isDirectory = isDirectory
    }
}

public enum PreflightStatus: String, Sendable, Hashable, Codable {
    case passed
    case warning
    case failed
    case skipped
}

public struct PreflightCheck: Sendable, Hashable, Identifiable {
    /// Stable id: "exists", "identity", "safety", "systemPolicy", "ownership",
    /// "runningApps", "openFiles", "cloudSynced", "largeDelete".
    public var id: String
    public var title: String
    public var status: PreflightStatus
    public var detail: String
    /// A `.warning` the user must explicitly tick before the Trash button enables
    /// (iCloud-synced items, very large deletes).
    public var requiresAcknowledgement: Bool

    public init(id: String, title: String, status: PreflightStatus, detail: String, requiresAcknowledgement: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.requiresAcknowledgement = requiresAcknowledgement
    }
}

public struct ProcessUsage: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    /// One example open path inside the target.
    public var examplePath: String?

    public init(pid: Int32, name: String, examplePath: String?) {
        self.pid = pid
        self.name = name
        self.examplePath = examplePath
    }
}

public struct PreflightReport: Sendable, Hashable {
    public var target: CleanupTarget
    public var checks: [PreflightCheck]
    public var processesUsingTarget: [ProcessUsage]
    public var checkedAt: Date

    public init(target: CleanupTarget, checks: [PreflightCheck], processesUsingTarget: [ProcessUsage], checkedAt: Date) {
        self.target = target
        self.checks = checks
        self.processesUsingTarget = processesUsingTarget
        self.checkedAt = checkedAt
    }

    /// No check failed.
    public var canProceed: Bool { !checks.contains { $0.status == .failed } }
    /// Warnings the user must tick before proceeding.
    public var acknowledgementsRequired: [PreflightCheck] {
        checks.filter { $0.requiresAcknowledgement && $0.status == .warning }
    }
    public var hasWarnings: Bool { checks.contains { $0.status == .warning } }
}

public struct CleanupOutcome: Sendable, Hashable {
    public var target: CleanupTarget
    public var succeeded: Bool
    /// Where the item landed in the Trash.
    public var trashedPath: String?
    /// Immediately reclaimable once the Trash is emptied (target.metrics.privateBytes).
    public var reclaimedPrivateBytes: UInt64
    /// Physical allocation moved to the Trash (target.metrics.allocatedBytes).
    public var movedAllocatedBytes: UInt64
    public var errorMessage: String?

    public init(target: CleanupTarget, succeeded: Bool, trashedPath: String?, reclaimedPrivateBytes: UInt64,
                movedAllocatedBytes: UInt64, errorMessage: String?) {
        self.target = target
        self.succeeded = succeeded
        self.trashedPath = trashedPath
        self.reclaimedPrivateBytes = reclaimedPrivateBytes
        self.movedAllocatedBytes = movedAllocatedBytes
        self.errorMessage = errorMessage
    }
}

public protocol SafeCleanupPerforming: Sendable {
    /// Checks, in order: path still exists (lstat, no follow); identity matches
    /// (fileID + deviceID, else FAILED; mtime drift ⇒ warning); safety permits
    /// trash (else FAILED); conflicting apps not running (warning); no process
    /// holds open files inside the target (libproc scan, ≤ 500 ms budget ⇒
    /// warning, or "skipped" on timeout); target is not a mount point / volume
    /// root / home directory / "/" (FAILED).
    func preflight(_ target: CleanupTarget) async -> PreflightReport

    /// Moves to Trash with `FileManager.default.trashItem` ONLY IF
    /// `report.canProceed` and the report is for this exact target, re-checking
    /// identity immediately before the move. Never calls removeItem.
    func moveToTrash(_ target: CleanupTarget, report: PreflightReport) async -> CleanupOutcome
}

/// A directory the file system says changed.
public struct DirtyPath: Sendable, Hashable {
    /// Absolute directory path.
    public var path: String
    /// True when the whole subtree must be rescanned
    /// (kFSEventStreamEventFlagMustScanSubDirs, dropped events, root changed).
    public var recursive: Bool

    public init(path: String, recursive: Bool) {
        self.path = path
        self.recursive = recursive
    }
}

public struct DirtyPathBatch: Sendable, Hashable {
    /// Minimal cover: no path is inside another *recursive* path of the batch.
    public var paths: [DirtyPath]
    /// Raw FSEvents coalesced into this batch.
    public var eventCount: Int
    public var receivedAt: Date
    /// True when this batch contains kFSEventStreamEventFlagHistoryDone — every
    /// historical event since `sinceEventID` has been delivered.
    public var historyDone: Bool
    /// Highest FSEvents event id in this batch (persist it to resume later).
    public var lastEventID: UInt64

    public init(paths: [DirtyPath], eventCount: Int, receivedAt: Date, historyDone: Bool = false, lastEventID: UInt64 = 0) {
        self.paths = paths
        self.eventCount = eventCount
        self.receivedAt = receivedAt
        self.historyDone = historyDone
        self.lastEventID = lastEventID
    }
}

public protocol FileSystemWatching: AnyObject, Sendable {
    /// Starts an FSEventStream on `paths` (directory-level events, no
    /// kFSEventStreamCreateFlagFileEvents) and yields coalesced batches.
    /// `sinceEventID` replays history from a persisted event id (nil = now);
    /// the batch carrying HistoryDone has `historyDone == true` (an empty
    /// batch is yielded if history held no events). Calling `start` again
    /// restarts with the new paths.
    func start(paths: [String], latency: TimeInterval, sinceEventID: UInt64?) throws -> AsyncStream<DirtyPathBatch>
    /// FSEventsGetCurrentEventId() — persist with a scan to replay later.
    var currentEventID: UInt64 { get }
    /// Stops the stream and finishes the AsyncStream. Idempotent.
    func stop()
    var isRunning: Bool { get }
}

// MARK: - History series (KlaDStorageOps)

/// One point of a folder's size history.
public struct SizeSample: Sendable, Hashable {
    public var date: Date
    public var metrics: StorageMetrics

    public init(date: Date, metrics: StorageMetrics) {
        self.date = date
        self.metrics = metrics
    }
}

/// One point of a volume's used-space history.
public struct UsageSample: Sendable, Hashable {
    public var date: Date
    /// Volume used capacity (total − available now).
    public var usedBytes: UInt64
    public var totalBytes: UInt64

    public init(date: Date, usedBytes: UInt64, totalBytes: UInt64) {
        self.date = date
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }
}

public protocol SnapshotSeriesProviding: Sendable {
    /// The size of `path` in every stored snapshot that recorded it, oldest first.
    func sizeSeries(path: String) async throws -> [SizeSample]
    /// Volume usage from every stored snapshot's volume report (any root),
    /// oldest first, one sample per snapshot, deduplicated by timestamp.
    func usageSeries() async throws -> [UsageSample]
}

// MARK: - Fill forecast (KlaDStorageOps)

public enum ForecastOutcome: Sendable, Hashable {
    /// Not enough history (need ≥ 7 days spanning ≥ 4 distinct days).
    case insufficientData(daysCovered: Int, distinctDays: Int)
    /// Flat or shrinking.
    case notFillingUp(bytesPerDay: Int64)
    /// Would be full in lowDays…highDays at the current pace.
    case fillsIn(lowDays: Int, highDays: Int, bytesPerDay: Int64)
    /// Growing, but the low estimate is beyond two years.
    case moreThanTwoYears(bytesPerDay: Int64)
}

public protocol StorageForecasting: Sendable {
    /// Honest forecast: last sample per day over up to 60 days, sudden one-day
    /// jumps (> 3× the median absolute daily change and > 5 GB) excluded,
    /// Theil–Sen slope (median of pairwise slopes) with the range from the
    /// slopes' quartiles. Never an exact date.
    func forecast(samples: [UsageSample], now: Date) -> ForecastOutcome
}

// MARK: - Instant reopen (KlaDStorageOps)

public struct ScanCacheMeta: Sendable, Hashable, Codable {
    public var rootPath: String
    public var scannedAt: Date
    /// FSEvents id at scan completion — replayed on reopen to find changes.
    public var fsEventsID: UInt64
    public var privateSizeSupported: Bool
    public var unreadableCount: Int
    public var nodeCount: Int

    public init(rootPath: String, scannedAt: Date, fsEventsID: UInt64, privateSizeSupported: Bool, unreadableCount: Int, nodeCount: Int) {
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.fsEventsID = fsEventsID
        self.privateSizeSupported = privateSizeSupported
        self.unreadableCount = unreadableCount
        self.nodeCount = nodeCount
    }
}

public protocol ScanCaching: Sendable {
    /// Persists the tree's structure, identities, flags, mtimes and FILE metrics
    /// (directories are re-aggregated on load). Categories / annotations are not
    /// stored (re-classified after load). Must only READ the tree.
    func save(_ root: FileTreeNode, meta: ScanCacheMeta) async throws
    /// Loads and re-aggregates a cached tree; nil if none. Throws on corruption
    /// (strict, bounds-checked decoding — never trusts lengths or counts).
    func load(rootPath: String) async throws -> (root: FileTreeNode, meta: ScanCacheMeta)?
    /// Metadata of every cached root, newest first.
    func cachedScans() async -> [ScanCacheMeta]
    func remove(rootPath: String) async throws
}

// MARK: - Insights (KlaDIntelligence)

public struct LargeFileEntry: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var metrics: StorageMetrics
    public var category: StorageCategory
    public var modificationTime: Int64
    public var flags: NodeFlags

    public init(path: String, metrics: StorageMetrics, category: StorageCategory, modificationTime: Int64, flags: NodeFlags) {
        self.path = path
        self.metrics = metrics
        self.category = category
        self.modificationTime = modificationTime
        self.flags = flags
    }
}

public struct FileTypeSummary: Sendable, Identifiable, Hashable {
    public var id: String { key }
    /// Lowercased extension ("mov"), or "" for files without one.
    public var key: String
    public var fileCount: Int
    public var metrics: StorageMetrics
    public var category: StorageCategory
    /// Path of the largest file of this type.
    public var largestPath: String

    public init(key: String, fileCount: Int, metrics: StorageMetrics, category: StorageCategory, largestPath: String) {
        self.key = key
        self.fileCount = fileCount
        self.metrics = metrics
        self.category = category
        self.largestPath = largestPath
    }
}

public protocol InventoryReporting: Sendable {
    /// The `limit` largest regular files by `measure` (bounded heap, O(n log k)).
    /// Skips opaque nodes and hard-link duplicates.
    func largestFiles(in root: FileTreeNode, limit: Int, measure: SizeMeasure) -> [LargeFileEntry]
    /// Per-extension totals, largest first.
    func fileTypes(in root: FileTreeNode, limit: Int) -> [FileTypeSummary]
}

public struct SimilarFolder: Sendable, Hashable {
    public var path: String
    public var metrics: StorageMetrics
    public var newestModificationTime: Int64

    public init(path: String, metrics: StorageMetrics, newestModificationTime: Int64) {
        self.path = path
        self.metrics = metrics
        self.newestModificationTime = newestModificationTime
    }
}

public struct SimilarFolderGroup: Sendable, Identifiable, Hashable {
    public enum MatchKind: String, Sendable, Hashable {
        /// Same children (names and sizes) — almost certainly copies.
        case identicalContents
        /// Name variants ("app", "app copy", "app_v2", "New folder (3)") with very similar contents.
        case nameVariants
    }

    public var id: String
    /// Shared base name ("kd").
    public var title: String
    public var kind: MatchKind
    /// 0…1 structural similarity.
    public var similarity: Double
    /// Folders, the one most likely to be "the original" first.
    public var folders: [SimilarFolder]
    /// Σ private bytes of all folders except the first.
    public var reclaimableBytes: UInt64

    public init(id: String, title: String, kind: MatchKind, similarity: Double, folders: [SimilarFolder], reclaimableBytes: UInt64) {
        self.id = id
        self.title = title
        self.kind = kind
        self.similarity = similarity
        self.folders = folders
        self.reclaimableBytes = reclaimableBytes
    }
}

public protocol SimilarFolderDetecting: Sendable {
    /// Groups of near-duplicate folders ≥ `minimumBytes`, largest reclaimable
    /// first. Never descends into rule-matched cleanup targets, packages,
    /// protected or opaque nodes; never reports a folder and its own ancestor.
    func findSimilarFolders(in root: FileTreeNode, minimumBytes: UInt64) -> [SimilarFolderGroup]
}

/// Installed applications, captured on the MainActor (LaunchServices).
public struct InstalledApps: Sendable, Hashable {
    /// Lowercased bundle identifiers.
    public var bundleIDs: Set<String>
    /// Lowercased app names without ".app".
    public var names: Set<String>

    public init(bundleIDs: Set<String>, names: Set<String>) {
        self.bundleIDs = bundleIDs
        self.names = names
    }
}

public protocol LeftoverDetecting: Sendable {
    /// Hints for app data whose app is gone: direct children of ~/Library/Caches,
    /// Application Support, Logs, HTTPStorages, WebKit, Saved Application State
    /// whose bundle id / name matches no installed app, unchanged for 90+ days,
    /// ≥ minimum size. Group `.appLeftovers`, safety `.reviewFirst`, action
    /// `.moveToTrash`. Never Apple's (com.apple.*), never protected locations.
    func findLeftovers(in root: FileTreeNode, context: ClassificationContext, installed: InstalledApps) -> [CleanupRecommendation]
}
