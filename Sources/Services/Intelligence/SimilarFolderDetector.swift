// SimilarFolderDetector.swift — KlaDIntelligence
//
// Finds copies of the same folder ("kd", "kd - Copy", "New folder (7)/kd copy 2", "kd_v2")
// from the tree alone — no disk I/O.
//
//   1. Candidates: directories ≥ minimumBytes at depth ≥ 1 that are not opaque, protected,
//      packages, or inside/equal to a rule-annotated cleanup target. Subtrees smaller than
//      the minimum are pruned (children can never exceed their parent).
//   2. Identical contents: a 64-bit fingerprint over the multiset of
//      (child name, child kind, child allocated rounded to 4 KiB) + file count. Subfolders
//      contribute their own fingerprint instead of just their size (computed bottom-up), so two
//      folders only match when their whole structure matches — not merely their top level.
//      Candidates are sorted by fingerprint so equal ones are adjacent (no O(n²)).
//   3. Name variants: names are normalised (case, " copy", "(2)", "_v2", "_old", …) and
//      bucketed by a hash of the normalised name; inside a bucket only fingerprint classes
//      whose sizes are within 15 % are compared (two-pointer window over sizes) by the
//      Jaccard similarity of their child-name sets (≥ 0.8). Generic names ("New folder")
//      never match on name alone.
//   4. Matches are merged with union-find; groups are processed top-down and a member that
//      has an ancestor inside the same or an already reported group is dropped, so only the
//      highest matching level is reported.

import Foundation
import KlaDModels

public struct SimilarFolderDetector: SimilarFolderDetecting {
    public init() {}

    /// Allocation sizes are compared in 4 KiB steps.
    private static let sizeQuantum: UInt64 = 4096
    private static let minimumJaccard = 0.8
    /// Hard stop for pathological name buckets (e.g. thousands of folders called "src").
    private static let comparisonBudget = 4_000_000

    // MARK: - Entry point

