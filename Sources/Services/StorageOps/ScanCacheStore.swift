// ScanCacheStore.swift — KlaDStorageOps
//
// Instant reopen: persists a scanned tree so the app can show it immediately and
// replay FSEvents history to find what changed since.
//
// Files, per scan root (hash = hex SHA-256 of the root path):
//   <hash>.kladscan   binary tree, LZFSE-compressed body
//   <hash>.json       `ScanCacheMeta` sidecar (cheap to list)
// Both are written atomically (temp file + rename).
//
// .kladscan layout (little-endian, explicit):
//   "KLAD"            4 bytes magic
//   UInt16            format version (1)
//   UInt64            node count
//   UInt64            raw (uncompressed) body length      ┐ guards: allocation is bounded by these,
//   UInt64            compressed body length              │ truncation / trailing bytes / any
//   UInt64            first 8 bytes of SHA-256(raw body)  ┘ corruption is caught before decoding
//   body              LZFSE( node × nodeCount ), pre-order:
//     UInt8 kind · UInt32 flags · UInt64 fileID · Int32 deviceID · Int64 mtime ·
//     UInt64 cloneID · Int32 errorCode · UInt16 nameLength + UTF-8 bytes · UInt32 childCount
//     and, for files / symlinks / other: UInt64 logical, allocated, private, cloud
//
// Decoding never recurses (trees are deep), never trusts a length or count, and
// throws a typed `ScanCacheError` for anything malformed.
//
// This store deletes only its OWN cache files (names derived from a hash inside
// its own directory) — never user data.

import Compression
import CryptoKit
import Foundation
import KlaDModels

public enum ScanCacheError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The cache file is malformed (bad magic, lengths, counts, checksum, …).
    case corrupt(String)
    /// Written by a newer (or unknown) format version.
    case unsupportedVersion(UInt16)
    /// A name longer than the format allows (1024 UTF-8 bytes).
    case nameTooLong(String)

    public var description: String {
        switch self {
        case let .corrupt(reason): return "Scan cache is corrupt: \(reason)"
        case let .unsupportedVersion(version): return "Scan cache format v\(version) is not supported"
        case let .nameTooLong(name): return "Name too long to cache: \(name.prefix(40))…"
        }
    }

    public var errorDescription: String? { description }
}

