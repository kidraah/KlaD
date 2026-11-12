// SafeCleanupService.swift — KlaDStorageOps
//
// Pre-flight checks + Trash-only removal. The only deletion primitive here is the
// injected `trashItem` closure (default: FileManager.trashItem). Nothing in this
// file calls removeItem / unlink / rm.

import AppKit
import Darwin
import Foundation
import KlaDModels

public final class SafeCleanupService: SafeCleanupPerforming {
    private let runningApplicationBundleIDs: (@Sendable () async -> Set<String>)?
    private let trashItem: @Sendable (URL) throws -> URL?

    /// Wall-clock budget for the open-file scan.
    static let openFileBudget: TimeInterval = 0.5

    public init(
        runningApplicationBundleIDs: (@Sendable () async -> Set<String>)? = nil,
        trashItem: (@Sendable (URL) throws -> URL?)? = nil
    ) {
        self.runningApplicationBundleIDs = runningApplicationBundleIDs
        self.trashItem = trashItem ?? Self.defaultTrashItem
    }

    private static let defaultTrashItem: @Sendable (URL) throws -> URL? = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    // MARK: - Pre-flight

    public func preflight(_ target: CleanupTarget) async -> PreflightReport {
        var checks: [PreflightCheck] = []

        // 1. exists
        var st = stat()
        let existsErrno: Int32? = lstat(target.path, &st) == 0 ? nil : errno
        if let code = existsErrno {
            checks.append(PreflightCheck(id: "exists", title: "Item still exists", status: .failed,
                                         detail: "Item no longer exists (\(String(cString: strerror(code))))."))
        } else {
            checks.append(PreflightCheck(id: "exists", title: "Item still exists", status: .passed,
                                         detail: "Item is present on disk."))
        }

        // 2. identity
        if existsErrno != nil {
            checks.append(PreflightCheck(id: "identity", title: "Same item as scanned", status: .failed,
                                         detail: "Cannot verify identity: item is missing."))
        } else if UInt64(st.st_ino) != target.identity.fileID || st.st_dev != target.identity.deviceID {
            checks.append(PreflightCheck(id: "identity", title: "Same item as scanned", status: .failed,
                                         detail: "The item at this path is no longer the one that was scanned (it was replaced)."))
        } else if Int64(st.st_mtimespec.tv_sec) != target.identity.modificationTime {
            checks.append(PreflightCheck(id: "identity", title: "Same item as scanned", status: .warning,
                                         detail: "Modified since the scan."))
        } else {
            checks.append(PreflightCheck(id: "identity", title: "Same item as scanned", status: .passed,
                                         detail: "File ID, device and modification time match the scan."))
        }

        // 3. safety
        if target.safety.permitsTrash {
            checks.append(PreflightCheck(id: "safety", title: "Safety tier permits Trash", status: .passed,
                                         detail: "Safety tier “\(target.safety.displayName)” permits moving to Trash."))
        } else {
            checks.append(PreflightCheck(id: "safety", title: "Safety tier permits Trash", status: .failed,
                                         detail: "Safety tier “\(target.safety.displayName)” never permits Trash."))
        }

        // 4. protected path
        checks.append(Self.protectedPathCheck(for: target.path, exists: existsErrno == nil))

        // 5. running apps
        checks.append(await runningAppsCheck(for: target))

        // 6. open files
        var usage: [ProcessUsage] = []
        if existsErrno != nil {
            checks.append(PreflightCheck(id: "openFiles", title: "No open files inside", status: .skipped,
                                         detail: "Skipped: item is missing."))
        } else {
            let scan = await Self.scanOpenFiles(path: target.path, budget: Self.openFileBudget)
            usage = scan.processes
            if !scan.processes.isEmpty {
                let names = scan.processes.prefix(5).map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
                let more = scan.processes.count > 5 ? " and \(scan.processes.count - 5) more" : ""
                let partial = scan.timedOut ? " (scan timed out; list may be incomplete)" : ""
                checks.append(PreflightCheck(id: "openFiles", title: "No open files inside", status: .warning,
                                             detail: "In use by \(names)\(more)\(partial)."))
            } else if scan.timedOut {
                checks.append(PreflightCheck(id: "openFiles", title: "No open files inside", status: .skipped,
                                             detail: "Open-file check timed out"))
            } else {
                checks.append(PreflightCheck(id: "openFiles", title: "No open files inside", status: .passed,
                                             detail: "No process has files open inside this item."))
            }
        }

        return PreflightReport(target: target, checks: checks, processesUsingTarget: usage, checkedAt: Date())
    }

