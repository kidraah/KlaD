// BSDAttributeLayout.swift — KlaDScanner
//
// Zero-copy parsing of getattrlistbulk(2) result buffers.
//
// Verified packing rules (sys/attr.h, getattrlist(2), getattrlistbulk(2)):
//   • Each entry starts with a u_int32_t total length.
//   • ATTR_CMN_RETURNED_ATTRS (attribute_set_t, 20 bytes) is packed first,
//     then ATTR_CMN_ERROR, then ATTR_CMN_NAME, then the remaining common
//     attributes in ascending bit order.
//   • Directory attributes follow (directories only), then file attributes
//     (non-directories only), then — with FSOPT_ATTR_CMN_EXTENDED — the
//     ATTR_CMNEXT_* "extended common" attributes requested through the
//     `forkattr` bitmap, in ascending bit order.
//   • Every attribute is 4-byte aligned, INCLUDING 64-bit values, so all
//     loads go through `loadUnaligned`.
//   • Only attributes present in the returned set are packed (we do not pass
//     FSOPT_PACK_INVAL_ATTRS).
// `klad-probe verify <dir>` cross-checks every parsed field against lstat(2).

import Darwin
import Foundation

/// Raw constants (spelled out so we never depend on how Clang imports
/// large unsigned macros).
enum BSDAttr {
    // commonattr
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnFlags: UInt32 = 0x0004_0000
    static let cmnFileID: UInt32 = 0x0200_0000
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    // dirattr
    static let dirMountStatus: UInt32 = 0x0000_0004
    // fileattr
    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileTotalSize: UInt32 = 0x0000_0002
    static let fileAllocSize: UInt32 = 0x0000_0004
    // forkattr reinterpreted as ATTR_CMNEXT_* (FSOPT_ATTR_CMN_EXTENDED)
    static let extPrivateSize: UInt32 = 0x0000_0008
    static let extCloneID: UInt32 = 0x0000_0100
    static let extExtFlags: UInt32 = 0x0000_0200
    // options
    static let optAttrCmnExtended: UInt64 = 0x0000_0020
    static let optReturnRealDev: UInt64 = 0x0000_0200
    // DIR_MNTSTATUS_*
    static let dirMntStatusMountPoint: UInt32 = 0x0000_0001
    static let dirMntStatusTrigger: UInt32 = 0x0000_0002
}

/// fsobj_type_t (enum vtype).
enum VType: UInt32 {
    case vnon = 0, vreg = 1, vdir = 2, vblk = 3, vchr = 4, vlnk = 5, vsock = 6, vfifo = 7, vbad = 8, vstr = 9, vcplx = 10
}

/// st_flags bits (sys/stat.h).
enum BSDFileFlags {
    static let ufImmutable: UInt32 = 0x0000_0002
    static let ufCompressed: UInt32 = 0x0000_0020
    static let ufHidden: UInt32 = 0x0000_8000
    static let sfImmutable: UInt32 = 0x0002_0000
    static let sfRestricted: UInt32 = 0x0008_0000
    static let sfNoUnlink: UInt32 = 0x0010_0000
    static let sfFirmlink: UInt32 = 0x0080_0000
    static let sfDataless: UInt32 = 0x4000_0000
}

/// ATTR_CMNEXT_EXT_FLAGS bits (sys/stat.h EF_*).
enum BSDExtFlags {
    static let mayShareBlocks: UInt64 = 0x01
    static let noXattrs: UInt64 = 0x02
    static let isSyncRoot: UInt64 = 0x04
    static let isPurgeable: UInt64 = 0x08
    static let isSparse: UInt64 = 0x10
    static let isSynthetic: UInt64 = 0x20
    static let sharesAllBlocks: UInt64 = 0x40
}

/// One parsed directory entry. `namePointer` is only valid while the
/// result buffer is alive — materialize `name` before refilling it.
struct BulkEntry {
    var namePointer: UnsafePointer<UInt8>?
    var nameLength: Int = 0          // bytes, excluding the NUL terminator
    var errorCode: UInt32 = 0
    var deviceID: Int32 = 0
    var objectType: UInt32 = 0
    var modificationTime: Int64 = 0
    var bsdFlags: UInt32 = 0
    var fileID: UInt64 = 0
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 1
    var totalSize: Int64 = 0
    var allocSize: Int64 = 0
    var privateSize: Int64 = 0
    var cloneID: UInt64 = 0
    var extFlags: UInt64 = 0
    var hasPrivateSize = false
    var hasFileAttributes = false
    var hasExtFlags = false

