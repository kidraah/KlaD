// FSEventsMonitorTests.swift
import CoreServices
import Foundation
import Testing
import KlaDModels
@testable import KlaDStorageOps

/// Returns true when `matches` is satisfied by a batch before `timeout`; keeps poking the directory meanwhile.
private func awaitBatch(
    _ stream: AsyncStream<DirtyPathBatch>, timeout: Duration = .seconds(10), poke: (@Sendable () -> Void)? = nil,
    matches: @escaping @Sendable (DirtyPathBatch) -> Bool
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await batch in stream where matches(batch) { return true }
            return false
        }
        group.addTask {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline, !Task.isCancelled {
                poke?()
                try? await Task.sleep(for: .milliseconds(300))
            }
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}



@Suite("FSEventsMonitor")
struct FSEventsMonitorTests {
    @Test func reportsChangedDirectoryAndStops() async throws {
        let scratch = try ScratchDir("fsev"); defer { scratch.cleanup() }
        let root = scratch.path
        let monitor = FSEventsMonitor()
        #expect(!monitor.isRunning)
        let stream = try monitor.start(paths: [root], latency: 0.1)
        #expect(monitor.isRunning)

        let counter = LockedBox(0)
        let found = await awaitBatch(
            stream,
            poke: {
                let n = counter.value; counter.mutate { $0 += 1 }
                try? Data("x".utf8).write(to: URL(fileURLWithPath: root + "/file\(n).txt"))
                try? FileManager.default.createDirectory(atPath: root + "/sub\(n)", withIntermediateDirectories: true)
            },
            matches: { batch in
                batch.paths.contains { $0.path == root || $0.path.hasPrefix(root + "/") } && batch.eventCount > 0
            })
        #expect(found, "no FSEvents batch containing the watched directory within 10 s")

        monitor.stop()
        #expect(!monitor.isRunning)
        monitor.stop() // idempotent

        // The stream finishes after stop().
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream {}; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished)
    }

    @Test func reportsPathsInTheCallersSpelling() async throws {
        // FileManager.temporaryDirectory lives under the /var → /private/var symlink.
        let scratch = try ScratchDir("fsev"); defer { scratch.cleanup() }
        let root = scratch.path
        let monitor = FSEventsMonitor()
        defer { monitor.stop() }
        let stream = try monitor.start(paths: [root + "/"], latency: 0.1)
        let counter = LockedBox(0)
        let found = await awaitBatch(
            stream,
            poke: {
                let n = counter.value; counter.mutate { $0 += 1 }
                try? Data("x".utf8).write(to: URL(fileURLWithPath: root + "/f\(n)"))
            },
            matches: { batch in batch.paths.contains { $0.path == root } })
        #expect(found)
    }

    @Test func restartFinishesPreviousStream() async throws {
        let scratch = try ScratchDir("fsev"); defer { scratch.cleanup() }
        let monitor = FSEventsMonitor()
        defer { monitor.stop() }
        let first = try monitor.start(paths: [scratch.path], latency: 0.1)
        let second = try monitor.start(paths: [scratch.path], latency: 0.1)
        #expect(monitor.isRunning)
        let firstEnded = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in first {}; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let r = await group.next() ?? false
            group.cancelAll()
            return r
        }
        #expect(firstEnded)
        #expect(monitor.isRunning)
        _ = second
    }

    @Test func emptyPathsThrow() {
        let monitor = FSEventsMonitor()
        #expect(throws: FSEventsMonitorError.self) { try monitor.start(paths: [], latency: 0.1) }
        #expect(!monitor.isRunning)
        monitor.stop()
        monitor.stop()
    }

    @Test func consumerCancellationStopsMonitor() async throws {
        let scratch = try ScratchDir("fsev"); defer { scratch.cleanup() }
        let monitor = FSEventsMonitor()
        let stream = try monitor.start(paths: [scratch.path], latency: 0.1)
        let task = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value
        for _ in 0..<50 where monitor.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!monitor.isRunning)
    }

    @Test func minimalCoverLogic() {
        let must = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        let dropped = UInt32(kFSEventStreamEventFlagUserDropped)
        let history = UInt32(kFSEventStreamEventFlagHistoryDone)
        let cover = FSEventsMonitor.minimalCover(
            paths: ["/a/b/", "/a/b/c", "/a/b/c/d", "/x/y", "/x/y", "/m", "/m/n", "/ignored", "/q", "/q/z"],
            flags: [0, must, 0, 0, 0, 0, 0, history, dropped, 0])
        // /a/b non-recursive stays (it is the parent of the recursive /a/b/c); /a/b/c/d is covered by /a/b/c;
        // duplicates merge; /m + /m/n are both non-recursive so both stay; /q is recursive so /q/z drops.
        #expect(cover == [
            DirtyPath(path: "/a/b", recursive: false), DirtyPath(path: "/a/b/c", recursive: true),
            DirtyPath(path: "/m", recursive: false), DirtyPath(path: "/m/n", recursive: false),
            DirtyPath(path: "/q", recursive: true), DirtyPath(path: "/x/y", recursive: false),
        ])
        // A recursive duplicate upgrades the non-recursive one.
        #expect(FSEventsMonitor.minimalCover(paths: ["/a", "/a/"], flags: [0, must]) == [DirtyPath(path: "/a", recursive: true)])
        // Recursive root swallows everything else.
        #expect(FSEventsMonitor.minimalCover(paths: ["/", "/a", "/b/c"], flags: [must, 0, 0]) == [DirtyPath(path: "/", recursive: true)])
        #expect(FSEventsMonitor.minimalCover(paths: ["/a"], flags: [history]).isEmpty)
    }

    // MARK: Replay





}
