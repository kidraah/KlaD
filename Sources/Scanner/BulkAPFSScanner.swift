// BulkAPFSScanner.swift — KlaDScanner
//
// Concurrent getattrlistbulk(2) traversal.
//
//   • N dedicated POSIX threads (not the Swift cooperative pool — these block
//     in the kernel) share a LIFO work stack guarded by an NSCondition. LIFO
//     keeps the frontier depth-first, so memory stays proportional to tree
//     depth × fan-out instead of the whole breadth.
//   • Each thread owns a 256 KiB result buffer and parses entries in place
//     (BSDAttributeLayout.swift); one syscall returns hundreds of entries with
//     name, type, device, inode, flags, mtime, sizes, PRIVATESIZE, clone id
//     and EF_* flags — no per-file stat().
//   • Each directory node's children are assigned by exactly one thread
//     (FileTreeNode single-writer contract).
//   • Every scanner thread engages IOPOL_MATERIALIZE_DATALESS_FILES_OFF, so
//     even a bug can't make the scanner download iCloud content.
//   • Whole-disk scans ("/") run in two phases (see FirmlinkAndMountGuard).
//   • Aggregation runs in parallel per top-level subtree.

import Darwin
import Foundation
import os
import KlaDModels

public enum ScannerError: Error, LocalizedError, Sendable {
    case rootNotFound(path: String, errorCode: Int32)
    case rootNotDirectory(path: String)

    public var errorDescription: String? {
        switch self {
        case .rootNotFound(let path, let code):
            return "Cannot open \(path): \(String(cString: strerror(code)))"
        case .rootNotDirectory(let path):
            return "\(path) is not a folder"
        }
    }
}

public final class BulkAPFSScanner: StorageScanning {
    public init() {}

    public func scan(_ options: ScanOptions, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        let session = try ScanSession(options: options, rootName: nil, progress: progress)
        return try await Self.runOffCooperativePool(session)
    }

    public func rescanSubtree(atPath path: String, options: ScanOptions) async throws -> FileTreeNode {
        var subOptions = options
        subOptions.rootPath = path
        let resolved = ScanSession.resolve(path)
        let session = try ScanSession(
            options: subOptions,
            rootName: (resolved as NSString).lastPathComponent,
            progress: nil
        )
        return try await Self.runOffCooperativePool(session).root
    }

    /// Runs the blocking session on a dedicated thread; propagates cancellation.
    private static func runOffCooperativePool(_ session: ScanSession) async throws -> ScanResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ScanResult, Error>) in
                let thread = Thread {
                    continuation.resume(returning: session.run())
                }
                thread.name = "klad.scan.coordinator"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            session.cancel()
        }
    }
}

// MARK: - Work queue

final class DirectoryWorkQueue: @unchecked Sendable {
    struct Job {
        let node: FileTreeNode
        let path: String
    }

    private let condition = NSCondition()
    private var stack: [Job] = []
    private var active = 0
    private var cancelled = false

