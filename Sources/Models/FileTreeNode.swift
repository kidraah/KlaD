// FileTreeNode.swift — KlaDModels
//
// Compact reference/value hybrid tree. Nodes are reference types (cheap parent /
// child links, stable identity for SwiftUI); all sizes are a value-type
// `StorageMetrics`. Directory metrics are aggregates of their descendants.
//
// ── THREADING CONTRACT ────────────────────────────────────────────────────────
// `FileTreeNode` is `@unchecked Sendable`. Its mutable state follows a strict
// single-writer discipline:
//   1. While a scan is running, ONLY the scanner mutates the nodes it creates
//      (each directory's children are assigned by exactly one worker).
//   2. Post-processing (aggregation, classification) runs on ONE task before the
//      tree is published.
//   3. After publication, mutations (`removeFromParent`, `replace(with:)`,
//      annotation updates) happen ONLY on the MainActor.
// Background readers (duplicate candidate collection, snapshot capture) must run
// before publication or operate on value-type copies.
//
// ── INVARIANTS ────────────────────────────────────────────────────────────────
//   • The root node's `name` is its absolute path ("/", "/Users/me"); every
//     other node's `name` is a single path component.
//   • After `recomputeAggregates(sortChildren: true)`, children are sorted by
//     `metrics.allocatedBytes` descending (ties: name ascending).
//   • A file node has `metrics.fileCount == 1, directoryCount == 0`.
//   • A directory's metrics == Σ children's `aggregateContribution`.
//   • Hard-link duplicates (2nd+ sighting of an inode) contribute only to the
//     file count, never to byte totals.

import Foundation

/// The kind of file-system object.
public enum NodeKind: UInt8, Sendable, Codable, Hashable {
    case file
    case directory
    case symlink
    /// FIFOs, sockets, devices, …
    case other
}

/// Per-node facts from the BSD attribute layer.
public struct NodeFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// SF_DATALESS — iCloud / File Provider placeholder. NEVER open, read or hash.
    public static let cloudPlaceholder        = NodeFlags(rawValue: 1 << 0)
    /// EF_MAY_SHARE_BLOCKS — may share blocks with a clone or snapshot.
    public static let mayShareBlocks          = NodeFlags(rawValue: 1 << 1)
    /// EF_SHARES_ALL_BLOCKS — a pure APFS clone (shares every block with another file).
    public static let sharesAllBlocks         = NodeFlags(rawValue: 1 << 2)
    /// Link count > 1.
    public static let hardLinked              = NodeFlags(rawValue: 1 << 3)
    /// 2nd+ sighting of a hard-linked inode: excluded from parent byte aggregates.
    public static let hardLinkDuplicate       = NodeFlags(rawValue: 1 << 4)
    /// DIR_MNTSTATUS_MNTPOINT — another file system is mounted here.
    public static let mountPoint              = NodeFlags(rawValue: 1 << 5)
    /// SF_FIRMLINK — firmlink into the Data volume (e.g. /Users).
    public static let firmlink                = NodeFlags(rawValue: 1 << 6)
    /// EF_IS_SYNTHETIC — synthetic directory/symlink (/etc/synthetic.conf).
    public static let synthetic               = NodeFlags(rawValue: 1 << 7)
    /// EF_IS_SPARSE — at least one sparse region.
    public static let sparse                  = NodeFlags(rawValue: 1 << 8)
    /// UF_COMPRESSED — transparently compressed (decmpfs).
    public static let compressed              = NodeFlags(rawValue: 1 << 9)
    /// EF_IS_PURGEABLE — the OS may purge this file on its own.
    public static let purgeable               = NodeFlags(rawValue: 1 << 10)
    /// UF_HIDDEN or a dot-file.
    public static let hidden                  = NodeFlags(rawValue: 1 << 11)
    /// A bundle directory (.app, .framework, .photoslibrary, …).
    public static let package                 = NodeFlags(rawValue: 1 << 12)
    /// Directory could not be enumerated (EPERM / EACCES / …). See `errorCode`.
    public static let unreadable              = NodeFlags(rawValue: 1 << 13)
    /// Intentionally not descended (mount point, other volume, excluded path, firmlink duplicate).
    public static let excluded                = NodeFlags(rawValue: 1 << 14)
    /// ATTR_CMNEXT_PRIVATESIZE unavailable — privateBytes fell back to allocatedBytes.
    public static let privateSizeUnavailable  = NodeFlags(rawValue: 1 << 15)
    /// SF_RESTRICTED — System Integrity Protection.
    public static let restricted              = NodeFlags(rawValue: 1 << 16)
    /// EF_IS_SYNC_ROOT — an iCloud sync root.
    public static let syncRoot                = NodeFlags(rawValue: 1 << 17)
    /// UF_IMMUTABLE / SF_IMMUTABLE / SF_NOUNLINK.
    public static let immutable               = NodeFlags(rawValue: 1 << 18)
    /// Some descendant was unreadable or the scan was cancelled — totals are a lower bound.
    public static let incompleteSubtree       = NodeFlags(rawValue: 1 << 19)
}