    var isDirectory: Bool { objectType == VType.vdir.rawValue }
    var isSymlink: Bool { objectType == VType.vlnk.rawValue }
    var isRegular: Bool { objectType == VType.vreg.rawValue }

    var name: String {
        guard let namePointer, nameLength > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: namePointer, count: nameLength), as: UTF8.self)
    }

    /// Name equals an ASCII literal, without allocating.
    func nameEquals(_ literal: StaticString) -> Bool {
        guard let namePointer, nameLength == literal.utf8CodeUnitCount else { return false }
        return memcmp(namePointer, literal.utf8Start, nameLength) == 0
    }
}

/// Parses the packed entries of one getattrlistbulk result buffer.
enum BulkEntryParser {
    /// Calls `body` for each of `count` entries in `buffer`.
    @inline(__always)
    static func forEachEntry(in buffer: UnsafeRawPointer, count: Int, _ body: (inout BulkEntry) -> Void) {
        var cursor = buffer
        for _ in 0..<count {
            let entryLength = Int(cursor.loadUnaligned(as: UInt32.self))
            var entry = BulkEntry()
            var p = cursor + 4

            let common = p.loadUnaligned(as: UInt32.self)
            // volattr at +4 is never set for bulk
            let dirAttrs = p.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let fileAttrs = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            let extAttrs = p.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            p += 20

            if common & BSDAttr.cmnError != 0 {
                entry.errorCode = p.loadUnaligned(as: UInt32.self)
                p += 4
            }
            if common & BSDAttr.cmnName != 0 {
                let offset = Int(p.loadUnaligned(as: Int32.self))
                let length = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                entry.namePointer = (p + offset).assumingMemoryBound(to: UInt8.self)
                entry.nameLength = max(0, length - 1)   // length includes the NUL
                p += 8
            }
            if common & BSDAttr.cmnDevID != 0 {
                entry.deviceID = p.loadUnaligned(as: Int32.self)
                p += 4
            }
            if common & BSDAttr.cmnObjType != 0 {
                entry.objectType = p.loadUnaligned(as: UInt32.self)
                p += 4
            }
            if common & BSDAttr.cmnModTime != 0 {
                entry.modificationTime = Int64(p.loadUnaligned(as: Int.self))   // timespec.tv_sec
                p += MemoryLayout<timespec>.size
            }
            if common & BSDAttr.cmnFlags != 0 {
                entry.bsdFlags = p.loadUnaligned(as: UInt32.self)
                p += 4
            }
            if common & BSDAttr.cmnFileID != 0 {
                entry.fileID = p.loadUnaligned(as: UInt64.self)
                p += 8
            }
            // Directory attributes (directories only).
            if dirAttrs & BSDAttr.dirMountStatus != 0 {
                entry.mountStatus = p.loadUnaligned(as: UInt32.self)
                p += 4
            }
            // File attributes (non-directories only).
            if fileAttrs & BSDAttr.fileLinkCount != 0 {
                entry.linkCount = p.loadUnaligned(as: UInt32.self)
                p += 4
            }
            if fileAttrs & BSDAttr.fileTotalSize != 0 {
                entry.totalSize = p.loadUnaligned(as: Int64.self)
                entry.hasFileAttributes = true
                p += 8
            }
            if fileAttrs & BSDAttr.fileAllocSize != 0 {
                entry.allocSize = p.loadUnaligned(as: Int64.self)
                p += 8
            }
            // Extended common attributes (ascending bit order).
            if extAttrs & BSDAttr.extPrivateSize != 0 {
                entry.privateSize = p.loadUnaligned(as: Int64.self)
                entry.hasPrivateSize = true
                p += 8
            }
            if extAttrs & BSDAttr.extCloneID != 0 {
                entry.cloneID = p.loadUnaligned(as: UInt64.self)
                p += 8
            }
            if extAttrs & BSDAttr.extExtFlags != 0 {
                entry.extFlags = p.loadUnaligned(as: UInt64.self)
                entry.hasExtFlags = true
                p += 8
            }

            body(&entry)
            cursor += entryLength
        }
    }
}