    func seed(_ jobs: [Job]) {
        condition.lock()
        stack.append(contentsOf: jobs)
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until a job is available; nil when the traversal is complete or cancelled.
    func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled { return nil }
            if let job = stack.popLast() {
                active += 1
                return job
            }
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    func complete(adding jobs: [Job]) {
        condition.lock()
        stack.append(contentsOf: jobs)
        active -= 1
        if jobs.count == 1 {
            condition.signal()
        } else if !jobs.isEmpty || (stack.isEmpty && active == 0) {
            condition.broadcast()
        }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Jobs never processed (after cancellation).
    func drainRemaining() -> [Job] {
        condition.lock()
        defer { condition.unlock() }
        let remaining = stack
        stack.removeAll()
        return remaining
    }
}

// MARK: - Session

final class ScanSession: @unchecked Sendable {
    private struct SharedStats {
        var files: UInt64 = 0
        var directories: UInt64 = 0
        var allocated: UInt64 = 0
        var logical: UInt64 = 0
        var cloud: UInt64 = 0
        var unreadable: UInt64 = 0
        var hardLinkDuplicates: Int = 0
        var sawPrivateSize = false
        var lastPath = ""
        var issues: [ScanIssue] = []
    }

    private static let maxIssues = 500

    let options: ScanOptions
    let rootPath: String
    let rootName: String
    let threadCount: Int
    let progress: (@Sendable (ScanProgress) -> Void)?

    private let queue = DirectoryWorkQueue()
    private let stats = OSAllocatedUnfairLock(initialState: SharedStats())
    private let cancelledFlag = OSAllocatedUnfairLock(initialState: false)
    private var guardrail: TraversalGuard!
    private var startedAt = Date()

    init(options: ScanOptions, rootName: String?, progress: (@Sendable (ScanProgress) -> Void)?) throws {
        self.options = options
        self.rootPath = Self.resolve(options.rootPath)
        self.rootName = rootName ?? rootPath
        self.progress = progress
        let cores = ProcessInfo.processInfo.activeProcessorCount
        self.threadCount = options.concurrency > 0 ? options.concurrency : min(max(cores, 4), 16)

        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw ScannerError.rootNotFound(path: rootPath, errorCode: errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ScannerError.rootNotDirectory(path: rootPath) }
    }

    /// realpath(3) with a sane fallback; strips trailing slashes.
    static func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var resolved: String = expanded
        if let real = realpath(expanded, nil) {
            resolved = String(cString: real)
            free(real)
        }
        while resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    var isCancelled: Bool { cancelledFlag.withLock { $0 } }

    func cancel() {
        cancelledFlag.withLock { $0 = true }
        queue.cancel()
    }

    // MARK: Run

    func run() -> ScanResult {
        startedAt = Date()
        var st = stat()
        lstat(rootPath, &st)
        let rootDevice = st.st_dev
        let wholeDisk = rootPath == "/"

        // lstat reports one device for the whole boot volume group (System +
        // Data + firmlinks), so firmlinks need no special casing here; other
        // volumes are separate devices and/or mount points.
        guardrail = TraversalGuard(
            crossMountPoints: options.crossMountPoints,
            excludedPaths: options.excludedPaths,
            allowedDevices: [rootDevice]
        )

        let root = FileTreeNode(
            name: rootName,
            kind: .directory,
            flags: Self.nodeFlags(bsdFlags: st.st_flags, extFlags: 0, name: (rootPath as NSString).lastPathComponent, isDirectory: true),
            fileID: UInt64(st.st_ino),
            deviceID: rootDevice,
            modificationTime: Int64(st.st_mtimespec.tv_sec)
        )
        _ = guardrail.markVisited(device: rootDevice, inode: UInt64(st.st_ino))

        // Phase 1.
        traverse(seed: [DirectoryWorkQueue.Job(node: root, path: rootPath)])

        // Phase 2 (whole disk): the Data volume, minus everything reached via firmlinks.
        if wholeDisk, !options.crossMountPoints, !isCancelled,
           let dataNode = root.descendant(atPath: TraversalGuard.dataVolumeMount),
           dataNode.kind == .directory, dataNode.flags.contains(.mountPoint) {
            var dst = stat()
            if lstat(TraversalGuard.dataVolumeMount, &dst) == 0 {
                _ = guardrail.markVisited(device: dst.st_dev, inode: UInt64(dst.st_ino))
            }
            dataNode.flags.remove(.excluded)
            traverse(seed: [DirectoryWorkQueue.Job(node: dataNode, path: TraversalGuard.dataVolumeMount)])
        }

        let cancelled = isCancelled
        if cancelled {
            for job in queue.drainRemaining() {
                job.node.flags.insert(.incompleteSubtree)
            }
            root.flags.insert(.incompleteSubtree)
        }

        aggregate(root)

        let completedAt = Date()
        let finalStats = stats.withLock { $0 }
        reportProgress(final: true)
        return ScanResult(
            root: root,
            options: options,
            startedAt: startedAt,
            completedAt: completedAt,
            issues: finalStats.issues,
            unreadableCount: Int(finalStats.unreadable),
            privateSizeSupported: finalStats.sawPrivateSize,
            hardLinkDuplicateCount: finalStats.hardLinkDuplicates,
            wasCancelled: cancelled
        )
    }

    /// Runs the worker pool until the frontier is exhausted (or cancelled),
    /// reporting progress every ~100 ms from this thread.
    private func traverse(seed: [DirectoryWorkQueue.Job]) {
        queue.seed(seed)
        let group = DispatchGroup()
        for index in 0..<threadCount {
            group.enter()
            let thread = Thread { [self] in
                workerLoop()
                group.leave()
            }
            thread.name = "klad.scan.worker.\(index)"
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
        while group.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            reportProgress(final: false)
        }
    }

    private func reportProgress(final: Bool) {
        guard let progress else { return }
        let snapshot = stats.withLock { $0 }
        progress(ScanProgress(
            filesScanned: snapshot.files,
            directoriesScanned: snapshot.directories,
            allocatedBytes: snapshot.allocated,
            logicalBytes: snapshot.logical,
            cloudStubBytes: snapshot.cloud,
            unreadableCount: snapshot.unreadable,
            currentPath: snapshot.lastPath,
            elapsed: Date().timeIntervalSince(startedAt)
        ))
    }

    // MARK: Worker

    private func workerLoop() {
        DatalessMaterializationGuard.engageForCurrentThread()
        var reader = BulkDirectoryReader(requestPrivateSize: options.requestPrivateSize)
        defer { reader.deallocate() }
        while let job = queue.next() {
            var newJobs: [DirectoryWorkQueue.Job] = []
            process(job, reader: &reader, newJobs: &newJobs)
            queue.complete(adding: newJobs)
        }
    }

    private func process(_ job: DirectoryWorkQueue.Job, reader: inout BulkDirectoryReader, newJobs: inout [DirectoryWorkQueue.Job]) {
        let prefix = job.path == "/" ? "/" : job.path + "/"
        var children: [FileTreeNode] = []
        var files: UInt64 = 0
        var directories: UInt64 = 0
        var allocated: UInt64 = 0
        var logical: UInt64 = 0
        var cloud: UInt64 = 0
        var hardLinkDuplicates = 0
        var sawPrivate = false
        let guardrail = self.guardrail!

        let result = reader.read(path: job.path, isCancelled: { self.isCancelled }) { entry in
            guard entry.nameLength > 0 else { return }
            let name = entry.name

            if entry.isDirectory {
                let childPath = prefix + name
                var identity = entry
                if entry.bsdFlags & BSDFileFlags.sfFirmlink != 0 {
                    // getattrlistbulk describes the firmlink node itself (System volume
                    // inode); lstat resolves to the Data-volume target. Use the target's
                    // identity so the visited set dedupes /System/Volumes/Data/<x> and the
                    // cleanup pre-flight (lstat-based) sees matching inodes.
                    var st = stat()
                    if lstat(childPath, &st) == 0 {
                        identity.fileID = UInt64(st.st_ino)
                        identity.deviceID = st.st_dev
                        identity.modificationTime = Int64(st.st_mtimespec.tv_sec)
                    }
                }
                let node = FileTreeNode(
                    name: name,
                    kind: .directory,
                    flags: Self.nodeFlags(bsdFlags: entry.bsdFlags, extFlags: entry.extFlags, name: name, isDirectory: true),
                    fileID: identity.fileID,
                    deviceID: identity.deviceID,
                    modificationTime: identity.modificationTime
                )
                switch guardrail.decide(entry: identity, childPath: childPath) {
                case .descend:
                    newJobs.append(DirectoryWorkQueue.Job(node: node, path: childPath))
                case .skip(let extra):
                    node.flags.formUnion(extra)
                case .omit:
                    return
                }
                directories += 1
                children.append(node)
                return
            }

            let kind: NodeKind = entry.isRegular ? .file : (entry.isSymlink ? .symlink : .other)
            var flags = Self.nodeFlags(bsdFlags: entry.bsdFlags, extFlags: entry.extFlags, name: name, isDirectory: false)
            let fileLogical = UInt64(max(0, entry.totalSize))
            let fileAllocated = UInt64(max(0, entry.allocSize))
            var filePrivate: UInt64
            if entry.hasPrivateSize {
                filePrivate = min(UInt64(max(0, entry.privateSize)), fileAllocated)
                sawPrivate = true
            } else {
                filePrivate = fileAllocated
                flags.insert(.privateSizeUnavailable)
            }
            var duplicate = false
            if entry.linkCount > 1 && kind == .file {
                flags.insert(.hardLinked)
                // Deleting one name of a hard-linked inode frees nothing.
                filePrivate = 0
                if !guardrail.registerHardLink(device: entry.deviceID, inode: entry.fileID) {
                    flags.insert(.hardLinkDuplicate)
                    duplicate = true
                    hardLinkDuplicates += 1
                }
            }
            let isStub = flags.contains(.cloudPlaceholder)
            let node = FileTreeNode(
                name: name,
                kind: kind,
                metrics: StorageMetrics(
                    logicalBytes: fileLogical,
                    allocatedBytes: fileAllocated,
                    privateBytes: filePrivate,
                    cloudStubBytes: isStub ? fileLogical : 0,
                    fileCount: 1
                ),
                flags: flags,
                fileID: entry.fileID,
                deviceID: entry.deviceID,
                modificationTime: entry.modificationTime,
                cloneID: entry.cloneID,
                errorCode: Int32(bitPattern: entry.errorCode)
            )
            files += 1
            if !duplicate {
                allocated &+= fileAllocated
                logical &+= fileLogical
                if isStub { cloud &+= fileLogical }
            }
            children.append(node)
        }

        var failure: Int32?
        switch result {
        case .ok: break
        case .openFailed(let code), .readFailed(let code): failure = code
        case .cancelled: job.node.flags.insert(.incompleteSubtree)
        }
        if let failure {
            job.node.flags.insert(.unreadable)
            job.node.errorCode = failure
        }
        job.node.setChildren(children)

        let jobPath = job.path
        stats.withLock { [files, directories, allocated, logical, cloud, hardLinkDuplicates, sawPrivate, failure] s in
            s.files &+= files
            s.directories &+= directories + 1
            s.allocated &+= allocated
            s.logical &+= logical
            s.cloud &+= cloud
            s.hardLinkDuplicates += hardLinkDuplicates
            if sawPrivate { s.sawPrivateSize = true }
            s.lastPath = jobPath
            if let failure {
                s.unreadable &+= 1
                if s.issues.count < Self.maxIssues {
                    s.issues.append(ScanIssue(path: jobPath, errorCode: failure, message: String(cString: strerror(failure))))
                }
            }
        }
    }

    // MARK: Aggregation

    /// Post-order aggregation, parallel across the root's directory children.
    private func aggregate(_ root: FileTreeNode) {
        let topDirectories = root.children.filter { $0.kind == .directory }
        DispatchQueue.concurrentPerform(iterations: topDirectories.count) { index in
            topDirectories[index].recomputeAggregates(sortChildren: true)
        }
        root.aggregateFromChildren(sort: true)
    }

    // MARK: Flags

    static func nodeFlags(bsdFlags: UInt32, extFlags: UInt64, name: String, isDirectory: Bool) -> NodeFlags {
        var flags: NodeFlags = []
        if bsdFlags & BSDFileFlags.sfDataless != 0 { flags.insert(.cloudPlaceholder) }
        if bsdFlags & BSDFileFlags.sfFirmlink != 0 { flags.insert(.firmlink) }
        if bsdFlags & BSDFileFlags.ufCompressed != 0 { flags.insert(.compressed) }
        if bsdFlags & BSDFileFlags.sfRestricted != 0 { flags.insert(.restricted) }
        if bsdFlags & (BSDFileFlags.ufImmutable | BSDFileFlags.sfImmutable | BSDFileFlags.sfNoUnlink) != 0 {
            flags.insert(.immutable)
        }
        if bsdFlags & BSDFileFlags.ufHidden != 0 || name.hasPrefix(".") { flags.insert(.hidden) }
        if extFlags & BSDExtFlags.mayShareBlocks != 0 { flags.insert(.mayShareBlocks) }
        if extFlags & BSDExtFlags.sharesAllBlocks != 0 { flags.insert(.sharesAllBlocks) }
        if extFlags & BSDExtFlags.isSparse != 0 { flags.insert(.sparse) }
        if extFlags & BSDExtFlags.isPurgeable != 0 { flags.insert(.purgeable) }
        if extFlags & BSDExtFlags.isSynthetic != 0 { flags.insert(.synthetic) }
        if extFlags & BSDExtFlags.isSyncRoot != 0 { flags.insert(.syncRoot) }
        if isDirectory && TraversalGuard.isPackageName(name) { flags.insert(.package) }
        return flags
    }
}
