// TestSupport.swift — shared helpers for the StorageOps tests.
import Darwin
import Foundation
import KlaDModels

/// A unique scratch directory under the system temp dir; removed on `cleanup()`.
struct ScratchDir {
    let url: URL
    var path: String { url.path }

    init(_ label: String = "ops") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("klad-storageops-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        // Restore permissions so chmod 000 fixtures can be removed.
        if let items = FileManager.default.enumerator(atPath: path) {
            for case let rel as String in items { _ = chmod(path + "/" + rel, 0o700) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String, bytes: Data) throws -> String {
        let p = path + "/" + name
        try bytes.write(to: URL(fileURLWithPath: p))
        return p
    }
}

func randomData(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
    return data
}

func lstatInfo(_ path: String) -> stat {
    var st = stat()
    precondition(lstat(path, &st) == 0, "lstat failed for \(path)")
    return st
}

func setModificationTime(_ path: String, seconds: Int) {
    var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
    utimes(path, &times)
}

func candidate(_ path: String, flags: NodeFlags = [], cloneID: UInt64 = 0) -> DuplicateCandidate {
    let st = lstatInfo(path)
    let allocated = UInt64(st.st_blocks) * 512
    return DuplicateCandidate(
        path: path, logicalBytes: UInt64(st.st_size), allocatedBytes: allocated, privateBytes: allocated,
        flags: flags, fileID: UInt64(st.st_ino), deviceID: st.st_dev, cloneID: cloneID,
        modificationTime: Int64(st.st_mtimespec.tv_sec))
}

func cleanupTarget(
    _ path: String, safety: SafetyLevel = .safeToClear, isDirectory: Bool = true,
    conflicting: [String] = []
) -> CleanupTarget {
    let st = lstatInfo(path)
    return CleanupTarget(
        path: path, displayName: (path as NSString).lastPathComponent, safety: safety,
        identity: NodeIdentity(fileID: UInt64(st.st_ino), deviceID: st.st_dev, modificationTime: Int64(st.st_mtimespec.tv_sec)),
        metrics: StorageMetrics(logicalBytes: 1000, allocatedBytes: 4096, privateBytes: 2048, fileCount: 1),
        conflictingApplicationBundleIDs: conflicting, isDirectory: isDirectory)
}