/// Classification output attached to rule-matched nodes (allocated only for matches).
public final class NodeAnnotation: Sendable {
    public let ruleID: String
    public let title: String
    public let safety: SafetyLevel
    public let group: RecommendationGroup
    /// Short human reason ("Sibling package.json + package-lock.json").
    public let reason: String

    public init(ruleID: String, title: String, safety: SafetyLevel, group: RecommendationGroup, reason: String) {
        self.ruleID = ruleID
        self.title = title
        self.safety = safety
        self.group = group
        self.reason = reason
    }
}

/// Traversal control for `walk`.
public enum TraversalControl: Sendable {
    case `continue`
    case skipChildren
    case stop
}

public final class FileTreeNode: @unchecked Sendable, Identifiable, Hashable, CustomStringConvertible {
    // MARK: Identity
    /// Path component, or the absolute path for a root node.
    public let name: String
    public let kind: NodeKind
    /// ATTR_CMN_FILEID (inode number).
    public let fileID: UInt64
    /// ATTR_CMN_DEVID.
    public let deviceID: Int32
    /// ATTR_CMN_MODTIME, seconds since 1970.
    public let modificationTime: Int64
    /// ATTR_CMNEXT_CLONEID (0 when unavailable). Equal ids ⇒ pure clones of the same data stream.
    public let cloneID: UInt64

    // MARK: Tree links
    public internal(set) weak var parent: FileTreeNode?
    public private(set) var children: [FileTreeNode]

    // MARK: Storage & facts
    /// Own values for files; aggregate for directories.
    public var metrics: StorageMetrics
    public var flags: NodeFlags
    /// errno when `.unreadable`.
    public var errorCode: Int32

    // MARK: Classification (written by the classification engine)
    public var category: StorageCategory
    public var annotation: NodeAnnotation?

    public init(
        name: String,
        kind: NodeKind,
        metrics: StorageMetrics = .zero,
        flags: NodeFlags = [],
        fileID: UInt64 = 0,
        deviceID: Int32 = 0,
        modificationTime: Int64 = 0,
        cloneID: UInt64 = 0,
        errorCode: Int32 = 0,
        category: StorageCategory = .other
    ) {
        self.name = name
        self.kind = kind
        self.metrics = metrics
        self.flags = flags
        self.fileID = fileID
        self.deviceID = deviceID
        self.modificationTime = modificationTime
        self.cloneID = cloneID
        self.errorCode = errorCode
        self.category = category
        self.children = []
    }

    // MARK: Identifiable / Hashable (reference identity)

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    public static func == (lhs: FileTreeNode, rhs: FileTreeNode) -> Bool { lhs === rhs }

    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    public var description: String {
        "FileTreeNode(\(path), \(kind), alloc=\(metrics.allocatedBytes), private=\(metrics.privateBytes))"
    }

    // MARK: Derived properties

    @inlinable public var isDirectory: Bool { kind == .directory }
    @inlinable public var isRoot: Bool { parent == nil }
    @inlinable public var hasChildren: Bool { !children.isEmpty }

    /// Children for `OutlineGroup` / hierarchical `Table`: nil for leaves.
    public var childrenOrNil: [FileTreeNode]? { children.isEmpty ? nil : children }

