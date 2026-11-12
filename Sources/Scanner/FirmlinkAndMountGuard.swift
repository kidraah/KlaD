// FirmlinkAndMountGuard.swift — KlaDScanner
//
// Decides which directories the scanner descends into so every byte is
// counted exactly once:
//
//  • Mount points (DIR_MNTSTATUS_MNTPOINT) are not crossed unless asked —
//    and autofs triggers (DIR_MNTSTATUS_TRIGGER: /net, /home) never are,
//    because enumerating them mounts network file systems.
//  • Dataless (SF_DATALESS) directories are never enumerated: listing them
//    asks fileproviderd to materialize the folder from iCloud.
//  • A device change without a mount point means a firmlink. In whole-disk
//    mode ("/"), firmlinks into the Data volume (/Users, /Applications,
//    /private, …) are followed, the /System/Volumes/Data mount itself is
//    scanned in a second phase, and the shared visited set (dev, inode)
//    drops directories already reached through a firmlink — so the Data
//    volume is never counted twice.
//  • Every directory is recorded in the visited set, which also defeats
//    directory hard-link loops on HFS+ Time Machine volumes.
//  • Hard-linked files (link count > 1) are counted once per (dev, inode).

import Darwin
import Foundation
import os
import KlaDModels

struct InodeKey: Hashable {
    let device: Int32
    let inode: UInt64
}

final class TraversalGuard: @unchecked Sendable {
    enum Decision {
        /// Enumerate the directory.
        case descend
        /// Keep the node but don't enumerate it; flags explain why.
        case skip(NodeFlags)
        /// Drop the node entirely (already counted via a firmlink).
        case omit
    }

    let crossMountPoints: Bool
    let excludedPaths: Set<String>
    /// Devices whose directories may be entered without a mount point
    /// (root device, plus the Data volume in whole-disk mode).
    let allowedDevices: Set<Int32>

    private let visitedLock = OSAllocatedUnfairLock(initialState: Set<InodeKey>())
    private let hardLinkLock = OSAllocatedUnfairLock(initialState: Set<InodeKey>())

    init(crossMountPoints: Bool, excludedPaths: Set<String>, allowedDevices: Set<Int32>) {
        self.crossMountPoints = crossMountPoints
        self.excludedPaths = excludedPaths
        self.allowedDevices = allowedDevices
    }

    /// Records a directory as visited. Returns false if it was already seen.
    func markVisited(device: Int32, inode: UInt64) -> Bool {
        let key = InodeKey(device: device, inode: inode)
        return visitedLock.withLock { $0.insert(key).inserted }
    }

    /// Registers a hard-linked file. Returns true for the FIRST sighting
    /// (which carries the bytes); false for duplicates.
    func registerHardLink(device: Int32, inode: UInt64) -> Bool {
        let key = InodeKey(device: device, inode: inode)
        return hardLinkLock.withLock { $0.insert(key).inserted }
    }

    var hardLinkCount: Int { hardLinkLock.withLock { $0.count } }

    /// Whether to descend into a directory entry.
    func decide(entry: BulkEntry, childPath: String) -> Decision {
        if entry.bsdFlags & BSDFileFlags.sfDataless != 0 {
            return .skip([.cloudPlaceholder, .excluded])
        }
        if entry.mountStatus & BSDAttr.dirMntStatusTrigger != 0 {
            return .skip([.mountPoint, .excluded])
        }
        if entry.mountStatus & BSDAttr.dirMntStatusMountPoint != 0 && !crossMountPoints {
            return .skip([.mountPoint, .excluded])
        }
        if !excludedPaths.isEmpty && excludedPaths.contains(childPath) {
            return .skip([.excluded])
        }
        if !crossMountPoints && !allowedDevices.contains(entry.deviceID) {
            // Different volume reached without a mount point we were told to cross.
            return .skip([.excluded])
        }
        if !markVisited(device: entry.deviceID, inode: entry.fileID) {
            return .omit
        }
        return .descend
    }

    // MARK: - Volume-group helpers

    /// st_dev of a path (no follow), or nil.
    static func device(of path: String) -> Int32? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_dev
    }

    /// The Data volume mount of the boot volume group, if present.
    static let dataVolumeMount = "/System/Volumes/Data"

    /// Bundle extensions treated as opaque packages (`NodeFlags.package`).
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "systemextension",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "aplibrary", "logicx", "fcpbundle",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "docc", "mlpackage", "mlmodelc",
        "rtfd", "pages", "numbers", "key", "sparsebundle", "photosmigrator", "band",
        "qlgenerator", "prefpane", "saver", "component", "mdimporter", "wdgt",
        "utm", "pvm", "vmwarevm", "pkg", "mpkg",
    ]

    static func isPackageName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 16 else { return false }
        return packageExtensions.contains(ext.lowercased())
    }
}
