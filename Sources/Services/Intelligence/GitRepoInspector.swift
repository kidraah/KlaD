// GitRepoInspector.swift — KlaDIntelligence
//
// Read-only git facts for a path: working-tree cleanliness, branch, last commit.
//   • git runs via Foundation.Process (never a shell) with GIT_OPTIONAL_LOCKS=0,
//     core.fsmonitor disabled and a hard timeout per call (terminate, then SIGKILL);
//   • stdout is drained on a background queue so a full pipe can never hang us;
//   • paths inside iCloud / File Provider trees are skipped — git could read
//     dataless files and force a download;
//   • results (including failures) are cached per repository root for 60 s and
//     concurrent lookups of the same root share one in-flight task.

import Foundation
import KlaDModels

public actor GitRepoInspector: GitRepositoryInspecting {
    private let gitExecutable: String
    private let timeout: TimeInterval
    private let cacheTTL: TimeInterval

    private struct CacheEntry {
        let status: GitRepositoryStatus?
        let storedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<GitRepositoryStatus?, Never>] = [:]

    public init(gitExecutable: String = "/usr/bin/git", timeout: TimeInterval = 3, cacheTTL: TimeInterval = 60) {
        self.gitExecutable = gitExecutable
        self.timeout = timeout
        self.cacheTTL = cacheTTL
    }

    // MARK: - GitRepositoryInspecting

    public func status(forPath path: String) async -> GitRepositoryStatus? {
        guard case .repository(_, let status) = await lookup(path) else { return nil }
        return status
    }

    public func supportingSignals(forPath path: String, now: Date) async -> [SupportingSignal] {
        switch await lookup(path) {
        case .skipped: return []
        case .notRepository: return [.notGitRepository]
        case .repository(_, let status):
            guard let status else { return [] }   // timeout / git error
            var signals: [SupportingSignal] = []
            if status.isClean {
                signals.append(.gitClean)
            } else {
                signals.append(.gitUncommittedChanges(count: status.changedCount + status.untrackedCount))
            }
            if let date = status.lastCommitDate {
                let days = max(0, Int((now.timeIntervalSince(date) / 86_400).rounded(.down)))
                signals.append(.gitLastCommit(daysAgo: days))
            }
            return signals
        }
    }

    // MARK: - Lookup

    private enum Lookup {
        case skipped
        case notRepository
        case repository(root: String, status: GitRepositoryStatus?)
    }

    private func lookup(_ path: String) async -> Lookup {
        if Self.isCloudManaged(path) { return .skipped }
        guard let root = Self.findRepositoryRoot(from: path) else { return .notRepository }

        if let entry = cache[root], Date().timeIntervalSince(entry.storedAt) < cacheTTL {
            return .repository(root: root, status: entry.status)
        }
        if let task = inFlight[root] {
            return .repository(root: root, status: await task.value)
        }

        let executable = gitExecutable
        let limit = timeout
        let task = Task<GitRepositoryStatus?, Never> {
            await Self.readStatus(root: root, git: executable, timeout: limit)
        }
        inFlight[root] = task
        let status = await task.value
        inFlight[root] = nil
        cache[root] = CacheEntry(status: status, storedAt: Date())
        return .repository(root: root, status: status)
    }

    // MARK: - Repository discovery (FileManager.fileExists only)

    private static func isCloudManaged(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        for sub in ["/Library/Mobile Documents", "/Library/CloudStorage"] {
            let prefix = home + sub
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        // Also catch the same locations reached through another spelling (symlinks).
        if path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/") { return true }
        return false
    }

    private static func findRepositoryRoot(from path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let homeParent = (NSHomeDirectory() as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var directory = path
        while true {
            if fm.fileExists(atPath: directory + "/.git") { return directory }
            if directory == "/" || directory == homeParent || directory.isEmpty { return nil }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { return nil }
            directory = parent.isEmpty ? "/" : parent
        }
    }

    // MARK: - Running git

    private static func readStatus(root: String, git: String, timeout: TimeInterval) async -> GitRepositoryStatus? {
        async let porcelain = runGit(git, ["-C", root, "-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z", "--untracked-files=normal"], timeout: timeout)
        async let branch = runGit(git, ["-C", root, "-c", "core.fsmonitor=false", "rev-parse", "--abbrev-ref", "HEAD"], timeout: timeout)
        async let lastCommit = runGit(git, ["-C", root, "-c", "core.fsmonitor=false", "log", "-1", "--format=%ct"], timeout: timeout)
        let (statusResult, branchResult, commitResult) = await (porcelain, branch, lastCommit)

        guard case .output(let statusData) = statusResult else { return nil }
        if case .timedOut = branchResult { return nil }
        if case .timedOut = commitResult { return nil }

        let counts = parsePorcelain(statusData)

        var branchName: String?
        if case .output(let data) = branchResult,
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, text != "HEAD" {
            branchName = text
        }

        var lastCommitDate: Date?
        if case .output(let data) = commitResult,
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = TimeInterval(text) {
            lastCommitDate = Date(timeIntervalSince1970: seconds)
        }

        return GitRepositoryStatus(
            repositoryRoot: root,
            branch: branchName,
            isClean: counts.changed == 0 && counts.untracked == 0,
            changedCount: counts.changed,
            untrackedCount: counts.untracked,
            lastCommitDate: lastCommitDate
        )
    }

    /// Parses `git status --porcelain=v1 -z`: NUL-separated `XY path` entries; rename/copy
    /// entries are followed by one extra NUL-separated field (the original path).
    static func parsePorcelain(_ data: Data) -> (changed: Int, untracked: Int) {
        var changed = 0
        var untracked = 0
        let bytes = [UInt8](data)
        var start = 0
        var skipNext = false
        for index in 0...bytes.count {
            guard index == bytes.count || bytes[index] == 0 else { continue }
            defer { start = index + 1 }
            guard index > start else { continue }
            if skipNext { skipNext = false; continue }
            let entry = bytes[start..<index]
            guard entry.count >= 3 else { continue }
            let x = entry[entry.startIndex]
            let y = entry[entry.startIndex + 1]
            if x == UInt8(ascii: "?") && y == UInt8(ascii: "?") {
                untracked += 1
            } else if x == UInt8(ascii: "!") && y == UInt8(ascii: "!") {
                continue
            } else {
                changed += 1
                if x == UInt8(ascii: "R") || x == UInt8(ascii: "C") || y == UInt8(ascii: "R") || y == UInt8(ascii: "C") {
                    skipNext = true
                }
            }
        }
        return (changed, untracked)
    }

    private enum GitResult {
        case output(Data)
        case failed
        case timedOut
    }

    private static func runGit(_ git: String, _ arguments: [String], timeout: TimeInterval) async -> GitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runGitBlocking(git, arguments, timeout: timeout))
            }
        }
    }

    /// Collects pipe output from a background thread.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func set(_ data: Data) { lock.lock(); buffer = data; lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    private static func runGitBlocking(_ git: String, _ arguments: [String], timeout: TimeInterval) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do { try process.run() } catch { return .failed }

        // Drain stdout concurrently so a chatty git can never block on a full pipe.
        let collector = OutputCollector()
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            collector.set(reader.readDataToEndOfFile())
            drained.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            // The killed process closes the pipe, so the reader thread ends on its own.
            return .timedOut
        }

        // Process is gone; the pipe normally hits EOF immediately. Don't wait forever if a
        // grandchild inherited the write end (the reader thread then finishes whenever it does).
        _ = drained.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0 else { return .failed }
        return .output(collector.data)
    }
}
