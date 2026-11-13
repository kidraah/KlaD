// SafeCleanupTests.swift
import Darwin
import Foundation
import Testing
import KlaDModels
@testable import KlaDStorageOps

private func makeService(
    running: Set<String> = [], trashDir: String? = nil, trashed: LockedBox<[String]>? = nil, home: String? = nil
) -> SafeCleanupService {
    SafeCleanupService(
        runningApplicationBundleIDs: { running },
        trashItem: { url in
            trashed?.mutate { $0.append(url.path) }
            guard let trashDir else { return nil }
            let destination = URL(fileURLWithPath: trashDir).appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        },
        homeDirectory: home ?? NSHomeDirectory())
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
        let report = await makeService(home: scratch.path).preflight(cleanupTarget(dir))
        #expect(report.checks.map(\.id) == [
            "exists", "identity", "safety", "systemPolicy", "ownership", "runningApps", "openFiles",
        ])
        #expect(report.checks.map(\.title) == [
            "Item still exists", "Same item as scanned", "Safety tier permits Trash",
            "Inside your home folder, outside protected data", "Owned by you, not locked by the system",
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
        let report = await makeService(home: scratch.path).preflight(target)
        #expect(check(report, "exists")?.status == .failed)
        #expect(check(report, "identity")?.status == .failed)
        #expect(!report.canProceed)
        #expect(report.checks.count == 7)
        #expect(check(report, "ownership")?.status == .failed)
    }

    @Test func identityMismatchFailsAndMtimeDriftWarns() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        var target = cleanupTarget(dir)
        target.identity.fileID &+= 1
        var report = await makeService(home: scratch.path).preflight(target)
        #expect(check(report, "identity")?.status == .failed)
        #expect(!report.canProceed)

        target = cleanupTarget(dir)
        target.identity.deviceID &+= 1
        report = await makeService(home: scratch.path).preflight(target)
        #expect(check(report, "identity")?.status == .failed)

        target = cleanupTarget(dir)
        target.identity.modificationTime -= 100
        report = await makeService(home: scratch.path).preflight(target)
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
            let report = await makeService(home: scratch.path).preflight(cleanupTarget(dir, safety: tier))
            #expect(check(report, "safety")?.status == .failed, "\(tier)")
            #expect(!report.canProceed)
        }
        let review = await makeService(home: scratch.path).preflight(cleanupTarget(dir, safety: .reviewFirst))
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
            #expect(check(report, "systemPolicy")?.status == .failed, "\(path) should be protected")
            #expect(!report.canProceed, "\(path)")
        }
        // Trailing slash / dot segments cannot sneak past.
        let sneaky = CleanupTarget(
            path: home + "/Library/../", displayName: "~", safety: .safeToClear,
            identity: NodeIdentity(fileID: UInt64(lstatInfo(home).st_ino), deviceID: lstatInfo(home).st_dev, modificationTime: 0),
            metrics: .zero, isDirectory: true)
        #expect(check(await makeService().preflight(sneaky), "systemPolicy")?.status == .failed)
    }

    @Test func mountPointsAreProtected() async throws {
        // /System/Volumes/Data is the Data volume's mount point on every APFS macOS 11+.
        let path = "/System/Volumes/Data"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let report = await makeService().preflight(cleanupTarget(path))
        #expect(check(report, "systemPolicy")?.status == .failed)
    }

    @Test func runningConflictingAppWarns() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let target = cleanupTarget(dir, conflicting: ["com.apple.dt.Xcode"])
        let running = await makeService(running: ["com.apple.dt.Xcode", "com.apple.finder"], home: scratch.path).preflight(target)
        let warn = try #require(check(running, "runningApps"))
        #expect(warn.status == .warning)
        #expect(warn.detail.contains("com.apple.dt.Xcode"))
        #expect(running.canProceed)
        let closed = await makeService(running: ["com.apple.finder"], home: scratch.path).preflight(target)
        #expect(check(closed, "runningApps")?.status == .passed)
    }

    @Test func openFileInsideTargetWarnsNamingThisProcess() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let handle = try #require(FileHandle(forReadingAtPath: dir + "/file.txt"))
        defer { try? handle.close() }
        let report = await makeService(home: scratch.path).preflight(cleanupTarget(dir))
        let open = try #require(check(report, "openFiles"))
        #expect(open.status == .warning, "\(open)")
        let me = try #require(report.processesUsingTarget.first { $0.pid == getpid() })
        #expect(!me.name.isEmpty)
        #expect(me.examplePath?.hasSuffix("/DerivedData/file.txt") == true)
        #expect(open.detail.contains(me.name))
        #expect(report.canProceed)   // a warning, not a failure

        // Once closed, the same target passes.
        try handle.close()
        let after = await makeService(home: scratch.path).preflight(cleanupTarget(dir))
        #expect(check(after, "openFiles")?.status == .passed)
    }

    @Test func currentDirectoryInsideTargetCounts() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        // A held directory fd is also a vnode open inside the target.
        let fd = open(dir, O_RDONLY | O_DIRECTORY)
        #expect(fd >= 0)
        defer { close(fd) }
        let report = await makeService(home: scratch.path).preflight(cleanupTarget(dir))
        #expect(check(report, "openFiles")?.status == .warning)
        #expect(report.processesUsingTarget.contains { $0.pid == getpid() })
    }

    @Test func moveToTrashUsesInjectedTrash() async throws {
        let scratch = try ScratchDir("clean"); defer { scratch.cleanup() }
        let dir = try makeTarget(scratch)
        let trash = scratch.path + "/FakeTrash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let calls = LockedBox<[String]>([])
        let service = makeService(trashDir: trash, trashed: calls, home: scratch.path)
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
        let service = makeService(trashDir: scratch.path, trashed: calls, home: scratch.path)
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
        let service = makeService(trashDir: scratch.path, trashed: calls, home: scratch.path)
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
        let service = SafeCleanupService(runningApplicationBundleIDs: { [] }, trashItem: { _ in throw Boom() }, homeDirectory: scratch.path)
        let target = cleanupTarget(dir)
        let outcome = await service.moveToTrash(target, report: await service.preflight(target))
        #expect(!outcome.succeeded)
        #expect(outcome.errorMessage?.contains("boom") == true)
        #expect(FileManager.default.fileExists(atPath: dir))
    }

    // MARK: - Hardening: system policy, ownership, iCloud, size

    private func forgedPassingReport(_ target: CleanupTarget) -> PreflightReport {
        PreflightReport(
            target: target,
            checks: ["exists", "identity", "safety", "systemPolicy", "ownership", "runningApps", "openFiles"].map {
                PreflightCheck(id: $0, title: $0, status: .passed, detail: "forged")
            },
            processesUsingTarget: [], checkedAt: Date())
    }

    @Test func systemPolicyPassesInsideHomeAndFailsOutside() async throws {
        let home = try ScratchDir("home"); defer { home.cleanup() }
        let elsewhere = try ScratchDir("elsewhere"); defer { elsewhere.cleanup() }
        let inside = try makeTarget(home, name: "project-build")
        let outside = try makeTarget(elsewhere, name: "project-build")
        let service = makeService(home: home.path)

        let ok = await service.preflight(cleanupTarget(inside))
        #expect(check(ok, "systemPolicy")?.status == .passed)
        #expect(ok.canProceed)

        let bad = await service.preflight(cleanupTarget(outside))
        #expect(check(bad, "systemPolicy")?.status == .failed, "outside the home folder")
        #expect(!bad.canProceed)
    }

    @Test func systemPolicyFailsOnProtectedAndTopLevelHomeFolders() async throws {
        let home = try ScratchDir("home"); defer { home.cleanup() }
        let fm = FileManager.default
        for relative in ["Documents", "Library", "Library/Caches", "Library/Mail/V10", "Library/Containers/com.x/Data",
                         "Library/Application Support/MobileSync/Backup", "Pictures/Photos Library.photoslibrary/originals"] {
            try fm.createDirectory(atPath: home.path + "/" + relative, withIntermediateDirectories: true)
            let report = await makeService(home: home.path).preflight(cleanupTarget(home.path + "/" + relative))
            #expect(check(report, "systemPolicy")?.status == .failed, "\(relative) must be protected")
            #expect(!report.canProceed)
        }
        // The home folder itself.
        let homeReport = await makeService(home: home.path).preflight(cleanupTarget(home.path))
        #expect(check(homeReport, "systemPolicy")?.status == .failed)
        // An ordinary cache folder deeper in Library is fine.
        try fm.createDirectory(atPath: home.path + "/Library/Caches/com.example.app", withIntermediateDirectories: true)
        let cache = await makeService(home: home.path).preflight(cleanupTarget(home.path + "/Library/Caches/com.example.app"))
        #expect(check(cache, "systemPolicy")?.status == .passed)
    }

    @Test func symlinkedPathComponentsThatLeaveTheHomeFail() async throws {
        let home = try ScratchDir("home"); defer { home.cleanup() }
        let elsewhere = try ScratchDir("elsewhere"); defer { elsewhere.cleanup() }
        let fm = FileManager.default
        let outsideDir = try makeTarget(elsewhere, name: "data")
        // home/link -> elsewhere/data ; target home/link/file.txt (parent component is a symlink out of home)
        #expect(symlink(outsideDir, home.path + "/link") == 0)
        let viaLink = home.path + "/link/file.txt"
        let report = await makeService(home: home.path).preflight(cleanupTarget(viaLink, isDirectory: false))
        #expect(check(report, "systemPolicy")?.status == .failed)
        #expect(!report.canProceed)

        // The target itself being a symlink that leaves the home also fails.
        #expect(symlink(outsideDir, home.path + "/direct") == 0)
        let direct = await makeService(home: home.path).preflight(cleanupTarget(home.path + "/direct"))
        #expect(check(direct, "systemPolicy")?.status == .failed)

        // A symlink that stays inside the permitted area is fine.
        let realDir = try makeTarget(home, name: "real")
        #expect(symlink(realDir, home.path + "/alias") == 0)
        let alias = await makeService(home: home.path).preflight(cleanupTarget(home.path + "/alias/file.txt", isDirectory: false))
        #expect(check(alias, "systemPolicy")?.status == .passed, "\(check(alias, "systemPolicy")?.detail ?? "")")

        // A symlink into protected data inside the home fails.
        try fm.createDirectory(atPath: home.path + "/Library/Mail/V10", withIntermediateDirectories: true)
        #expect(symlink(home.path + "/Library/Mail", home.path + "/sneaky") == 0)
        let sneaky = await makeService(home: home.path).preflight(cleanupTarget(home.path + "/sneaky/V10"))
        #expect(check(sneaky, "systemPolicy")?.status == .failed)
    }

    @Test func immutableFlagFailsOwnership() async throws {
        let home = try ScratchDir("home"); defer { home.cleanup() }
        let dir = try makeTarget(home)
        let service = makeService(home: home.path)
        #expect(check(await service.preflight(cleanupTarget(dir)), "ownership")?.status == .passed)

        #expect(chflags(dir, UInt32(UF_IMMUTABLE)) == 0)   // `chflags uchg`
        defer { _ = chflags(dir, 0) }
        let report = await service.preflight(cleanupTarget(dir))
        let ownership = try #require(check(report, "ownership"))
        #expect(ownership.status == .failed, "\(ownership)")
        #expect(!report.canProceed)
    }

    @Test func ownershipFlagMaskAndForeignOwner() {
        var st = stat()
        st.st_uid = getuid()
        #expect(SafeCleanupService.ownershipFailure(stat: st) == nil)
        for (name, flag) in [("SF_RESTRICTED", UInt32(0x80000)), ("SF_IMMUTABLE", 0x20000), ("UF_IMMUTABLE", 0x2),
                             ("SF_NOUNLINK", 0x100000), ("SF_FIRMLINK", 0x800000)] {
            st.st_flags = flag
            #expect(SafeCleanupService.ownershipFailure(stat: st) != nil, "\(name) must fail ownership")
            #expect(SafeCleanupService.ownershipCheck(stat: st).status == .failed)
        }
        st.st_flags = 0x8000   // UF_HIDDEN-like bits that are not locks
        #expect(SafeCleanupService.ownershipFailure(stat: st) == nil)
        st.st_flags = 0
        st.st_uid = getuid() &+ 1
        #expect(SafeCleanupService.ownershipFailure(stat: st) != nil)
        #expect(SafeCleanupService.ownershipCheck(stat: nil).status == .failed)
    }



    @Test func moveToTrashRechecksPolicyAndOwnershipAgainstForgedReports() async throws {
        let home = try ScratchDir("home"); defer { home.cleanup() }
        let elsewhere = try ScratchDir("elsewhere"); defer { elsewhere.cleanup() }
        let calls = LockedBox<[String]>([])
        let service = makeService(trashDir: home.path, trashed: calls, home: home.path)

        // Outside the home folder.
        let outside = try makeTarget(elsewhere)
        let outsideTarget = cleanupTarget(outside)
        var outcome = await service.moveToTrash(outsideTarget, report: forgedPassingReport(outsideTarget))
        #expect(!outcome.succeeded)

        // Protected data inside the home folder.
        try FileManager.default.createDirectory(atPath: home.path + "/Library/Mail/V10", withIntermediateDirectories: true)
        let protectedTarget = cleanupTarget(home.path + "/Library/Mail/V10")
        outcome = await service.moveToTrash(protectedTarget, report: forgedPassingReport(protectedTarget))
        #expect(!outcome.succeeded)

        // Locked item inside the home folder.
        let locked = try makeTarget(home, name: "locked")
        let lockedTarget = cleanupTarget(locked)
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(locked, 0) }
        outcome = await service.moveToTrash(lockedTarget, report: forgedPassingReport(lockedTarget))
        #expect(!outcome.succeeded)
        #expect(outcome.errorMessage?.contains("locked") == true, "\(outcome.errorMessage ?? "")")

        #expect(calls.value.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside))
        #expect(FileManager.default.fileExists(atPath: locked))
    }
}
