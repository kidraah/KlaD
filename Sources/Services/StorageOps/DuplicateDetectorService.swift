// DuplicateDetectorService.swift — KlaDStorageOps
//
// size → edge hash (4 KiB head + tail) → full streamed SHA-256.
// Never opens SF_DATALESS files; lstat-guards every open; O_NOFOLLOW.

import CryptoKit
import Darwin
import Foundation
import KlaDModels

public final class DuplicateDetectorService: DuplicateDetecting {
    private let maxConcurrentFiles: Int
    private let homeDirectory: String

    /// `homeDirectory` is injectable for tests; candidates outside what
    /// `SystemPolicy.mayModify` permits for that home are never considered.
    public init(maxConcurrentFiles: Int = 4, homeDirectory: String = NSHomeDirectory()) {
        self.maxConcurrentFiles = max(1, maxConcurrentFiles)
        self.homeDirectory = SystemPolicy.normalize(homeDirectory)
    }

    private static let sfDataless: UInt32 = 0x4000_0000
    private static let edgeBytes = 4096
    private static let chunkBytes = 1 << 20

    public func findDuplicates(
        among candidates: [DuplicateCandidate],
        options: DuplicateScanOptions,
        progress: (@Sendable (DuplicateScanProgress) -> Void)?
    ) async throws -> [DuplicateGroup] {
        try Task.checkCancellation()
        let reporter = ProgressReporter(progress)

        // 1. Filter + collapse hard links and clones.
        let filtered = Self.collapse(candidates, minimumBytes: options.minimumBytes, home: homeDirectory)
        reporter.report(.groupingBySize, processed: 0, total: filtered.count, force: true)

        // 2. Group by logical size.
        var bySize: [UInt64: [DuplicateCandidate]] = [:]
        for c in filtered { bySize[c.logicalBytes, default: []].append(c) }
        let sizeGroups = bySize.values.filter { $0.count >= 2 }
        let edgeJobs = sizeGroups.flatMap { $0 }
        reporter.report(.groupingBySize, processed: filtered.count, total: filtered.count, force: true)
        try Task.checkCancellation()

        // 3. Edge hash.
        let edgeCounter = Counter()
        let edgeTotal = edgeJobs.count
        let edgeResults = try await Self.boundedMap(edgeJobs, limit: maxConcurrentFiles) { candidate -> String? in
            let hash = try Self.edgeHash(of: candidate)
            reporter.report(.edgeHashing, processed: edgeCounter.increment(), total: edgeTotal)
            return hash
        }
        var byEdge: [EdgeKey: [DuplicateCandidate]] = [:]
        for (candidate, hash) in zip(edgeJobs, edgeResults) {
            guard let hash else { continue }
            byEdge[EdgeKey(size: candidate.logicalBytes, hash: hash), default: []].append(candidate)
        }
        // Largest first so the byte budget is spent where it reclaims the most.
        let fullJobs = byEdge.values.filter { $0.count >= 2 }.flatMap { $0 }
            .sorted { $0.logicalBytes != $1.logicalBytes ? $0.logicalBytes > $1.logicalBytes : $0.path < $1.path }
        try Task.checkCancellation()

        // 4. Full SHA-256 with a global byte budget.
        let budget = ByteBudget(limit: options.maxBytesToHash)
        let fullCounter = Counter()
        let fullTotal = fullJobs.count
        reporter.report(.fullHashing, processed: 0, total: fullTotal, bytesHashed: 0, force: true)
        let fullResults = try await Self.boundedMap(fullJobs, limit: maxConcurrentFiles) { candidate -> String? in
            guard budget.reserve(candidate.logicalBytes) else { return nil }
            let hash: String?
            do {
                hash = try Self.fullHash(of: candidate)
            } catch {
                budget.refund(candidate.logicalBytes)
                throw error
            }
            if hash == nil { budget.refund(candidate.logicalBytes) }
            reporter.report(.fullHashing, processed: fullCounter.increment(), total: fullTotal, bytesHashed: budget.used)
            return hash
        }
        var byHash: [FullKey: [DuplicateCandidate]] = [:]
        for (candidate, hash) in zip(fullJobs, fullResults) {
            guard let hash else { continue }
            byHash[FullKey(size: candidate.logicalBytes, hash: hash), default: []].append(candidate)
        }
        try Task.checkCancellation()

        // 5. Build output.
        var groups: [DuplicateGroup] = []
        for (key, members) in byHash where members.count >= 2 {
            let ordered = Self.keepOrder(members, home: homeDirectory)
            let reclaimable = ordered.dropFirst().reduce(UInt64(0)) { $0 &+ $1.privateBytes }
            groups.append(DuplicateGroup(
                contentHash: key.hash, fileSize: key.size, paths: ordered.map(\.path), reclaimableBytes: reclaimable))
        }
        groups.sort {
            if $0.reclaimableBytes != $1.reclaimableBytes { return $0.reclaimableBytes > $1.reclaimableBytes }
            if $0.fileSize != $1.fileSize { return $0.fileSize > $1.fileSize }
            return $0.contentHash < $1.contentHash
        }
        reporter.report(.finished, processed: fullTotal, total: fullTotal, bytesHashed: budget.used, force: true)
        return groups
    }