    public func findSimilarFolders(in root: FileTreeNode, minimumBytes: UInt64) -> [SimilarFolderGroup] {
        if root.isOpaque || root.isProtectedLocation || Self.isTrashTarget(root) { return [] }

        // ── 1. Candidates ────────────────────────────────────────────────────────────
        var nodes: [FileTreeNode] = []
        var depths: [Int] = []
        var stack: [(node: FileTreeNode, depth: Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            for child in node.children where child.kind == .directory {
                if child.isOpaque || child.isProtectedLocation || child.flags.contains(.package) { continue }
                if Self.isTrashTarget(child) { continue }
                if child.metrics.allocatedBytes < minimumBytes { continue }   // prune: descendants are smaller
                if !child.hasChildren { continue }
                if !child.flags.isDisjoint(with: [.excluded, .unreadable, .mountPoint]) { continue }
                nodes.append(child)
                depths.append(depth + 1)
                stack.append((child, depth + 1))
            }
        }
        let count = nodes.count
        guard count >= 2 else { return [] }

        // ── 2. Content fingerprints, identical classes ──────────────────────────────
        // `nodes` lists parents before their children, so a reverse pass sees child digests first.
        var fingerprints = [UInt64](repeating: 0, count: count)
        var deepDigests: [ObjectIdentifier: UInt64] = [:]
        deepDigests.reserveCapacity(count)
        var i = count - 1
        while i >= 0 {
            let digest = Self.fingerprint(of: nodes[i], subfolderDigests: deepDigests)
            fingerprints[i] = digest
            deepDigests[ObjectIdentifier(nodes[i])] = digest
            i -= 1
        }

        var sets = DisjointSets(count: count)
        var byFingerprint = Array(0..<count)
        byFingerprint.sort { fingerprints[$0] != fingerprints[$1] ? fingerprints[$0] < fingerprints[$1] : $0 < $1 }
        var run = 0
        while run < count {
            var end = run + 1
            while end < count && fingerprints[byFingerprint[end]] == fingerprints[byFingerprint[run]] { end += 1 }
            if end - run >= 2 {
                for k in (run + 1)..<end { sets.union(byFingerprint[run], byFingerprint[k]) }
            }
            run = end
        }

        // ── 3. Name variants ───────────────────────────────────────────────────────
        var nameHashes = [UInt64](repeating: 0, count: count)
        var isVariantName = [Bool](repeating: false, count: count)
        var isGeneric = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let normalized = FolderNames.normalize(nodes[i].name)
            var hasher = Hasher()
            hasher.combine(normalized.key)
            nameHashes[i] = UInt64(bitPattern: Int64(hasher.finalize()))
            isVariantName[i] = normalized.isVariant
            isGeneric[i] = normalized.isGeneric
        }

        struct Edge { var a: Int; var b: Int; var similarity: Double }
        var edges: [Edge] = []
        var budget = Self.comparisonBudget

        var byName = Array(0..<count)
        byName.sort { nameHashes[$0] != nameHashes[$1] ? nameHashes[$0] < nameHashes[$1] : $0 < $1 }
        run = 0
        while run < count {
            var end = run + 1
            while end < count && nameHashes[byName[end]] == nameHashes[byName[run]] { end += 1 }
            defer { run = end }
            guard end - run >= 2, !isGeneric[byName[run]], budget > 0 else { continue }

            // One representative per identical-content class, ordered by size.
            var seenRoots = Set<Int>()
            var reps: [Int] = []
            for k in run..<end where seenRoots.insert(sets.find(byName[k])).inserted { reps.append(byName[k]) }
            guard reps.count >= 2 else { continue }
            reps.sort { a, b in
                let x = nodes[a].metrics.allocatedBytes, y = nodes[b].metrics.allocatedBytes
                return x != y ? x < y : a < b
            }
            var childNames: [Int: [Int]] = [:]
            func names(_ index: Int) -> [Int] {
                if let cached = childNames[index] { return cached }
                let sorted = nodes[index].children.map(\.name.hashValue).sorted()
                childNames[index] = sorted
                return sorted
            }

            for i in 0..<reps.count {
                let small = nodes[reps[i]].metrics.allocatedBytes
                for j in (i + 1)..<reps.count {
                    let large = nodes[reps[j]].metrics.allocatedBytes
                    if small &* 100 < large &* 85 { break }                // sorted ascending: no later j fits either
                    if budget <= 0 { break }
                    budget -= 1
                    let a = reps[i], b = reps[j]
                    if sets.find(a) == sets.find(b) { continue }
                    let left = names(a), right = names(b)
                    let low = min(left.count, right.count), high = max(left.count, right.count)
                    if Double(low) < Self.minimumJaccard * Double(high) { continue }
                    let similarity = Self.jaccard(left, right)
                    if similarity < Self.minimumJaccard { continue }
                    if Self.isAncestor(nodes[a], of: nodes[b]) || Self.isAncestor(nodes[b], of: nodes[a]) { continue }
                    sets.union(a, b)
                    edges.append(Edge(a: a, b: b, similarity: similarity))
                }
            }
        }

        // ── 4. Components → candidate groups ───────────────────────────────────────
        var weakestEdge: [Int: Double] = [:]
        for edge in edges {
            let r = sets.find(edge.a)
            weakestEdge[r] = min(weakestEdge[r] ?? 1, edge.similarity)
        }
        var components: [Int: [Int]] = [:]
        for i in 0..<count where sets.size(of: i) >= 2 { components[sets.find(i), default: []].append(i) }

        struct Pending {
            var members: [Int]
            var kind: SimilarFolderGroup.MatchKind
            var similarity: Double
            var minDepth: Int
            var bytes: UInt64
        }
        var pending: [Pending] = components.map { root, members in
            let similarity = weakestEdge[root]
            return Pending(
                members: members,
                kind: similarity == nil ? .identicalContents : .nameVariants,
                similarity: similarity ?? 1.0,
                minDepth: members.map { depths[$0] }.min() ?? 0,
                bytes: members.map { nodes[$0].metrics.allocatedBytes }.max() ?? 0
            )
        }
        // Top-down: shallow groups first so deeper matches inside them are suppressed.
        pending.sort { a, b in
            if a.minDepth != b.minDepth { return a.minDepth < b.minDepth }
            if a.kind != b.kind { return a.kind == .identicalContents }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return a.members.min() ?? 0 < b.members.min() ?? 0
        }

        var reported = Set<ObjectIdentifier>()
        var groups: [SimilarFolderGroup] = []
        for candidate in pending {
            let memberIDs = Set(candidate.members.map { ObjectIdentifier(nodes[$0]) })
            let kept = candidate.members.filter { index in
                var cursor = nodes[index].parent
                while let ancestor = cursor {
                    let id = ObjectIdentifier(ancestor)
                    if memberIDs.contains(id) || reported.contains(id) { return false }
                    cursor = ancestor.parent
                }
                return true
            }
            guard kept.count >= 2 else { continue }
            for index in kept { reported.insert(ObjectIdentifier(nodes[index])) }
            groups.append(Self.makeGroup(
                kept, nodes: nodes, isVariantName: isVariantName,
                kind: candidate.kind, similarity: candidate.similarity
            ))
        }

        groups.sort { a, b in
            if a.reclaimableBytes != b.reclaimableBytes { return a.reclaimableBytes > b.reclaimableBytes }
            return a.id < b.id
        }
        return groups
    }

