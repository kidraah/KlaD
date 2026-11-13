// InventoryReporter.swift — KlaDIntelligence
//
// Tree-only inventory queries (no disk I/O):
//   • largestFiles — bounded min-heap, O(n log k); paths are only built for the
//     handful of nodes that survive (and for exact-size ties);
//   • fileTypes    — one pass, per-extension accumulators keyed by the packed
//     extension from `NameKeys` (no String allocation per file).
// Both walks are iterative (trees can be 100+ levels deep).

import Foundation
import KlaDModels

public struct InventoryReporter: InventoryReporting {
    public init() {}

    // MARK: - Largest files

    private struct HeapEntry {
        let value: UInt64
        let node: FileTreeNode
    }

    /// Min-heap on "worse first": smaller value, then (for equal values) the path that sorts LATER.
    /// The root is therefore always the entry that would be evicted next.
    private struct BoundedHeap {
        private(set) var items: [HeapEntry] = []
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            items.reserveCapacity(min(capacity, 4096))
        }

        var isFull: Bool { items.count >= capacity }
        var minimumValue: UInt64 { items.first?.value ?? 0 }

        /// True when `a` should be evicted before `b`.
        private static func isWorse(_ a: HeapEntry, _ b: HeapEntry) -> Bool {
            if a.value != b.value { return a.value < b.value }
            return a.node.path > b.node.path
        }

        mutating func offer(_ entry: HeapEntry) {
            if items.count < capacity {
                items.append(entry)
                siftUp(items.count - 1)
            } else if Self.isWorse(items[0], entry) {
                items[0] = entry
                siftDown(0)
            }
        }

