// ScannerDiagnostics.swift — KlaDScanner
//
// Cross-checks the getattrlistbulk(2) packing parser against lstat(2) for
// every entry of a directory. Used by `klad-probe verify` and the core tests.

import Darwin
import Foundation
import KlaDModels

public struct AttributeVerificationReport: Sendable, CustomStringConvertible {
    public struct Row: Sendable {
        public var name: String
        public var type: String
        public var logical: Int64
        public var allocated: Int64
        public var privateSize: Int64?
        public var cloneID: UInt64
        public var extFlags: UInt64
        public var bsdFlags: UInt32
        public var linkCount: UInt32
        public var mismatches: [String]
    }

    public var directory: String
    public var rows: [Row]
    public var privateSizeReturned: Int
    public var mismatchCount: Int { rows.reduce(0) { $0 + $1.mismatches.count } }

    public var description: String {
        var lines = ["getattrlistbulk ⇄ lstat verification for \(directory)",
                     "entries: \(rows.count)  mismatches: \(mismatchCount)  PRIVATESIZE returned: \(privateSizeReturned)"]
        for row in rows {
            let priv = row.privateSize.map(String.init) ?? "—"
            let ext = String(row.extFlags, radix: 16)
            let flags = String(row.bsdFlags, radix: 16)
            var line = "  \(row.type.padding(toLength: 4, withPad: " ", startingAt: 0)) "
            line += "logical=\(row.logical) alloc=\(row.allocated) private=\(priv) clone=\(row.cloneID) "
            line += "ext=0x\(ext) flags=0x\(flags) links=\(row.linkCount)  \(row.name)"
            if !row.mismatches.isEmpty { line += "   ✗ " + row.mismatches.joined(separator: "; ") }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

public enum ScannerDiagnostics {
    /// Reads `directory` with the production parser and compares each entry with lstat.
    public static func verifyAttributePacking(directory: String) -> AttributeVerificationReport {
        var reader = BulkDirectoryReader(requestPrivateSize: true)
        defer { reader.deallocate() }
        var rows: [AttributeVerificationReport.Row] = []
        var privateReturned = 0
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        _ = reader.read(path: directory, isCancelled: { false }) { entry in
            let name = entry.name
            var st = stat()
            var mismatches: [String] = []
            if lstat(prefix + name, &st) != 0 {
                mismatches.append("lstat failed: \(String(cString: strerror(errno)))")
            } else {
                if UInt64(st.st_ino) != entry.fileID { mismatches.append("inode \(st.st_ino)≠\(entry.fileID)") }
                if st.st_dev != entry.deviceID { mismatches.append("dev \(st.st_dev)≠\(entry.deviceID)") }
                if st.st_flags != entry.bsdFlags { mismatches.append("flags 0x\(String(st.st_flags, radix: 16))≠0x\(String(entry.bsdFlags, radix: 16))") }
                if Int64(st.st_mtimespec.tv_sec) != entry.modificationTime { mismatches.append("mtime \(st.st_mtimespec.tv_sec)≠\(entry.modificationTime)") }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                if isDir != entry.isDirectory { mismatches.append("type") }
                if !isDir {
                    if Int64(st.st_size) != entry.totalSize { mismatches.append("size \(st.st_size)≠\(entry.totalSize)") }
                    if Int64(st.st_blocks) * 512 != entry.allocSize { mismatches.append("alloc \(Int64(st.st_blocks) * 512)≠\(entry.allocSize)") }
                    if UInt32(st.st_nlink) != entry.linkCount { mismatches.append("nlink \(st.st_nlink)≠\(entry.linkCount)") }
                }
            }
            if entry.hasPrivateSize { privateReturned += 1 }
            let type: String
            switch VType(rawValue: entry.objectType) {
            case .vreg: type = "file"
            case .vdir: type = "dir"
            case .vlnk: type = "link"
            default: type = "obj\(entry.objectType)"
            }
            rows.append(.init(
                name: name, type: type, logical: entry.totalSize, allocated: entry.allocSize,
                privateSize: entry.hasPrivateSize ? entry.privateSize : nil, cloneID: entry.cloneID,
                extFlags: entry.extFlags, bsdFlags: entry.bsdFlags, linkCount: entry.linkCount, mismatches: mismatches
            ))
        }
        rows.sort { $0.name < $1.name }
        return AttributeVerificationReport(directory: directory, rows: rows, privateSizeReturned: privateReturned)
    }
}
