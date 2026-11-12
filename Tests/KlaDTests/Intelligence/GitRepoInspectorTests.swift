// GitRepoInspectorTests.swift
// Temp directories only; every fixture is removed afterwards.
import Testing
import Foundation
@testable import KlaDIntelligence
import KlaDModels

private struct TempDir {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("klad-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve symlinks (/var → /private/var) so paths compare equal to what we pass in.
        url = base.resolvingSymlinksInPath()
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func write(_ name: String, _ text: String = "hello\n") throws {
        try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

@discardableResult
private func git(_ dir: TempDir, _ args: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", dir.path, "-c", "user.email=a@b", "-c", "user.name=t", "-c", "init.defaultBranch=main",
                         "-c", "commit.gpgsign=false"] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private func makeRepo() throws -> TempDir {
    let dir = try TempDir()
    try git(dir, "init", "-q")
    try dir.write("a.txt")
    try dir.write("b.txt")
    try git(dir, "add", ".")
    try git(dir, "commit", "-q", "-m", "init")
    return dir
}

@Suite("GitRepoInspector")
struct GitRepoInspectorTests {
    @Test func cleanRepo() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        let inspector = GitRepoInspector()
        let status = try #require(await inspector.status(forPath: dir.path))
        #expect(status.isClean)
        #expect(status.changedCount == 0 && status.untrackedCount == 0)
        #expect(status.branch == "main")
        #expect(status.repositoryRoot == dir.path)
        let commit = try #require(status.lastCommitDate)
        #expect(abs(commit.timeIntervalSinceNow) < 120)

        let signals = await inspector.supportingSignals(forPath: dir.path, now: Date())
        #expect(signals == [.gitClean, .gitLastCommit(daysAgo: 0)])
    }

    @Test func subdirectoryResolvesToTheRepoRoot() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        let sub = dir.url.appendingPathComponent("deep/er", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let status = try #require(await GitRepoInspector().status(forPath: sub.path))
        #expect(status.repositoryRoot == dir.path)
    }

    @Test func modifiedAndUntrackedFiles() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        try dir.write("a.txt", "changed\n")
        try dir.write("new.txt")
        try dir.write("new2.txt")
        let inspector = GitRepoInspector()
        let status = try #require(await inspector.status(forPath: dir.path))
        #expect(!status.isClean)
        #expect(status.changedCount == 1)
        #expect(status.untrackedCount == 2)
        let signals = await inspector.supportingSignals(forPath: dir.path, now: Date())
        #expect(signals.first == .gitUncommittedChanges(count: 3))
    }

    @Test func untrackedOnly() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        try dir.write("scratch.txt")
        let status = try #require(await GitRepoInspector().status(forPath: dir.path))
        #expect(!status.isClean)
        #expect(status.changedCount == 0)
        #expect(status.untrackedCount == 1)
    }

    @Test func stagedRenameCountsOnce() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        try git(dir, "mv", "a.txt", "renamed.txt")
        let status = try #require(await GitRepoInspector().status(forPath: dir.path))
        #expect(status.changedCount == 1)
        #expect(status.untrackedCount == 0)
    }

    @Test func porcelainParser() {
        let data = Data("R  new.txt\0old.txt\0 M mod.txt\0?? u1\0?? u2\0A  added\0!! ignored\0".utf8)
        let counts = GitRepoInspector.parsePorcelain(data)
        #expect(counts.changed == 3)
        #expect(counts.untracked == 2)
        #expect(GitRepoInspector.parsePorcelain(Data()).changed == 0)
    }

    @Test func lastCommitAge() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        let inspector = GitRepoInspector()
        let signals = await inspector.supportingSignals(forPath: dir.path, now: Date().addingTimeInterval(10 * 86_400 + 60))
        #expect(signals.contains(.gitLastCommit(daysAgo: 10)))
    }

    @Test func repoWithoutCommits() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        try git(dir, "init", "-q")
        try dir.write("x.txt")
        let status = try #require(await GitRepoInspector().status(forPath: dir.path))
        #expect(status.untrackedCount == 1)
        #expect(status.lastCommitDate == nil)
    }

    @Test func nonRepoIsNotAGitRepository() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        try dir.write("x.txt")
        let inspector = GitRepoInspector()
        #expect(await inspector.status(forPath: dir.path) == nil)
        #expect(await inspector.supportingSignals(forPath: dir.path, now: Date()) == [.notGitRepository])
    }

    @Test func worktreeStyleGitFileIsRecognised() async throws {
        let repo = try makeRepo()
        let other = try TempDir()
        defer { repo.remove(); other.remove() }
        try git(repo, "worktree", "add", "-q", "\(other.path)/wt", "-b", "feature")
        let status = try #require(await GitRepoInspector().status(forPath: "\(other.path)/wt"))
        #expect(status.repositoryRoot == "\(other.path)/wt")
        #expect(status.branch == "feature")
    }

    @Test func cloudManagedPathsAreSkipped() async {
        let inspector = GitRepoInspector()
        let icloud = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/project"
        let cloud = NSHomeDirectory() + "/Library/CloudStorage/Dropbox/project"
        #expect(await inspector.status(forPath: icloud) == nil)
        #expect(await inspector.supportingSignals(forPath: icloud, now: Date()).isEmpty)
        #expect(await inspector.supportingSignals(forPath: cloud, now: Date()).isEmpty)
    }

    @Test func resultsAreCachedPerRepositoryRoot() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        let cached = GitRepoInspector()
        #expect(try #require(await cached.status(forPath: dir.path)).isClean)
        try dir.write("late.txt")
        #expect(try #require(await cached.status(forPath: dir.path)).isClean)   // still the cached answer

        let uncached = GitRepoInspector(cacheTTL: 0)
        #expect(try #require(await uncached.status(forPath: dir.path)).untrackedCount == 1)
    }

    @Test func concurrentCallsAreSafe() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        let inspector = GitRepoInspector()
        let path = dir.path
        let results = await withTaskGroup(of: GitRepositoryStatus?.self) { group in
            for _ in 0..<12 { group.addTask { await inspector.status(forPath: path) } }
            var all: [GitRepositoryStatus?] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 12)
        #expect(results.allSatisfy { $0?.isClean == true })
    }

    @Test func hangingGitIsKilledAtTheTimeout() async throws {
        let dir = try makeRepo()
        let script = try TempDir()
        defer { dir.remove(); script.remove() }
        let fake = script.url.appendingPathComponent("slow-git")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let inspector = GitRepoInspector(gitExecutable: fake.path, timeout: 0.5)
        let start = Date()
        let status = await inspector.status(forPath: dir.path)
        let elapsed = Date().timeIntervalSince(start)
        #expect(status == nil)
        #expect(elapsed < 5)
        #expect(await inspector.supportingSignals(forPath: dir.path, now: Date()).isEmpty)
    }

    @Test func missingGitExecutableYieldsNil() async throws {
        let dir = try makeRepo()
        defer { dir.remove() }
        let inspector = GitRepoInspector(gitExecutable: "/nonexistent/git")
        #expect(await inspector.status(forPath: dir.path) == nil)
        #expect(await inspector.supportingSignals(forPath: dir.path, now: Date()).isEmpty)
    }
}