    // MARK: - Group assembly

    private static func makeGroup(
        _ members: [Int], nodes: [FileTreeNode], isVariantName: [Bool],
        kind: SimilarFolderGroup.MatchKind, similarity: Double
    ) -> SimilarFolderGroup {
        struct Entry { let index: Int; let path: String }
        var entries = members.map { Entry(index: $0, path: nodes[$0].path) }
        // "Original first": not a copy-named variant, then the oldest content, then the shortest path.
        entries.sort { a, b in
            let av = isVariantName[a.index], bv = isVariantName[b.index]
            if av != bv { return !av }
            let at = nodes[a.index].newestModificationTime, bt = nodes[b.index].newestModificationTime
            if at != bt { return at < bt }
            if a.path.utf8.count != b.path.utf8.count { return a.path.utf8.count < b.path.utf8.count }
            return a.path < b.path
        }
        let folders = entries.map {
            SimilarFolder(path: $0.path, metrics: nodes[$0.index].metrics,
                          newestModificationTime: nodes[$0.index].newestModificationTime)
        }
        let reclaimable = folders.dropFirst().reduce(UInt64(0)) { $0 &+ $1.metrics.privateBytes }
        let first = entries[0]
        let name = nodes[first.index].name
        return SimilarFolderGroup(
            id: stableID(paths: entries.map(\.path)),
            title: FolderNames.baseName(of: name),
            kind: kind,
            similarity: similarity,
            folders: folders,
            reclaimableBytes: reclaimable
        )
    }

    /// FNV-1a over the sorted paths — stable across runs (unlike `Hasher`).
    private static func stableID(paths: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for path in paths.sorted() {
            for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            hash = (hash ^ 0x0A) &* 0x100000001b3
        }
        return "similar-" + String(hash, radix: 16)
    }

    // MARK: - Helpers

    private static func isTrashTarget(_ node: FileTreeNode) -> Bool {
        node.annotation?.safety.permitsTrash == true
    }

    private static func isAncestor(_ candidate: FileTreeNode, of node: FileTreeNode) -> Bool {
        var cursor = node.parent
        while let c = cursor {
            if c === candidate { return true }
            cursor = c.parent
        }
        return false
    }

    /// Order-independent hash of (name, kind, allocated rounded up to 4 KiB) of the direct children + counts.
    /// A subfolder with a known digest contributes that digest (its whole structure) instead of its size;
    /// other subfolders (below the minimum size, packages, …) fall back to size + item counts.
    private static func fingerprint(of directory: FileTreeNode, subfolderDigests: [ObjectIdentifier: UInt64]) -> UInt64 {
        var sum: UInt64 = 0
        for child in directory.children {
            var hasher = Hasher()
            hasher.combine(child.name)
            hasher.combine(child.kind.rawValue)
            if child.kind == .directory, let digest = subfolderDigests[ObjectIdentifier(child)] {
                hasher.combine(digest)
            } else {
                hasher.combine((child.metrics.allocatedBytes &+ (sizeQuantum - 1)) / sizeQuantum)
                if child.kind == .directory {
                    hasher.combine(child.metrics.fileCount)
                    hasher.combine(child.metrics.directoryCount)
                }
            }
            sum &+= UInt64(bitPattern: Int64(hasher.finalize()))
        }
        var hasher = Hasher()
        hasher.combine(sum)
        hasher.combine(directory.children.count)
        hasher.combine(directory.metrics.fileCount)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// |A ∩ B| / |A ∪ B| for two sorted arrays of unique values.
    private static func jaccard(_ a: [Int], _ b: [Int]) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        var i = 0, j = 0, common = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { common += 1; i += 1; j += 1 }
            else if a[i] < b[j] { i += 1 }
            else { j += 1 }
        }
        return Double(common) / Double(a.count + b.count - common)
    }
}

// MARK: - Union-find

private struct DisjointSets {
    private var parent: [Int]
    private var sizes: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        sizes = [Int](repeating: 1, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var cursor = x
        while parent[cursor] != root {
            let next = parent[cursor]
            parent[cursor] = root
            cursor = next
        }
        return root
    }