    /// Absolute path, rebuilt by walking parents (not stored, to save memory).
    public var path: String {
        guard let parent else { return name }
        let parentPath = parent.path
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    /// Human label: last path component for roots ("Macintosh HD" for "/").
    public var displayName: String {
        guard parent == nil else { return name }
        if name == "/" { return "Macintosh HD" }
        let last = (name as NSString).lastPathComponent
        return last.isEmpty ? name : last
    }

    public var modificationDate: Date { Date(timeIntervalSince1970: TimeInterval(modificationTime)) }

    /// Depth below the root (root = 0).
    public var depth: Int {
        var d = 0
        var cursor = parent
        while let c = cursor { d += 1; cursor = c.parent }
        return d
    }

    /// Ancestors from the root down to (not including) self.
    public var ancestors: [FileTreeNode] {
        var chain: [FileTreeNode] = []
        var cursor = parent
        while let c = cursor { chain.append(c); cursor = c.parent }
        return chain.reversed()
    }

    /// The topmost ancestor (self if root).
    public var root: FileTreeNode {
        var cursor = self
        while let p = cursor.parent { cursor = p }
        return cursor
    }

    /// The nearest annotation on self or an ancestor (e.g. files inside a matched
    /// node_modules inherit its safety).
    public var effectiveAnnotation: NodeAnnotation? {
        var cursor: FileTreeNode? = self
        while let c = cursor {
            if let a = c.annotation { return a }
            cursor = c.parent
        }
        return nil
    }

    /// What this node adds to its parent's aggregate.
    public var aggregateContribution: StorageMetrics {
        if flags.contains(.hardLinkDuplicate) {
            return StorageMetrics(fileCount: 1)
        }
        if kind == .directory {
            var m = metrics
            m.directoryCount &+= 1
            return m
        }
        return metrics
    }

    /// Identity used by pre-flight checks to verify a target hasn't changed since the scan.
    public var identity: NodeIdentity {
        NodeIdentity(fileID: fileID, deviceID: deviceID, modificationTime: modificationTime)
    }

    // MARK: Lookup

    /// Linear search among direct children.
    public func child(named childName: String) -> FileTreeNode? {
        children.first { $0.name == childName }
    }

    /// Whether a direct child with this name exists.
    public func hasChild(named childName: String) -> Bool {
        children.contains { $0.name == childName }
    }

    /// Sibling with this name (via parent), if any.
    public func sibling(named siblingName: String) -> FileTreeNode? {
        parent?.child(named: siblingName)
    }

    /// Resolves an absolute path within this subtree.
    public func descendant(atPath absolutePath: String) -> FileTreeNode? {
        let base = path
        if absolutePath == base { return self }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard absolutePath.hasPrefix(prefix) else { return nil }
        var current = self
        for component in absolutePath.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = current.child(named: String(component)) else { return nil }
            current = next
        }
        return current
    }

    // MARK: Traversal

    /// Pre-order, iterative (safe on deep trees). Visits self first.
    public func walk(_ body: (FileTreeNode) throws -> TraversalControl) rethrows {
        var stack: [FileTreeNode] = [self]
        while let node = stack.popLast() {
            switch try body(node) {
            case .stop: return
            case .skipChildren: continue
            case .continue:
                // Reverse so children are visited in their stored (size-descending) order.
                stack.append(contentsOf: node.children.reversed())
            }
        }
    }

    /// Pre-order traversal that also supplies each node's absolute path, built
    /// incrementally (much cheaper than calling `path` per node).
    public func walkWithPaths(_ body: (FileTreeNode, String) throws -> TraversalControl) rethrows {
        var stack: [(FileTreeNode, String)] = [(self, path)]
        while let (node, nodePath) = stack.popLast() {
            switch try body(node, nodePath) {
            case .stop: return
            case .skipChildren: continue
            case .continue:
                let prefix = nodePath.hasSuffix("/") ? nodePath : nodePath + "/"
                for child in node.children.reversed() {
                    stack.append((child, prefix + child.name))
                }
            }
        }
    }

    // MARK: Mutation (scanner before publication; MainActor after — see contract)

    /// Replaces all children, wiring parent links. Does NOT recompute aggregates.
    public func setChildren(_ newChildren: [FileTreeNode]) {
        for child in newChildren { child.parent = self }
        children = newChildren
    }

    /// Appends a child, wiring its parent link. Does NOT recompute aggregates.
    public func appendChild(_ child: FileTreeNode) {
        child.parent = self
        children.append(child)
    }

    /// Recomputes directory aggregates for this whole subtree (post-order,
    /// iterative), propagates `.incompleteSubtree`, and optionally sorts children
    /// by allocated bytes descending.
    public func recomputeAggregates(sortChildren: Bool = true) {
        // Collect directories in pre-order; process in reverse ⇒ children before parents.
        var directories: [FileTreeNode] = []
        var stack: [FileTreeNode] = [self]
        while let node = stack.popLast() {
            guard node.kind == .directory else { continue }
            directories.append(node)
            for child in node.children where child.kind == .directory {
                stack.append(child)
            }
        }
        for directory in directories.reversed() {
            directory.aggregateFromChildren(sort: sortChildren)
        }
    }

