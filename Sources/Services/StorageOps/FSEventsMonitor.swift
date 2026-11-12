// FSEventsMonitor.swift — KlaDStorageOps
//
// Directory-level FSEvents → coalesced `DirtyPathBatch` AsyncStream.

import CoreServices
import Foundation
import KlaDModels

public enum FSEventsMonitorError: Error, Sendable, CustomStringConvertible {
    case noPaths
    case streamCreationFailed
    case streamStartFailed

    public var description: String {
        switch self {
        case .noPaths: return "No paths to watch"
        case .streamCreationFailed: return "FSEventStreamCreate failed"
        case .streamStartFailed: return "FSEventStreamStart failed"
        }
    }
}

public final class FSEventsMonitor: FileSystemWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.klad.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var sink: Sink?
    private var running = false

    public init() {}

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func start(paths: [String], latency: TimeInterval) throws -> AsyncStream<DirtyPathBatch> {
        let watched = paths.filter { !$0.isEmpty }
        guard !watched.isEmpty else { throw FSEventsMonitorError.noPaths }

        // Restart semantics: tear the previous stream down first.
        stop()

        let (events, continuation) = AsyncStream<DirtyPathBatch>.makeStream(bufferingPolicy: .unbounded)
        let sink = Sink(continuation: continuation, aliases: Self.aliases(for: watched))
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                if let info { _ = Unmanaged<Sink>.fromOpaque(info).retain() }
                return info
            },
            release: { info in
                if let info { Unmanaged<Sink>.fromOpaque(info).release() }
            },
            copyDescription: nil)

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, fsEventsCallback, &context, watched as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), max(0, latency), flags)
        else {
            continuation.finish()
            throw FSEventsMonitorError.streamCreationFailed
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            continuation.finish()
            throw FSEventsMonitorError.streamStartFailed
        }

        lock.lock()
        self.stream = created
        self.sink = sink
        self.running = true
        lock.unlock()

        // Consumer cancelled / dropped the stream → stop, unless we've already restarted.
        continuation.onTermination = { [weak self, weak sink] _ in
            guard let self, let sink else { return }
            self.stop(ifCurrent: sink)
        }
        return events
    }

    public func stop() { stop(ifCurrent: nil) }

    private func stop(ifCurrent expected: Sink?) {
        lock.lock()
        if let expected, sink !== expected { lock.unlock(); return }
        let oldStream = stream
        let oldSink = sink
        stream = nil
        sink = nil
        running = false
        lock.unlock()

        // Teardown outside the lock: finish() may synchronously fire onTermination.
        if let oldStream {
            FSEventStreamStop(oldStream)
            FSEventStreamInvalidate(oldStream)
            FSEventStreamRelease(oldStream)
        }
        oldSink?.continuation.finish()
    }

    // MARK: Path aliasing

    /// FSEvents reports canonical paths (/private/var/…); callers know the path they
    /// passed (/var/…). Map events back to the caller's spelling.
    private static func aliases(for watched: [String]) -> [(real: String, original: String)] {
        var result: [(String, String)] = []
        for original in watched {
            let trimmed = Sink.stripTrailingSlash(original)
            guard let resolved = realpath(trimmed, nil) else { continue }
            defer { free(resolved) }
            let real = String(cString: resolved)
            if real != trimmed { result.append((real, trimmed)) }
        }
        return result.sorted { $0.0.count > $1.0.count }
    }

    // MARK: Callback sink

    /// Receives raw events on the FSEvents queue and yields batches.
    fileprivate final class Sink: @unchecked Sendable {
        let continuation: AsyncStream<DirtyPathBatch>.Continuation
        let aliases: [(real: String, original: String)]

        init(continuation: AsyncStream<DirtyPathBatch>.Continuation, aliases: [(real: String, original: String)]) {
            self.continuation = continuation
            self.aliases = aliases
        }

        static func stripTrailingSlash(_ path: String) -> String {
            var p = path
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }

        private func original(for path: String) -> String {
            for alias in aliases {
                if path == alias.real { return alias.original }
                if path.hasPrefix(alias.real + "/") { return alias.original + path.dropFirst(alias.real.count) }
            }
            return path
        }

        func handle(paths: [String], flags: [UInt32], eventCount: Int) {
            let mapped = paths.map { original(for: Self.stripTrailingSlash($0)) }
            let cover = FSEventsMonitor.minimalCover(paths: mapped, flags: flags)
            guard !cover.isEmpty else { return }
            continuation.yield(DirtyPathBatch(paths: cover, eventCount: eventCount, receivedAt: Date()))
        }

    }

    // MARK: Batching rules

    /// Maps raw events to a minimal cover: trailing "/" stripped, duplicates merged
    /// (recursive wins), `HistoryDone` / `EventIdsWrapped` ignored, and every path
    /// strictly inside a recursive path of the same batch dropped. Sorted by path.
    static func minimalCover(paths: [String], flags: [UInt32]) -> [DirtyPath] {
        let recursiveMask = UInt32(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        let ignoredMask = UInt32(kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagEventIdsWrapped)

        var recursiveByPath: [String: Bool] = [:]
        for (path, flag) in zip(paths, flags) {
            if flag & ignoredMask != 0 { continue }
            let clean = Sink.stripTrailingSlash(path)
            guard !clean.isEmpty else { continue }
            recursiveByPath[clean] = (recursiveByPath[clean] ?? false) || flag & recursiveMask != 0
        }
        let recursivePaths = Set(recursiveByPath.filter(\.value).keys)
        var result: [DirtyPath] = []
        for (path, recursive) in recursiveByPath {
            if !recursivePaths.isEmpty, hasRecursiveAncestor(path, in: recursivePaths) { continue }
            result.append(DirtyPath(path: path, recursive: recursive))
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func hasRecursiveAncestor(_ path: String, in recursive: Set<String>) -> Bool {
        if path != "/", recursive.contains("/") { return true }
        var current = path
        while let slash = current.lastIndex(of: "/"), slash != current.startIndex {
            current = String(current[..<slash])
            if recursive.contains(current) { return true }
        }
        return false
    }
}

/// C callback: no captures; the `Sink` arrives through the context `info` pointer.
private let fsEventsCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let sink = Unmanaged<FSEventsMonitor.Sink>.fromOpaque(info).takeUnretainedValue()
    let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    guard let paths = array as? [String] else { return }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
    sink.handle(paths: paths, flags: flags, eventCount: numEvents)
}