        private mutating func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                if Self.isWorse(items[child], items[parent]) {
                    items.swapAt(child, parent)
                    child = parent
                } else { break }
            }
        }

        private mutating func siftDown(_ start: Int) {
            var parent = start
            let count = items.count
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var worst = parent
                if left < count, Self.isWorse(items[left], items[worst]) { worst = left }
                if right < count, Self.isWorse(items[right], items[worst]) { worst = right }
                if worst == parent { return }
                items.swapAt(parent, worst)
                parent = worst
            }
        }
    }

    public func largestFiles(in root: FileTreeNode, limit: Int, measure: SizeMeasure) -> [LargeFileEntry] {
        guard limit > 0 else { return [] }
        var heap = BoundedHeap(capacity: limit)

        var stack: [FileTreeNode] = [root]
        while let node = stack.popLast() {
            if node.isOpaque || node.isProtectedLocation { continue }
            switch node.kind {
            case .directory:
                stack.append(contentsOf: node.children)
            case .file:
                let flags = node.flags
                if flags.contains(.hardLinkDuplicate) { continue }
                // Evicted iCloud placeholders occupy nothing on disk.
                if flags.contains(.cloudPlaceholder) && measure != .logical { continue }
                let value = node.metrics.value(for: measure)
                if value == 0 { continue }
                // Cheap rejection before the (rare) tie-break that needs paths.
                if heap.isFull && value < heap.minimumValue { continue }
                heap.offer(HeapEntry(value: value, node: node))
            case .symlink, .other:
                continue
            }
        }

        let sorted = heap.items
            .map { (value: $0.value, node: $0.node, path: $0.node.path) }
            .sorted { a, b in a.value != b.value ? a.value > b.value : a.path < b.path }
        return sorted.map { entry in
            LargeFileEntry(
                path: entry.path,
                metrics: entry.node.metrics,
                category: entry.node.category,
                modificationTime: entry.node.modificationTime,
                flags: entry.node.flags
            )
        }
    }

    // MARK: - File types

    private static let categoryCount = StorageCategory.allCases.count

    private struct TypeAccumulator {
        var fileCount = 0
        var metrics = StorageMetrics.zero
        var allocatedByCategory = [UInt64](repeating: 0, count: InventoryReporter.categoryCount)
        var logicalByCategory = [UInt64](repeating: 0, count: InventoryReporter.categoryCount)
        var filesByCategory = [Int](repeating: 0, count: InventoryReporter.categoryCount)
        var largest: FileTreeNode?
        var largestWeight: UInt64 = 0

        mutating func add(_ node: FileTreeNode) {
            fileCount += 1
            let contribution = node.aggregateContribution
            metrics.add(contribution)
            let slot = Int(node.category.rawValue)
            allocatedByCategory[slot] &+= contribution.allocatedBytes
            logicalByCategory[slot] &+= contribution.logicalBytes
            filesByCategory[slot] += 1
            let weight = node.metrics.allocatedBytes > 0 ? node.metrics.allocatedBytes : node.metrics.logicalBytes
            if largest == nil || weight > largestWeight {
                largest = node
                largestWeight = weight
            }
        }

        /// Category holding the most bytes (allocated; logical for all-placeholder types; file count as a last resort).
        var dominantCategory: StorageCategory {
            func argmax<T: Comparable>(_ values: [T], zero: T) -> Int? {
                var best = -1
                for i in values.indices where values[i] > zero && (best < 0 || values[i] > values[best]) { best = i }
                return best < 0 ? nil : best
            }
            let slot = argmax(allocatedByCategory, zero: 0)
                ?? argmax(logicalByCategory, zero: 0)
                ?? argmax(filesByCategory, zero: 0)
                ?? Int(StorageCategory.other.rawValue)
            return StorageCategory.allCases.first { Int($0.rawValue) == slot } ?? .other
        }
    }

    public func fileTypes(in root: FileTreeNode, limit: Int) -> [FileTypeSummary] {
        guard limit > 0 else { return [] }
        // Packed key (≤ 8 ASCII bytes) for the overwhelmingly common case; Strings only for longer extensions.
        var short: [UInt64: TypeAccumulator] = [:]
        var long: [String: TypeAccumulator] = [:]

        var stack: [FileTreeNode] = [root]
        while let node = stack.popLast() {
            if node.isOpaque || node.isProtectedLocation { continue }
            switch node.kind {
            case .directory:
                stack.append(contentsOf: node.children)
            case .file:
                let key = NameKeys.extensionKey(node.name)
                if key == NameKeys.longExtension {
                    long[Self.longExtension(of: node.name), default: TypeAccumulator()].add(node)
                } else {
                    short[key, default: TypeAccumulator()].add(node)
                }
            case .symlink, .other:
                continue
            }
        }

        var summaries: [(summary: FileTypeSummary, node: FileTreeNode)] = []
        summaries.reserveCapacity(short.count + long.count)
        for (key, accumulator) in short {
            if let entry = Self.summary(key: Self.string(fromPackedKey: key), accumulator) { summaries.append(entry) }
        }
        for (key, accumulator) in long {
            if let entry = Self.summary(key: key, accumulator) { summaries.append(entry) }
        }
        summaries.sort { a, b in
            let x = a.summary.metrics, y = b.summary.metrics
            if x.allocatedBytes != y.allocatedBytes { return x.allocatedBytes > y.allocatedBytes }
            if x.logicalBytes != y.logicalBytes { return x.logicalBytes > y.logicalBytes }
            if a.summary.fileCount != b.summary.fileCount { return a.summary.fileCount > b.summary.fileCount }
            return a.summary.key < b.summary.key
        }
        // Paths only for the types that are returned.
        return summaries.prefix(limit).map { entry in
            var summary = entry.summary
            summary.largestPath = entry.node.path
            return summary
        }
    }

    private static func summary(key: String, _ accumulator: TypeAccumulator) -> (summary: FileTypeSummary, node: FileTreeNode)? {
        guard let largest = accumulator.largest else { return nil }
        let summary = FileTypeSummary(
            key: key, fileCount: accumulator.fileCount, metrics: accumulator.metrics,
            category: accumulator.dominantCategory, largestPath: ""
        )
        return (summary, largest)
    }

    /// Decodes `NameKeys.extensionKey` output (0 → "").
    private static func string(fromPackedKey key: UInt64) -> String {
        guard key != 0 else { return "" }
        var bytes: [UInt8] = []
        var rest = key
        while rest != 0 {
            bytes.append(UInt8(truncatingIfNeeded: rest & 0xFF))
            rest >>= 8
        }
        return String(decoding: bytes.reversed(), as: UTF8.self)
    }

    /// Lower-cased extension of a name known to have one longer than 8 bytes.
    private static func longExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}
