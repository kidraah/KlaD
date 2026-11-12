// DuplicateDetectorTests.swift
import Darwin
import Foundation
import Testing
import KlaDModels
@testable import KlaDStorageOps

private let MiB = 1 << 20

@Suite("DuplicateDetectorService")
struct DuplicateDetectorTests {
    private let options = DuplicateScanOptions(minimumBytes: 1 << 20)

    @Test func identicalFilesFormOneGroup() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let payload = randomData(2 * MiB)
        let newest = try scratch.file("c.bin", bytes: payload)
        let oldest = try scratch.file("a.bin", bytes: payload)
        let middle = try scratch.file("b.bin", bytes: payload)
        _ = try scratch.file("other.bin", bytes: randomData(2 * MiB))
        setModificationTime(oldest, seconds: 1_000_000)
        setModificationTime(middle, seconds: 2_000_000)
        setModificationTime(newest, seconds: 3_000_000)

        let candidates = [newest, oldest, middle, scratch.path + "/other.bin"].map { candidate($0) }
        let groups = try await DuplicateDetectorService().findDuplicates(among: candidates, options: options, progress: nil)

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.paths == [oldest, middle, newest])   // oldest (kept) first
        #expect(group.fileSize == UInt64(2 * MiB))
        #expect(group.contentHash.count == 64)
        let expected = candidates.filter { $0.path != oldest && $0.path != scratch.path + "/other.bin" }
            .reduce(UInt64(0)) { $0 + $1.privateBytes }
        #expect(group.reclaimableBytes == expected)
        #expect(group.reclaimableBytes > 0)
    }

    @Test func sameSizeDifferentContentYieldsNothing() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        // Differ at the head (caught by the edge hash) …
        let a = try scratch.file("a", bytes: randomData(2 * MiB))
        let b = try scratch.file("b", bytes: randomData(2 * MiB))
        // … and one byte in the middle (only the full hash can tell).
        let base = randomData(2 * MiB)
        var tweaked = base
        tweaked[MiB] ^= 0xFF
        let c = try scratch.file("c", bytes: base)
        let d = try scratch.file("d", bytes: tweaked)
        let groups = try await DuplicateDetectorService().findDuplicates(
            among: [a, b, c, d].map { candidate($0) }, options: options, progress: nil)
        #expect(groups.isEmpty)
    }

    @Test func cloudPlaceholderIsNeverOpened() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let payload = randomData(2 * MiB)
        let a = try scratch.file("a", bytes: payload)
        let b = try scratch.file("b", bytes: payload)
        let stub = try scratch.file("stub", bytes: payload)
        #expect(chmod(stub, 0o000) == 0)
        let candidates = [candidate(a), candidate(b), candidate(stub, flags: .cloudPlaceholder)]
        let groups = try await DuplicateDetectorService().findDuplicates(among: candidates, options: options, progress: nil)
        #expect(groups.count == 1)
        #expect(groups.first?.paths.sorted() == [a, b].sorted())
        // Even a *non*-flagged unreadable file is merely skipped, never a crash/throw.
        let withUnreadable = [candidate(a), candidate(b), candidate(stub)]
        let again = try await DuplicateDetectorService().findDuplicates(among: withUnreadable, options: options, progress: nil)
        #expect(again.first?.paths.sorted() == [a, b].sorted())
    }

    @Test func apfsClonesCountAsOneCopy() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let original = try scratch.file("orig", bytes: randomData(2 * MiB))
        let clonePath = scratch.path + "/clone"
        let cloneOK = Darwin.clonefile(original, clonePath, 0) == 0
        if !cloneOK { _ = try scratch.file("clone", bytes: try Data(contentsOf: URL(fileURLWithPath: original))) }
        // Real fileIDs differ; the scanner would report the same cloneID + sharesAllBlocks for both.
        let flags: NodeFlags = [.sharesAllBlocks, .mayShareBlocks]
        let groups = try await DuplicateDetectorService().findDuplicates(
            among: [candidate(original, flags: flags, cloneID: 4242), candidate(clonePath, flags: flags, cloneID: 4242)],
            options: options, progress: nil)
        #expect(groups.isEmpty)

        // A clone pair plus an independent identical copy ⇒ one group of 2 (clone counted once).
        let independent = try scratch.file("indep", bytes: try Data(contentsOf: URL(fileURLWithPath: original)))
        let three = try await DuplicateDetectorService().findDuplicates(
            among: [candidate(original, flags: flags, cloneID: 4242), candidate(clonePath, flags: flags, cloneID: 4242), candidate(independent)],
            options: options, progress: nil)
        #expect(three.first?.paths.count == 2)

        // Same cloneID without a sharing flag is NOT trusted.
        let unflagged = try await DuplicateDetectorService().findDuplicates(
            among: [candidate(original, cloneID: 7), candidate(clonePath, cloneID: 7)], options: options, progress: nil)
        #expect(unflagged.count == 1)
    }

    @Test func hardLinksCountAsOneCopy() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let original = try scratch.file("orig", bytes: randomData(2 * MiB))
        let link = scratch.path + "/link"
        #expect(Darwin.link(original, link) == 0)
        let a = candidate(original), b = candidate(link)
        #expect(a.fileID == b.fileID)
        let groups = try await DuplicateDetectorService().findDuplicates(among: [a, b], options: options, progress: nil)
        #expect(groups.isEmpty)
        // Flagged duplicates are dropped outright.
        let other = try scratch.file("copy", bytes: try Data(contentsOf: URL(fileURLWithPath: original)))
        let flagged = try await DuplicateDetectorService().findDuplicates(
            among: [candidate(original), candidate(other, flags: .hardLinkDuplicate)], options: options, progress: nil)
        #expect(flagged.isEmpty)
    }

    @Test func symlinksAndSizeMismatchesAreSkipped() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let payload = randomData(2 * MiB)
        let a = try scratch.file("a", bytes: payload)
        let b = try scratch.file("b", bytes: payload)
        let link = scratch.path + "/link"
        #expect(symlink(a, link) == 0)
        var viaLink = candidate(a); viaLink.path = link; viaLink.fileID = 999_999_999
        var stale = candidate(b); stale.path = try scratch.file("stale", bytes: payload + Data([1]))
        stale.fileID = 888_888_888
        let groups = try await DuplicateDetectorService().findDuplicates(
            among: [candidate(a), viaLink, stale], options: options, progress: nil)
        #expect(groups.isEmpty)
    }

    @Test func minimumAndByteBudgetAreHonored() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let payload = randomData(2 * MiB)
        let a = try scratch.file("a", bytes: payload), b = try scratch.file("b", bytes: payload)
        let candidates = [candidate(a), candidate(b)]
        let small = try await DuplicateDetectorService().findDuplicates(
            among: candidates, options: DuplicateScanOptions(minimumBytes: 4 << 20), progress: nil)
        #expect(small.isEmpty)
        let starved = try await DuplicateDetectorService().findDuplicates(
            among: candidates, options: DuplicateScanOptions(minimumBytes: 1 << 20, maxBytesToHash: 1024), progress: nil)
        #expect(starved.isEmpty)
        let exact = try await DuplicateDetectorService().findDuplicates(
            among: candidates, options: DuplicateScanOptions(minimumBytes: 1 << 20, maxBytesToHash: UInt64(4 * MiB)), progress: nil)
        #expect(exact.count == 1)
    }

    @Test func groupsSortedByReclaimableDescending() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let small = randomData(2 * MiB), large = randomData(3 * MiB)
        let paths = [try scratch.file("s1", bytes: small), try scratch.file("s2", bytes: small),
                     try scratch.file("l1", bytes: large), try scratch.file("l2", bytes: large)]
        let groups = try await DuplicateDetectorService(maxConcurrentFiles: 2).findDuplicates(
            among: paths.map { candidate($0) }, options: options, progress: nil)
        #expect(groups.count == 2)
        #expect(groups[0].fileSize == UInt64(3 * MiB))
        #expect(groups[0].reclaimableBytes >= groups[1].reclaimableBytes)
    }

    @Test func progressReportsPhasesAndFinishes() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let payload = randomData(2 * MiB)
        let paths = [try scratch.file("a", bytes: payload), try scratch.file("b", bytes: payload)]
        let seen = LockedBox<[DuplicateScanProgress]>([])
        _ = try await DuplicateDetectorService().findDuplicates(
            among: paths.map { candidate($0) }, options: options, progress: { p in seen.mutate { $0.append(p) } })
        let phases = seen.value.map(\.phase)
        #expect(phases.first == .groupingBySize)
        #expect(phases.last == .finished)
        #expect(phases.contains(.fullHashing))
        #expect((seen.value.last?.bytesHashed ?? 0) == UInt64(4 * MiB))
    }

    @Test func cancellationThrows() async throws {
        let scratch = try ScratchDir("dup"); defer { scratch.cleanup() }
        let payload = randomData(2 * MiB)
        let paths = [try scratch.file("a", bytes: payload), try scratch.file("b", bytes: payload)]
        let candidates = paths.map { candidate($0) }
        let opts = options
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await DuplicateDetectorService().findDuplicates(among: candidates, options: opts, progress: nil)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