/// Builds the attrlist request used by every scanner thread.
enum BulkRequest {
    static func makeAttrList(requestPrivateSize: Bool) -> attrlist {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = BSDAttr.cmnReturnedAttrs | BSDAttr.cmnName | BSDAttr.cmnError | BSDAttr.cmnDevID
            | BSDAttr.cmnObjType | BSDAttr.cmnModTime | BSDAttr.cmnFlags | BSDAttr.cmnFileID
        list.dirattr = BSDAttr.dirMountStatus
        list.fileattr = BSDAttr.fileLinkCount | BSDAttr.fileTotalSize | BSDAttr.fileAllocSize
        list.forkattr = (requestPrivateSize ? BSDAttr.extPrivateSize : 0) | BSDAttr.extCloneID | BSDAttr.extExtFlags
        return list
    }

    /// NOTE: deliberately *without* FSOPT_RETURN_REALDEV. In a boot volume group,
    /// lstat(2) reports ONE device for the sealed System snapshot, the Data volume
    /// and the firmlinks between them, whereas RETURN_REALDEV reports the physical
    /// snapshot device. Matching lstat keeps the traversal guard and the cleanup
    /// pre-flight identity checks consistent (verified with `klad-probe verify`).
    static let options: UInt64 = BSDAttr.optAttrCmnExtended
}

/// Reads one directory with getattrlistbulk(2).
struct BulkDirectoryReader {
    /// Result buffer (one per thread; 256 KiB holds ~1–2k entries per syscall).
    let buffer: UnsafeMutableRawPointer
    let bufferSize: Int
    var attrList: attrlist

    init(requestPrivateSize: Bool, bufferSize: Int = 256 * 1024) {
        self.bufferSize = bufferSize
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        self.attrList = BulkRequest.makeAttrList(requestPrivateSize: requestPrivateSize)
    }

    func deallocate() { buffer.deallocate() }

    enum ReadResult {
        case ok
        case openFailed(Int32)
        case readFailed(Int32)
        case cancelled
    }

    /// Opens `path` (never following a final symlink) and streams every entry.
    /// Returns the errno on failure. `isCancelled` is polled between batches.
    mutating func read(path: String, isCancelled: () -> Bool, _ body: (inout BulkEntry) -> Void) -> ReadResult {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .openFailed(errno) }
        defer { close(fd) }
        while true {
            if isCancelled() { return .cancelled }
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, BulkRequest.options)
            if count == 0 { return .ok }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                return .readFailed(code)
            }
            BulkEntryParser.forEachEntry(in: UnsafeRawPointer(buffer), count: Int(count), body)
        }
    }
}

// MARK: - iCloud dataless guard

/// Enforces the "never materialize SF_DATALESS" invariant at the kernel level:
/// with IOPOL_MATERIALIZE_DATALESS_FILES_OFF, any accidental read/open of an
/// iCloud placeholder by this process fails (EDEADLK) instead of asking
/// fileproviderd/bird to download it.
public enum DatalessMaterializationGuard {
    // sys/resource.h
    private static let iopolTypeMaterializeDataless: Int32 = 3  // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
    private static let iopolScopeProcess: Int32 = 0             // IOPOL_SCOPE_PROCESS
    private static let iopolScopeThread: Int32 = 1              // IOPOL_SCOPE_THREAD
    private static let materializeOff: Int32 = 1                // IOPOL_MATERIALIZE_DATALESS_FILES_OFF

    /// Engage for the whole process (call once at launch).
    @discardableResult
    public static func engageProcessWide() -> Bool {
        setiopolicy_np(iopolTypeMaterializeDataless, iopolScopeProcess, materializeOff) == 0
    }

    /// Engage for the calling thread (scanner worker threads).
    @discardableResult
    public static func engageForCurrentThread() -> Bool {
        setiopolicy_np(iopolTypeMaterializeDataless, iopolScopeThread, materializeOff) == 0
    }

    /// Current process-wide policy (for diagnostics).
    public static var processPolicyIsOff: Bool {
        getiopolicy_np(iopolTypeMaterializeDataless, iopolScopeProcess) == materializeOff
    }
}
