// NameKeys.swift — KlaDIntelligence
//
// Allocation-free file-extension keys. `categoryHint` and the installer rule run
// for every file of 1–3 million node trees, so the extension is packed into a
// lower-cased UInt64 (≤ 8 ASCII bytes) instead of building a `String`.

import Foundation
import KlaDModels

enum NameKeys {
    /// Returned for extensions longer than 8 bytes (e.g. "swiftmodule").
    static let longExtension: UInt64 = .max

    /// Packs the lower-cased extension of `name` into a UInt64.
    /// 0 = no extension (a leading dot alone is not an extension).
    static func extensionKey(_ name: String) -> UInt64 {
        if let key = name.utf8.withContiguousStorageIfAvailable({ extensionKey(bytes: $0) }) {
            return key
        }
        return Array(name.utf8).withUnsafeBufferPointer { extensionKey(bytes: $0) }
    }

    private static func extensionKey(bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var dot = -1
        var i = bytes.count - 1
        while i > 0 {
            if bytes[i] == 0x2E { dot = i; break }
            i -= 1
        }
        if dot < 0 { return 0 }
        let length = bytes.count - dot - 1
        if length == 0 { return 0 }
        if length > 8 { return longExtension }
        var key: UInt64 = 0
        var j = dot + 1
        while j < bytes.count {
            var b = bytes[j]
            if b >= 0x41 && b <= 0x5A { b |= 0x20 }
            key = (key << 8) | UInt64(b)
            j += 1
        }
        return key
    }

    /// Key for a known lower-case extension literal ("dmg").
    static func key(_ lowercaseExtension: String) -> UInt64 {
        lowercaseExtension.utf8.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Lower-cased extension of a (directory) name, or nil. Allocates — use only for directories.
    static func lowercasedExtension(of name: String) -> String? {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: 0x2E), dot > utf8.startIndex else { return nil }
        let ext = name[utf8.index(after: dot)...]
        guard !ext.isEmpty, ext.utf8.count <= 16 else { return nil }
        return ext.lowercased()
    }

    /// Text after the last "/" (the whole string when there is none).
    static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `path` without its final component (`name` must be that component). "/" for top-level paths.
    static func parentPath(of path: String, name: String) -> String {
        let utf8 = path.utf8
        let cut = name.utf8.count + 1
        guard utf8.count > cut else { return "/" }
        let end = utf8.index(utf8.endIndex, offsetBy: -cut)
        return String(path[..<end])
    }
}

// MARK: - Category hints (DeveloperRulesCataloging.categoryHint)

enum CategoryHints {
    private static let table: [UInt64: StorageCategory] = {
        var table: [UInt64: StorageCategory] = [:]
        func add(_ category: StorageCategory, _ extensions: String) {
            for ext in extensions.split(separator: " ") { table[NameKeys.key(String(ext))] = category }
        }
        add(.media, "mov mp4 m4v mkv avi webm heic heif jpg jpeg png gif tif tiff raw cr2 cr3 nef arw dng psd mp3 m4a wav aif aiff flac aac ogg caf")
        add(.aiModels, "gguf safetensors ckpt pt pth onnx mlmodel")
        add(.containersVMs, "qcow2 vmdk vdi vhd vhdx")
        add(.documents, "pdf doc docx xls xlsx ppt pptx key pages numbers txt md rtf csv zip tar gz tgz bz2 xz 7z rar dmg pkg iso xip epub")
        add(.developerBuilds, "o a rlib rmeta pcm dsym")
        return table
    }()

    static func hint(forFileNamed name: String) -> StorageCategory? {
        let key = NameKeys.extensionKey(name)
        if key == 0 { return nil }
        if key == NameKeys.longExtension {
            return name.lowercased().hasSuffix(".swiftmodule") ? .developerBuilds : nil
        }
        return table[key]
    }
}