    // MARK: "Keep the original-looking copy"

    /// Orders a group so the copy most likely to be the original comes first:
    /// (1) not copy-named, (2) not in Downloads / Trash / a backup-or-old folder,
    /// (3) oldest modification, (4) shortest path (then lexical, for determinism).
    static func keepOrder(_ members: [DuplicateCandidate], home: String) -> [DuplicateCandidate] {
        struct Key: Comparable {
            var copyNamed: Bool
            var lowPriorityLocation: Bool
            var modified: Int64
            var pathLength: Int
            var path: String
            static func < (a: Key, b: Key) -> Bool {
                if a.copyNamed != b.copyNamed { return !a.copyNamed }
                if a.lowPriorityLocation != b.lowPriorityLocation { return !a.lowPriorityLocation }
                if a.modified != b.modified { return a.modified < b.modified }
                if a.pathLength != b.pathLength { return a.pathLength < b.pathLength }
                return a.path < b.path
            }
        }
        func key(_ c: DuplicateCandidate) -> Key {
            Key(copyNamed: isCopyNamed(fileName: (c.path as NSString).lastPathComponent),
                lowPriorityLocation: isInLowPriorityLocation(c.path, home: home),
                modified: c.modificationTime > 0 ? c.modificationTime : Int64.max,
                pathLength: c.path.utf8.count, path: c.path)
        }
        return members.map { (key($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// "x copy.txt", "x copy 2.txt", "x (1).txt", "x-1.txt", "x 2.txt", "Copy of x.txt".
    static func isCopyNamed(fileName: String) -> Bool {
        let base = (fileName as NSString).deletingPathExtension.lowercased()
        if base.hasPrefix("copy of ") { return true }
        let range = NSRange(base.startIndex..., in: base)
        return copyNamePattern.firstMatch(in: base, range: range) != nil
    }

    private static let copyNamePattern = try! NSRegularExpression(
        pattern: #"( copy( \d+)?| \(\d+\)|[ \-]\d{1,2})$"#)

    static func isInLowPriorityLocation(_ path: String, home: String) -> Bool {
        let normalized = SystemPolicy.normalize(path)
        if normalized.hasPrefix(home + "/Downloads/") { return true }
        for folder in normalized.split(separator: "/").dropLast() {
            let name = folder.lowercased()
            if name == ".trash" || name == "trash" || name.contains("backup") { return true }
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.contains(where: { $0 == "old" || $0 == "bak" }) { return true }
        }
        return false
    }

    // MARK: Candidate filtering

    private struct EdgeKey: Hashable { var size: UInt64; var hash: String }
    private struct FullKey: Hashable { var size: UInt64; var hash: String }
    private struct DeviceFile: Hashable { var device: Int32; var id: UInt64 }

    static func collapse(_ candidates: [DuplicateCandidate], minimumBytes: UInt64, home: String) -> [DuplicateCandidate] {
        var seenFiles = Set<DeviceFile>()
        var seenClones = Set<DeviceFile>()
        var seenPaths = Set<String>()
        var result: [DuplicateCandidate] = []
        for c in candidates {
            if c.flags.contains(.cloudPlaceholder) || c.flags.contains(.hardLinkDuplicate) { continue }
            if c.allocatedBytes == 0 || c.logicalBytes == 0 || c.logicalBytes < minimumBytes { continue }
            guard SystemPolicy.mayModify(c.path, home: home) else { continue }
            guard seenPaths.insert(c.path).inserted else { continue }
            if c.fileID != 0, !seenFiles.insert(DeviceFile(device: c.deviceID, id: c.fileID)).inserted { continue }
            if c.cloneID != 0, c.flags.contains(.sharesAllBlocks) || c.flags.contains(.mayShareBlocks),
               !seenClones.insert(DeviceFile(device: c.deviceID, id: c.cloneID)).inserted { continue }
            result.append(c)
        }
        return result
    }

    // MARK: File access

    /// lstat-guards then opens. Returns nil to skip the file.
    private static func openGuarded(_ candidate: DuplicateCandidate) -> Int32? {
        var st = stat()
        guard lstat(candidate.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              (st.st_flags & sfDataless) == 0,
              UInt64(st.st_size) == candidate.logicalBytes
        else { return nil }
        let fd = open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              opened.st_ino == st.st_ino, opened.st_dev == st.st_dev,
              (opened.st_flags & sfDataless) == 0,
              UInt64(opened.st_size) == candidate.logicalBytes
        else { close(fd); return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
        return fd
    }

    /// Reads exactly `count` bytes at `offset`; nil on short read or error.
    private static func pread(fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int, offset: Int64) -> Bool {
        var done = 0
        while done < count {
            let n = Darwin.pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if n > 0 { done += n }
            else if n < 0 && errno == EINTR { continue }
            else { return false }
        }
        return true
    }

    private static func edgeHash(of candidate: DuplicateCandidate) throws -> String? {
        try Task.checkCancellation()
        guard let fd = openGuarded(candidate) else { return nil }
        defer { close(fd) }
        let size = Int64(candidate.logicalBytes)
        let n = Int(min(Int64(edgeBytes), size))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var sizeLE = UInt64(size).littleEndian
        withUnsafeBytes(of: &sizeLE) { hasher.update(bufferPointer: $0) }
        guard pread(fd: fd, into: buffer, count: n, offset: 0) else { return nil }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
        guard pread(fd: fd, into: buffer, count: n, offset: size - Int64(n)) else { return nil }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
        return hex(hasher.finalize())
    }

    private static func fullHash(of candidate: DuplicateCandidate) throws -> String? {
        try Task.checkCancellation()
        guard let fd = openGuarded(candidate) else { return nil }
        defer { close(fd) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var total: UInt64 = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            let n = Darwin.read(fd, buffer, chunkBytes)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            total += UInt64(n)
        }
        // The file changed while we were reading it → not trustworthy.
        guard total == candidate.logicalBytes else { return nil }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Concurrency helpers

    /// Maps `items` with at most `limit` concurrent blocking workers; results keep input order.
    private static func boundedMap<T: Sendable, R: Sendable>(
        _ items: [T], limit: Int, _ work: @escaping @Sendable (T) throws -> R
    ) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            func launch(_ g: inout ThrowingTaskGroup<(Int, R), Error>) {
                let index = next
                next += 1
                let item = items[index]
                g.addTask {
                    try Task.checkCancellation()
                    return (index, try work(item))
                }
            }
            while next < min(limit, items.count) { launch(&group) }
            while let (index, value) = try await group.next() {
                results[index] = value
                try Task.checkCancellation()
                if next < items.count { launch(&group) }
            }
            return results.map { $0! }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private final class ByteBudget: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: UInt64
        private var consumed: UInt64 = 0
        private var exhausted = false
        init(limit: UInt64) { self.limit = limit }
        var used: UInt64 { lock.lock(); defer { lock.unlock() }; return consumed }
        func reserve(_ bytes: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if exhausted { return false }
            if consumed > limit || bytes > limit - consumed { exhausted = true; return false }
            consumed += bytes
            return true
        }
        func refund(_ bytes: UInt64) {
            lock.lock(); defer { lock.unlock() }
            consumed = consumed >= bytes ? consumed - bytes : 0
        }
    }

    /// Throttles progress callbacks to ≤ 10 Hz (phase boundaries are forced).
    private final class ProgressReporter: @unchecked Sendable {
        private let callback: (@Sendable (DuplicateScanProgress) -> Void)?
        private let lock = NSLock()
        private var lastEmit: UInt64 = 0
        init(_ callback: (@Sendable (DuplicateScanProgress) -> Void)?) { self.callback = callback }

        func report(_ phase: DuplicateScanProgress.Phase, processed: Int, total: Int, bytesHashed: UInt64 = 0, force: Bool = false) {
            guard let callback else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            if !force, now &- lastEmit < 100_000_000 { lock.unlock(); return }
            lastEmit = now
            lock.unlock()
            callback(DuplicateScanProgress(phase: phase, filesProcessed: processed, filesTotal: total, bytesHashed: bytesHashed))
        }
    }
}