public actor ScanCacheStore: ScanCaching {
    private let directory: URL

    static let magic: [UInt8] = Array("KLAD".utf8)
    static let formatVersion: UInt16 = 1
    static let headerSize = 4 + 2 + 8 + 8 + 8 + 8
    static let maxNameLength = 1024
    /// Smallest possible encoded node (directory with a 0-byte name).
    static let minimumNodeSize = 1 + 4 + 8 + 4 + 8 + 8 + 4 + 2 + 4
    static let fileMetricsSize = 32
    /// Hard ceiling on the decompressed body (a 2.5 M-node tree is ~200 MB).
    static let maxRawLength: UInt64 = 8 << 30
    /// LZFSE cannot plausibly expand this far; anything beyond is a corrupt length.
    static let maxExpansion: UInt64 = 8192

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    /// `~/Library/Caches/KlaD/Scans`
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("KlaD", isDirectory: true).appendingPathComponent("Scans", isDirectory: true)
    }

    // MARK: File naming

    static func hash(of rootPath: String) -> String {
        hex(SHA256.hash(data: Data(rootPath.utf8)))
    }

    private func scanURL(_ rootPath: String) -> URL {
        directory.appendingPathComponent(Self.hash(of: rootPath) + ".kladscan")
    }

    private func metaURL(_ rootPath: String) -> URL {
        directory.appendingPathComponent(Self.hash(of: rootPath) + ".json")
    }

    // MARK: ScanCaching

    public func save(_ root: FileTreeNode, meta: ScanCacheMeta) async throws {
        let (raw, count) = try Self.encode(root)
        let digest = Self.checksum(raw)
        let compressed = try Self.compress(raw)

        var file = ByteWriter(capacity: Self.headerSize + compressed.count)
        file.bytes.append(contentsOf: Self.magic)
        file.u16(Self.formatVersion)
        file.u64(count)
        file.u64(UInt64(raw.count))
        file.u64(UInt64(compressed.count))
        file.u64(digest)
        file.bytes.append(contentsOf: compressed)

        var stored = meta
        stored.rootPath = root.name
        stored.nodeCount = Int(count)
        let sidecar = try JSONEncoder().encode(stored)

        // Atomic: Data.write(.atomic) writes a temp file and renames it into place.
        try Data(file.bytes).write(to: scanURL(root.name), options: .atomic)
        try sidecar.write(to: metaURL(root.name), options: .atomic)
    }

    public func load(rootPath: String) async throws -> (root: FileTreeNode, meta: ScanCacheMeta)? {
        let scan = scanURL(rootPath), sidecar = metaURL(rootPath)
        guard FileManager.default.fileExists(atPath: scan.path), FileManager.default.fileExists(atPath: sidecar.path) else {
            return nil
        }
        let meta: ScanCacheMeta
        do {
            meta = try JSONDecoder().decode(ScanCacheMeta.self, from: Data(contentsOf: sidecar))
        } catch {
            throw ScanCacheError.corrupt("unreadable metadata sidecar")
        }
        guard meta.rootPath == rootPath else { throw ScanCacheError.corrupt("metadata is for a different root") }
        let file = try Data(contentsOf: scan, options: .mappedIfSafe)
        let root = try Self.decode(file)
        guard root.name == rootPath else { throw ScanCacheError.corrupt("tree root does not match the requested path") }
        return (root, meta)
    }

    public func cachedScans() async -> [ScanCacheMeta] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [ScanCacheMeta] = []
        for url in items where url.pathExtension == "json" {
            let scan = url.deletingPathExtension().appendingPathExtension("kladscan")
            guard FileManager.default.fileExists(atPath: scan.path),
                  let data = try? Data(contentsOf: url),
                  let meta = try? JSONDecoder().decode(ScanCacheMeta.self, from: data),
                  Self.hash(of: meta.rootPath) == url.deletingPathExtension().lastPathComponent
            else { continue }
            result.append(meta)
        }
        return result.sorted { $0.scannedAt != $1.scannedAt ? $0.scannedAt > $1.scannedAt : $0.rootPath < $1.rootPath }
    }

    public func remove(rootPath: String) async throws {
        for url in [scanURL(rootPath), metaURL(rootPath)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)   // our own cache file, never user data
        }
    }

    // MARK: Encoding

    /// Iterative pre-order encoding of the whole tree. Returns the raw body and node count.
    static func encode(_ root: FileTreeNode) throws -> (body: [UInt8], count: UInt64) {
        var out = ByteWriter(capacity: 1 << 20)
        var stack: [FileTreeNode] = [root]
        var count: UInt64 = 0
        while let node = stack.popLast() {
            let isDirectory = node.kind == .directory
            let nameBytes = node.name.utf8
            guard nameBytes.count <= maxNameLength else { throw ScanCacheError.nameTooLong(node.name) }
            out.u8(node.kind.rawValue)
            out.u32(node.flags.rawValue)
            out.u64(node.fileID)
            out.u32(UInt32(bitPattern: node.deviceID))
            out.u64(UInt64(bitPattern: node.modificationTime))
            out.u64(node.cloneID)
            out.u32(UInt32(bitPattern: node.errorCode))
            out.u16(UInt16(nameBytes.count))
            out.bytes.append(contentsOf: nameBytes)
            let children = isDirectory ? node.children : []
            out.u32(UInt32(truncatingIfNeeded: children.count))
            if !isDirectory {
                out.u64(node.metrics.logicalBytes)
                out.u64(node.metrics.allocatedBytes)
                out.u64(node.metrics.privateBytes)
                out.u64(node.metrics.cloudStubBytes)
            }
            count += 1
            // Reversed so children pop (and are written) in stored order.
            for child in children.reversed() { stack.append(child) }
        }
        return (out.bytes, count)
    }

    /// LZFSE, one shot. (`NSData.compressed(using: .lzfse)` yields the same stream format but is
    /// ~6× slower on large buffers: 5.6 s vs 0.9 s for a 200 MB / 2.5 M-node body.)
    static func compress(_ raw: [UInt8]) throws -> [UInt8] {
        guard !raw.isEmpty else { throw ScanCacheError.corrupt("nothing to compress") }
        let capacity = raw.count + raw.count / 8 + 4096   // room for incompressible data
        var written = 0
        let output = [UInt8](unsafeUninitializedCapacity: capacity) { buffer, initialized in
            written = raw.withUnsafeBufferPointer { source in
                compression_encode_buffer(buffer.baseAddress!, capacity, source.baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
            initialized = written
        }
        guard written > 0 else { throw ScanCacheError.corrupt("LZFSE compression failed") }
        return output
    }

    // MARK: Decoding

    private struct Frame {
        var node: FileTreeNode
        var remaining: UInt32
        var children: [FileTreeNode]
    }

    /// Strict, bounds-checked, non-recursive decoding of a whole `.kladscan` file.
    static func decode(_ file: Data) throws -> FileTreeNode {
        guard file.count >= headerSize else { throw ScanCacheError.corrupt("file too short") }
        let (nodeCount, rawLength, declaredCompressed, expectedChecksum) = try file.withUnsafeBytes { source -> (UInt64, UInt64, UInt64, UInt64) in
            var header = ByteReader(source)
            guard try header.bytes(4).elementsEqual(magic) else { throw ScanCacheError.corrupt("bad magic") }
            let version = try header.u16()
            guard version == formatVersion else { throw ScanCacheError.unsupportedVersion(version) }
            return (try header.u64(), try header.u64(), try header.u64(), try header.u64())
        }

        let compressedLength = UInt64(file.count - headerSize)
        guard declaredCompressed == compressedLength else { throw ScanCacheError.corrupt("file is truncated or has trailing bytes") }
        guard nodeCount >= 1, nodeCount <= rawLength / UInt64(minimumNodeSize) else {
            throw ScanCacheError.corrupt("node count does not fit the body length")
        }
        guard rawLength <= maxRawLength, rawLength <= compressedLength &* maxExpansion &+ (1 << 20) else {
            throw ScanCacheError.corrupt("implausible body length")
        }

        // LZFSE decode into exactly `rawLength` bytes.
        let length = Int(rawLength)
        var written = 0
        let raw = [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
            written = file.withUnsafeBytes { source -> Int in
                guard let base = source.baseAddress, let out = buffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    out, length, base.advanced(by: headerSize).assumingMemoryBound(to: UInt8.self),
                    source.count - headerSize, nil, COMPRESSION_LZFSE)
            }
            initialized = written
        }
        guard written == length else { throw ScanCacheError.corrupt("body is truncated or not valid LZFSE data") }
        guard checksum(raw) == expectedChecksum else { throw ScanCacheError.corrupt("checksum mismatch") }

        return try raw.withUnsafeBytes { try decodeNodes($0, nodeCount: nodeCount) }
    }

    private static func decodeNodes(_ buffer: UnsafeRawBufferPointer, nodeCount: UInt64) throws -> FileTreeNode {
        var reader = ByteReader(buffer)
        var stack: [Frame] = []
        var finished: FileTreeNode?
        var decoded: UInt64 = 0
        // Nodes announced by a parent's childCount but not yet decoded (the root counts as 1).
        var outstanding: UInt64 = 1

        while finished == nil {
            guard outstanding > 0 else { throw ScanCacheError.corrupt("tree ended before all nodes were read") }
            let isRoot = stack.isEmpty
            guard let kind = NodeKind(rawValue: try reader.u8()) else { throw ScanCacheError.corrupt("unknown node kind") }
            let flags = NodeFlags(rawValue: try reader.u32())
            let fileID = try reader.u64()
            let deviceID = Int32(bitPattern: try reader.u32())
            let mtime = Int64(bitPattern: try reader.u64())
            let cloneID = try reader.u64()
            let errorCode = Int32(bitPattern: try reader.u32())
            let nameLength = Int(try reader.u16())
            guard nameLength <= maxNameLength else { throw ScanCacheError.corrupt("name too long") }
            let nameBytes = try reader.bytes(nameLength)
            let name = String(decoding: nameBytes, as: UTF8.self)
            if isRoot {
                guard !name.isEmpty else { throw ScanCacheError.corrupt("empty root name") }
            } else {
                guard !name.isEmpty, !nameBytes.contains(UInt8(ascii: "/")), !nameBytes.contains(0) else {
                    throw ScanCacheError.corrupt("invalid node name")
                }
            }
            let childCount = try reader.u32()

            var metrics = StorageMetrics.zero
            if kind != .directory {
                guard childCount == 0 else { throw ScanCacheError.corrupt("leaf node with children") }
                metrics.logicalBytes = try reader.u64()
                metrics.allocatedBytes = try reader.u64()
                metrics.privateBytes = try reader.u64()
                metrics.cloudStubBytes = try reader.u64()
                metrics.fileCount = flags.contains(.opaque) ? 0 : 1
            }

            // Bookkeeping: never trust childCount beyond what the header promised.
            decoded += 1
            outstanding -= 1
            outstanding += UInt64(childCount)
            guard decoded + outstanding <= nodeCount else { throw ScanCacheError.corrupt("child count exceeds node count") }

            let node = FileTreeNode(
                name: name, kind: kind, metrics: metrics, flags: flags, fileID: fileID, deviceID: deviceID,
                modificationTime: mtime, cloneID: cloneID, errorCode: errorCode)

            if childCount > 0 {
                stack.append(Frame(node: node, remaining: childCount, children: []))
                continue
            }
            // A completed node attaches to its parent; completed parents cascade upward.
            var completed = node
            while true {
                guard !stack.isEmpty else { finished = completed; break }
                let top = stack.count - 1
                stack[top].children.append(completed)
                stack[top].remaining -= 1
                guard stack[top].remaining == 0 else { break }
                let frame = stack.removeLast()
                frame.node.setChildren(frame.children)
                completed = frame.node
            }
        }

        guard let root = finished, decoded == nodeCount, outstanding == 0, reader.remaining == 0 else {
            throw ScanCacheError.corrupt("node count or trailing data mismatch")
        }
        root.recomputeAggregates(sortChildren: true)
        return root
    }

    // MARK: Helpers

    /// First 8 bytes of SHA-256, little-endian.
    static func checksum(_ bytes: [UInt8]) -> UInt64 {
        let digest = SHA256.hash(data: bytes)
        var value: UInt64 = 0
        for (shift, byte) in digest.prefix(8).enumerated() { value |= UInt64(byte) << UInt64(8 * shift) }
        return value
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Little-endian byte IO

private struct ByteWriter {
    var bytes: [UInt8] = []

    init(capacity: Int) { bytes.reserveCapacity(capacity) }

    @inline(__always) mutating func u8(_ v: UInt8) { bytes.append(v) }
    @inline(__always) mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    @inline(__always) mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    @inline(__always) mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
}

private struct ByteReader {
    private let buffer: UnsafeRawBufferPointer
    private var offset = 0
    init(_ buffer: UnsafeRawBufferPointer) { self.buffer = buffer }

    var remaining: Int { buffer.count - offset }

    private mutating func take(_ count: Int) throws -> Int {
        guard count >= 0, count <= remaining else { throw ScanCacheError.corrupt("unexpected end of data") }
        defer { offset += count }
        return offset
    }

    @inline(__always) mutating func u8() throws -> UInt8 { buffer[try take(1)] }
    @inline(__always) mutating func u16() throws -> UInt16 {
        UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: try take(2), as: UInt16.self))
    }
    @inline(__always) mutating func u32() throws -> UInt32 {
        UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: try take(4), as: UInt32.self))
    }
    @inline(__always) mutating func u64() throws -> UInt64 {
        UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: try take(8), as: UInt64.self))
    }
    mutating func bytes(_ count: Int) throws -> UnsafeRawBufferPointer.SubSequence {
        let start = try take(count)
        return buffer[start..<start + count]
    }
}