    private func runningAppsCheck(for target: CleanupTarget) async -> PreflightCheck {
        let title = "Related apps are closed"
        guard !target.conflictingApplicationBundleIDs.isEmpty else {
            return PreflightCheck(id: "runningApps", title: title, status: .passed,
                                  detail: "No related applications to check.")
        }
        let running: Set<String>
        if let provider = runningApplicationBundleIDs {
            running = await provider()
        } else {
            running = await MainActor.run {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            }
        }
        let open = target.conflictingApplicationBundleIDs.filter { running.contains($0) }
        if open.isEmpty {
            return PreflightCheck(id: "runningApps", title: title, status: .passed,
                                  detail: "None of \(target.conflictingApplicationBundleIDs.joined(separator: ", ")) is running.")
        }
        return PreflightCheck(id: "runningApps", title: title, status: .warning,
                              detail: "Still running: \(open.joined(separator: ", ")). Quit it first to avoid corrupting its data.")
    }

    // MARK: - Protected paths

    static func protectedPathCheck(for path: String, exists: Bool) -> PreflightCheck {
        let title = "Not a protected location"
        if let reason = protectedReason(for: path, exists: exists) {
            return PreflightCheck(id: "protectedPath", title: title, status: .failed, detail: reason)
        }
        return PreflightCheck(id: "protectedPath", title: title, status: .passed,
                              detail: "Not a system, home or volume root location.")
    }

    private static let protectedTopLevel: Set<String> = [
        "/", "/System", "/Users", "/Applications", "/Library", "/private", "/usr", "/bin", "/sbin",
        "/Volumes", "/etc", "/var", "/opt", "/cores", "/dev", "/tmp", "/private/var", "/private/etc", "/private/tmp",
    ]
    /// Directly below a home directory.
    private static let protectedHomeChildren: Set<String> = [
        "Library", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
    ]

    private static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func realHome() -> String? {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return nil
    }

    /// Returns a human-readable reason when `path` must never be trashed, else nil.
    static func protectedReason(for rawPath: String, exists: Bool) -> String? {
        let lexical = normalize(rawPath)
        var candidates = [lexical]
        var isSymlink = false
        var st = stat()
        if lstat(lexical, &st) == 0 {
            isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
            // For a symlink only the link itself moves, so resolve its parent only.
            let url = URL(fileURLWithPath: lexical)
            let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            let resolved = (resolvedParent == "/" ? "" : resolvedParent) + "/" + url.lastPathComponent
            candidates.append(lexical == "/" ? "/" : normalize(resolved))
            if !isSymlink, let real = realpath(lexical, nil) {
                candidates.append(String(cString: real))
                free(real)
            }
        }

        var homes = Set([normalize(NSHomeDirectory())])
        if let home = realHome() { homes.insert(normalize(home)) }
        homes.insert(normalize(FileManager.default.homeDirectoryForCurrentUser.path))

        for path in Set(candidates) {
            if protectedTopLevel.contains(path) { return "“\(path)” is a protected system location." }
            if path == "/usr" || path.hasPrefix("/usr/"), !(path == "/usr/local" || path.hasPrefix("/usr/local/")) {
                return "“\(path)” is inside protected /usr."
            }
            for prefix in ["/System/", "/bin/", "/sbin/"] where path.hasPrefix(prefix) {
                return "“\(path)” is inside a protected system location."
            }
            for home in homes {
                if path == home { return "The home directory is protected." }
                for child in protectedHomeChildren where path == home + "/" + child {
                    return "~/\(child) is a protected location."
                }
            }
            // Any user's home or well-known folder under /Users/<name>.
            let parts = path.split(separator: "/").map(String.init)
            if parts.count == 2, parts[0] == "Users" { return "A user home directory is protected." }
            if parts.count == 3, parts[0] == "Users", protectedHomeChildren.contains(parts[2]) {
                return "/Users/\(parts[1])/\(parts[2]) is a protected location."
            }
        }

        // Mount points / volume roots (never for symlinks: only the link would move).
        if exists, !isSymlink {
            var fs = statfs()
            if statfs(lexical, &fs) == 0 {
                let mountPoint = withUnsafePointer(to: &fs.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                for path in Set(candidates) where mountPoint == path {
                    return "“\(path)” is a mount point / volume root."
                }
            }
            // Device differs from the parent directory ⇒ something is mounted here.
            var parent = stat()
            let parentPath = URL(fileURLWithPath: lexical).deletingLastPathComponent().path
            if lexical != "/", lstat(lexical, &st) == 0, lstat(parentPath, &parent) == 0, st.st_dev != parent.st_dev {
                return "“\(lexical)” is on a different volume than its parent (mount point)."
            }
        }
        return nil
    }

    // MARK: - Open-file scan (libproc)

    struct OpenFileScan: Sendable {
        var processes: [ProcessUsage]
        var timedOut: Bool
    }

    private static func scanOpenFiles(path: String, budget: TimeInterval) async -> OpenFileScan {
        await withCheckedContinuation { (continuation: CheckedContinuation<OpenFileScan, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanOpenFilesSync(path: path, budget: budget))
            }
        }
    }