    mutating func size(of x: Int) -> Int { sizes[find(x)] }

    mutating func union(_ a: Int, _ b: Int) {
        var ra = find(a), rb = find(b)
        if ra == rb { return }
        if sizes[ra] < sizes[rb] { swap(&ra, &rb) }
        parent[rb] = ra
        sizes[ra] += sizes[rb]
    }
}

// MARK: - Folder name normalisation

enum FolderNames {
    struct Normalized {
        /// Lower-cased base name with copy / version / backup decorations removed.
        var key: String
        /// True when something was stripped (the folder looks like a copy or variant).
        var isVariant: Bool
        /// "new folder" and friends — meaningless without identical contents.
        var isGeneric: Bool
    }

    static let genericNames: Set<String> = ["new folder", "untitled folder", "folder", "untitled", "new"]

    private static let space: UInt8 = 0x20
    private static let wordSuffixes: [[UInt8]] = ["copy", "old", "backup", "final"].map { Array($0.utf8) }
    private static let copyPrefix: [UInt8] = Array("copy of ".utf8)

    static func normalize(_ name: String) -> Normalized {
        var bytes = collapsed(name)
        let originalCount = bytes.count
        stripDecorations(&bytes)
        let key = String(decoding: bytes, as: UTF8.self)
        return Normalized(key: key, isVariant: bytes.count != originalCount, isGeneric: genericNames.contains(key))
    }

    /// The base name in the original casing ("kd - Copy" → "kd").
    static func baseName(of name: String) -> String {
        let normalized = normalize(name)
        guard normalized.isVariant else { return name }
        let prefix = String(name.prefix(normalized.key.count))
        return prefix.lowercased() == normalized.key ? prefix : normalized.key
    }

    /// Lower-cased, whitespace runs collapsed to one space, trimmed.
    private static func collapsed(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(name.utf8.count)
        var pendingSpace = false
        for byte in name.lowercased().utf8 {
            if byte == space || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(space); pendingSpace = false }
            out.append(byte)
        }
        return out
    }

    private static func isSeparator(_ byte: UInt8) -> Bool { byte == space || byte == 0x2D || byte == 0x5F }   // ' ' '-' '_'
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func trimTrailingSeparators(_ bytes: inout [UInt8]) {
        while let last = bytes.last, isSeparator(last) { bytes.removeLast() }
    }

    /// Repeatedly removes one trailing decoration until none is left. Never produces an empty name.
    private static func stripDecorations(_ bytes: inout [UInt8]) {
        if bytes.starts(with: copyPrefix), bytes.count > copyPrefix.count {
            bytes.removeFirst(copyPrefix.count)
        }
        for _ in 0..<8 {
            guard let shorter = strippedOnce(bytes), !shorter.isEmpty else { return }
            bytes = shorter
        }
    }

    private static func strippedOnce(_ bytes: [UInt8]) -> [UInt8]? {
        guard let last = bytes.last else { return nil }

        // "(N)"
        if last == 0x29, let open = bytes.lastIndex(of: 0x28) {
            let inside = bytes[(open + 1)..<(bytes.count - 1)]
            if !inside.isEmpty && inside.allSatisfy(isDigit) && open > 0 {
                var result = Array(bytes[..<open])
                trimTrailingSeparators(&result)
                return result
            }
        }

        // " N", "_vN", "-vN", " vN"
        if isDigit(last) {
            var digitsStart = bytes.count
            while digitsStart > 0 && isDigit(bytes[digitsStart - 1]) { digitsStart -= 1 }
            if digitsStart >= 2 {
                if bytes[digitsStart - 1] == space {
                    var result = Array(bytes[..<(digitsStart - 1)])
                    trimTrailingSeparators(&result)
                    return result
                }
                if bytes[digitsStart - 1] == 0x76, isSeparator(bytes[digitsStart - 2]) {     // "v"
                    var result = Array(bytes[..<(digitsStart - 2)])
                    trimTrailingSeparators(&result)
                    return result
                }
            }
            return nil
        }

        // " copy", " - copy", "_old", " old", "_backup", " backup", "-final"
        for word in wordSuffixes where bytes.count > word.count + 1 {
            let cut = bytes.count - word.count
            if bytes[cut...].elementsEqual(word) && isSeparator(bytes[cut - 1]) {
                var result = Array(bytes[..<cut])
                trimTrailingSeparators(&result)
                return result
            }
        }
        return nil
    }
}
