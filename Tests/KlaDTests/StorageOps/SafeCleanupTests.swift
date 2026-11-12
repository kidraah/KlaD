// SafeCleanupTests.swift
import Darwin
import Foundation
import Testing
import KlaDModels
@testable import KlaDStorageOps

private func makeService(
    running: Set<String> = [], trashDir: String? = nil, trashed: LockedBox<[String]>? = nil
) -> SafeCleanupService {
    SafeCleanupService(
        runningApplicationBundleIDs: { running },
        trashItem: { url in
            trashed?.mutate { $0.append(url.path) }
            guard let trashDir else { return nil }
            let destination = URL(fileURLWithPath: trashDir).appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
}

private func check(_ report: PreflightReport, _ id: String) -> PreflightCheck? {
    report.checks.first { $0.id == id }
}

@Suite("SafeCleanupService")
struct SafeCleanupTests {
    private func makeTarget(_ scratch: ScratchDir, name: String = "DerivedData") throws -> String {
        let dir = scratch.path + "/" + name
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: dir + "/file.txt"))
        return dir
    }

    @Test func preflightPassesOnTempDirWithAllChecksInOrder() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let report = await makeService().preflight(cleanupTarget(dir))
        #expect(report.checks.map(\.id) == ["exists", "identity", "safety", "protectedPath", "runningApps", "openFiles"])
        #expect(report.checks.map(\.title) == [
            "Item still exists", "Same item as scanned", "Safety tier permits Trash", "Not a protected location",
            "Related apps are closed", "No open files inside",
        ])
        #expect(report.canProceed)
        #expect(report.checks.allSatisfy { $0.status == .passed }, "\(report.checks)")
        #expect(report.processesUsingTarget.isEmpty)
    }

    @Test func missingItemFails() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let target = cleanupTarget(dir)
        try FileManager.default.moveItem(atPath: dir, toPath: scratch.path + "/moved")
        let report = await makeService().preflight(target)
        #expect(check(report, "exists")?.status == .failed)
        #expect(check(report, "identity")?.status == .failed)
        #expect(!report.canProceed)
        #expect(report.checks.count == 6)
    }

    @Test func identityMismatchFailsAndMtimeDriftWarns() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        var target = cleanupTarget(dir)
        target.identity.fileID &+= 1
        var report = await makeService().preflight(target)
        #expect(check(report, "identity")?.status == .failed)
        #expect(!report.canProceed)

        target = cleanupTarget(dir)
        target.identity.deviceID &+= 1
        report = await makeService().preflight(target)
        #expect(check(report, "identity")?.status == .failed)

        target = cleanupTarget(dir)
        target.identity.modificationTime -= 100
        report = await makeService().preflight(target)
        let identity = try #require(check(report, "identity"))
        #expect(identity.status == .warning)
        #expect(identity.detail.contains("Modified since the scan"))
        #expect(report.canProceed)
        #expect(report.hasWarnings)
    }

    @Test func unsafeTiersFail() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        for tier in [SafetyLevel.doNotDelete, .guidedExternalAction, .unknown] {
            let report = await makeService().preflight(cleanupTarget(dir, safety: tier))
            #expect(check(report, "safety")?.status == .failed, "\(tier)")
            #expect(!report.canProceed)
        }
        let review = await makeService().preflight(cleanupTarget(dir, safety: .reviewFirst))
        #expect(check(review, "safety")?.status == .passed)
    }

    @Test func protectedLocationsFail() async throws {
        let home = NSHomeDirectory()
        var paths = ["/", home, "/System", "/Users", "/Applications", "/Library", "/private", "/usr", "/bin", "/sbin",
                     "/Volumes", home + "/Library", home + "/Documents", home + "/Desktop", home + "/Downloads"]
        paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        #expect(paths.contains("/") && paths.contains(home))
        for path in paths {
            let st = lstatInfo(path)
            let target = CleanupTarget(
                path: path, displayName: path, safety: .safeToClear,
                identity: NodeIdentity(fileID: UInt64(st.st_ino), deviceID: st.st_dev, modificationTime: Int64(st.st_mtimespec.tv_sec)),
                metrics: .zero, isDirectory: true)
            let report = await makeService().preflight(target)
            #expect(check(report, "protectedPath")?.status == .failed, "\(path) should be protected")
            #expect(!report.canProceed, "\(path)")
        }
        // Trailing slash / dot segments cannot sneak past.
        let sneaky = CleanupTarget(
            path: home + "/Library/../", displayName: "~", safety: .safeToClear,
            identity: NodeIdentity(fileID: UInt64(lstatInfo(home).st_ino), deviceID: lstatInfo(home).st_dev, modificationTime: 0),
            metrics: .zero, isDirectory: true)
        #expect(check(await makeService().preflight(sneaky), "protectedPath")?.status == .failed)
    }

    @Test func mountPointsAreProtected() async throws {
        // /System/Volumes/Data is the Data volume's mount point on every APFS macOS 11+.
        let path = "/System/Volumes/Data"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let report = await makeService().preflight(cleanupTarget(path))
        #expect(check(report, "protectedPath")?.status == .failed)
    }

    @Test func runningConflictingAppWarns() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let target = cleanupTarget(dir, conflicting: ["com.apple.dt.Xcode"])
        let running = await makeService(running: ["com.apple.dt.Xcode", "com.apple.finder"]).preflight(target)
        let warn = try #require(check(running, "runningApps"))
        #expect(warn.status == .warning)
        #expect(warn.detail.contains("com.apple.dt.Xcode"))
        #expect(running.canProceed)
        let closed = await makeService(running: ["com.apple.finder"]).preflight(target)
        #expect(check(closed, "runningApps")?.status == .passed)
    }

    @Test func openFileInsideTargetWarnsNamingThisProcess() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let handle = try #require(FileHandle(forReadingAtPath: dir + "/file.txt"))
        defer { try? handle.close() }
        let report = await makeService().preflight(cleanupTarget(dir))
        let open = try #require(check(report, "openFiles"))
        #expect(open.status == .warning, "\(open)")
        let me = try #require(report.processesUsingTarget.first { $0.pid == getpid() })
        #expect(!me.name.isEmpty)
        #expect(me.examplePath?.hasSuffix("/DerivedData/file.txt") == true)
        #expect(open.detail.contains(me.name))
        #expect(report.canProceed)   // a warning, not a failure

        // Once closed, the same target passes.
        try handle.close()
        let after = await makeService().preflight(cleanupTarget(dir))
        #expect(check(after, "openFiles")?.status == .passed)
    }

    @Test func currentDirectoryInsideTargetCounts() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        // A held directory fd is also a vnode open inside the target.
        let fd = open(dir, O_RDONLY | O_DIRECTORY)
        #expect(fd >= 0)
        defer { close(fd) }
        let report = await makeService().preflight(cleanupTarget(dir))
        #expect(check(report, "openFiles")?.status == .warning)
        #expect(report.processesUsingTarget.contains { $0.pid == getpid() })
    }

    @Test func moveToTrashUsesInjectedTrash() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let trash = scratch.path + "/FakeTrash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let calls = LockedBox<[String]>([])
        let service = makeService(trashDir: trash, trashed: calls)
        let target = cleanupTarget(dir)
        let report = await service.preflight(target)
        let outcome = await service.moveToTrash(target, report: report)
        #expect(outcome.succeeded, "\(outcome)")
        #expect(outcome.errorMessage == nil)
        #expect(outcome.trashedPath == trash + "/DerivedData")
        #expect(outcome.reclaimedPrivateBytes == 2048)
        #expect(outcome.movedAllocatedBytes == 4096)
        #expect(calls.value == [dir])
        #expect(!FileManager.default.fileExists(atPath: dir))
        #expect(FileManager.default.fileExists(atPath: trash + "/DerivedData/file.txt"))
    }

    @Test func moveToTrashRefusals() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let calls = LockedBox<[String]>([])
        let service = makeService(trashDir: scratch.path, trashed: calls)
        let target = cleanupTarget(dir)
        let good = await service.preflight(target)

        // canProceed == false
        var failing = good
        failing.checks[0].status = .failed
        var outcome = await service.moveToTrash(target, report: failing)
        #expect(!outcome.succeeded && outcome.errorMessage != nil && outcome.trashedPath == nil)

        // report for a different target
        var other = target
        other.path += "/file.txt"
        outcome = await service.moveToTrash(other, report: good)
        #expect(!outcome.succeeded)

        // unsafe tier even with a (forged) passing report
        var unsafe = target
        unsafe.safety = .doNotDelete
        outcome = await service.moveToTrash(unsafe, report: PreflightReport(target: unsafe, checks: [], processesUsingTarget: [], checkedAt: Date()))
        #expect(!outcome.succeeded)

        // protected location even with a forged empty report
        let home = NSHomeDirectory()
        var homeTarget = cleanupTarget(home)
        homeTarget.safety = .safeToClear
        outcome = await service.moveToTrash(homeTarget, report: PreflightReport(target: homeTarget, checks: [], processesUsingTarget: [], checkedAt: Date()))
        #expect(!outcome.succeeded)

        #expect(calls.value.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir))
    }

    @Test func moveToTrashRefusesSwappedItem() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let calls = LockedBox<[String]>([])
        let service = makeService(trashDir: scratch.path, trashed: calls)
        let target = cleanupTarget(dir)
        let report = await service.preflight(target)
        #expect(report.canProceed)

        // Swap: move away + recreate at the same path ⇒ new inode.
        try FileManager.default.moveItem(atPath: dir, toPath: scratch.path + "/elsewhere")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: URL(fileURLWithPath: dir + "/new.txt"))
        let outcome = await service.moveToTrash(target, report: report)
        #expect(!outcome.succeeded)
        #expect(outcome.errorMessage?.contains("replaced") == true, "\(outcome.errorMessage ?? "")")
        #expect(calls.value.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir + "/new.txt"))
    }

    @Test func trashFailureIsReported() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let service = SafeCleanupService(runningApplicationBundleIDs: { [] }, trashItem: { _ in throw Boom() })
        let target = cleanupTarget(dir)
        let outcome = await service.moveToTrash(target, report: await service.preflight(target))
        #expect(!outcome.succeeded)
        #expect(outcome.errorMessage?.contains("boom") == true)
        #expect(FileManager.default.fileExists(atPath: dir))
    }
}