    private static func scanOpenFilesSync(path: String, budget: TimeInterval) -> OpenFileScan {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(budget * 1_000_000_000)
        func expired() -> Bool { DispatchTime.now().uptimeNanoseconds >= deadline }

        // Prefixes to match: the path as given and its kernel-resolved form (/var → /private/var).
        var roots = Set([normalize(path)])
        let url = URL(fileURLWithPath: normalize(path))
        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        roots.insert(normalize((resolvedParent == "/" ? "" : resolvedParent) + "/" + url.lastPathComponent))
        if let real = realpath(url.path, nil) { roots.insert(String(cString: real)); free(real) }

        func matches(_ candidate: String) -> Bool {
            for root in roots where candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/") { return true }
            return false
        }

        let capacityHint = Int(proc_listallpids(nil, 0))
        guard capacityHint > 0 else { return OpenFileScan(processes: [], timedOut: false) }
        let capacity = capacityHint * 2 + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let listed = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard listed > 0 else { return OpenFileScan(processes: [], timedOut: false) }
        var ordered = Array(pids.prefix(min(listed, capacity))).filter { $0 > 0 }
        // Our own process first: cheapest, always inspectable.
        let me = getpid()
        if let index = ordered.firstIndex(of: me) { ordered.swapAt(0, index) }

        var found: [ProcessUsage] = []
        var timedOut = false
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride

        pidLoop: for pid in ordered {
            if expired() { timedOut = true; break }
            var example: String?

            // Current working directory.
            var vpi = proc_vnodepathinfo()
            let vpiSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, vpiSize) == vpiSize {
                let cwd = cString(&vpi.pvi_cdir.vip_path)
                if !cwd.isEmpty, matches(cwd) { example = cwd }
            }

            // Open file descriptors.
            if example == nil {
                let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
                if needed > 0 {
                    let count = Int(needed) / fdInfoSize + 8
                    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
                    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(count * fdInfoSize))
                    if got > 0 {
                        for fd in fds.prefix(Int(got) / fdInfoSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                            if expired() { timedOut = true; break pidLoop }
                            var info = vnode_fdinfowithpath()
                            let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
                            let opened = cString(&info.pvip.vip_path)
                            if !opened.isEmpty, matches(opened) { example = opened; break }
                        }
                    }
                }
            }

            if let example {
                var name = [CChar](repeating: 0, count: 256)
                let length = proc_name(pid, &name, UInt32(name.count))
                found.append(ProcessUsage(pid: pid, name: length > 0 ? String(decoding: name.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "pid \(pid)", examplePath: example))
            }
        }
        return OpenFileScan(processes: found, timedOut: timedOut)
    }

    /// Reads a fixed-size C char tuple (e.g. `vip_path`) as a String.
    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    // MARK: - Move to Trash

    public func moveToTrash(_ target: CleanupTarget, report: PreflightReport) async -> CleanupOutcome {
        func refuse(_ message: String) -> CleanupOutcome {
            CleanupOutcome(target: target, succeeded: false, trashedPath: nil, reclaimedPrivateBytes: 0,
                           movedAllocatedBytes: 0, errorMessage: message)
        }
        guard report.target == target else { return refuse("The pre-flight report belongs to a different item.") }
        guard report.canProceed else {
            let failed = report.checks.filter { $0.status == .failed }.map(\.title).joined(separator: ", ")
            return refuse("Pre-flight did not pass (\(failed)).")
        }
        guard target.safety.permitsTrash else {
            return refuse("Safety tier “\(target.safety.displayName)” does not permit moving to Trash.")
        }
        // Independent of the (caller-supplied) report: never trash a protected location.
        if let reason = Self.protectedReason(for: target.path, exists: true) { return refuse(reason) }

        // TOCTOU guard: re-verify identity immediately before the move.
        var st = stat()
        guard lstat(target.path, &st) == 0 else { return refuse("The item no longer exists.") }
        guard UInt64(st.st_ino) == target.identity.fileID, st.st_dev == target.identity.deviceID else {
            return refuse("The item was replaced after pre-flight; refusing to move it.")
        }

        do {
            let trashed = try trashItem(URL(fileURLWithPath: target.path))
            return CleanupOutcome(
                target: target, succeeded: true, trashedPath: trashed?.path,
                reclaimedPrivateBytes: target.metrics.privateBytes,
                movedAllocatedBytes: target.metrics.allocatedBytes, errorMessage: nil)
        } catch {
            return refuse("Could not move to Trash: \(error.localizedDescription)")
        }
    }
}