    /// Recomputes this directory's metrics from its (already aggregated) children.
    public func aggregateFromChildren(sort: Bool) {
        guard kind == .directory else { return }
        var total = StorageMetrics.zero
        var incomplete = flags.contains(.unreadable)
        for child in children {
            total.add(child.aggregateContribution)
            if child.flags.contains(.incompleteSubtree) || child.flags.contains(.unreadable) {
                incomplete = true
            }
        }
        metrics = total
        if incomplete { flags.insert(.incompleteSubtree) } else { flags.remove(.incompleteSubtree) }
        if sort { sortChildrenBySize() }
    }

    /// Sorts direct children by allocated bytes descending, then name.
    public func sortChildrenBySize() {
        children.sort { a, b in
            if a.metrics.allocatedBytes != b.metrics.allocatedBytes {
                return a.metrics.allocatedBytes > b.metrics.allocatedBytes
            }
            return a.name < b.name
        }
    }

    /// Detaches this node from its parent and subtracts its contribution from
    /// every ancestor. Returns false for a root.
    @discardableResult
    public func removeFromParent() -> Bool {
        guard let parent else { return false }
        let contribution = aggregateContribution
        parent.children.removeAll { $0 === self }
        self.parent = nil
        var cursor: FileTreeNode? = parent
        while let c = cursor {
            c.metrics.subtract(contribution)
            cursor = c.parent
        }
        return true
    }

    /// Swaps this node for `replacement` in the parent (e.g. after a subtree
    /// rescan), adjusts ancestor aggregates by the delta and re-sorts siblings.
    /// `replacement` must already have its own aggregates computed.
    @discardableResult
    public func replace(with replacement: FileTreeNode) -> Bool {
        guard let parent, let index = parent.children.firstIndex(where: { $0 === self }) else { return false }
        let old = aggregateContribution
        let new = replacement.aggregateContribution
        replacement.parent = parent
        parent.children[index] = replacement
        self.parent = nil
        var cursor: FileTreeNode? = parent
        while let c = cursor {
            c.metrics.subtract(old)
            c.metrics.add(new)
            c.sortChildrenBySize()
            if replacement.flags.contains(.incompleteSubtree) || replacement.flags.contains(.unreadable) {
                c.flags.insert(.incompleteSubtree)
            }
            cursor = c.parent
        }
        return true
    }

    // MARK: Builders (tests, fixtures, previews)

    /// A file node. `allocated` defaults to `logical` rounded up to 4 KiB,
    /// `privateBytes` defaults to `allocated`. Cloud placeholders get
    /// allocated = private = 0 and cloudStubBytes = logical.
    public static func file(
        _ name: String,
        logical: UInt64,
        allocated: UInt64? = nil,
        privateBytes: UInt64? = nil,
        flags: NodeFlags = [],
        modificationTime: Int64 = 0,
        fileID: UInt64 = 0,
        cloneID: UInt64 = 0
    ) -> FileTreeNode {
        let isStub = flags.contains(.cloudPlaceholder)
        let alloc = isStub ? 0 : (allocated ?? ((logical + 4095) / 4096) * 4096)
        let priv = isStub ? 0 : (privateBytes ?? alloc)
        return FileTreeNode(
            name: name,
            kind: .file,
            metrics: StorageMetrics(
                logicalBytes: logical,
                allocatedBytes: alloc,
                privateBytes: priv,
                cloudStubBytes: isStub ? logical : 0,
                fileCount: 1
            ),
            flags: flags,
            fileID: fileID,
            modificationTime: modificationTime,
            cloneID: cloneID
        )
    }

    /// A directory node with `children` attached (aggregates NOT computed —
    /// call `recomputeAggregates()` on the root when the fixture is complete).
    public static func directory(
        _ name: String,
        modificationTime: Int64 = 0,
        flags: NodeFlags = [],
        fileID: UInt64 = 0,
        children: [FileTreeNode] = []
    ) -> FileTreeNode {
        let node = FileTreeNode(name: name, kind: .directory, flags: flags, fileID: fileID, modificationTime: modificationTime)
        node.setChildren(children)
        return node
    }
}

/// Identity captured at scan time; pre-flight re-checks it before trashing.
public struct NodeIdentity: Sendable, Hashable, Codable {
    public var fileID: UInt64
    public var deviceID: Int32
    /// Seconds since 1970.
    public var modificationTime: Int64

    public init(fileID: UInt64, deviceID: Int32, modificationTime: Int64) {
        self.fileID = fileID
        self.deviceID = deviceID
        self.modificationTime = modificationTime
    }
}
