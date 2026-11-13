// ClassificationEngine.swift — KlaDIntelligence
//
// Annotates a scanned tree in place and builds cleanup recommendations.
// Three iterative O(n) passes (trees can be 100+ levels deep — no recursion):
//   1. top-down: evaluate rules, annotate matches, emit recommendations,
//      carry the inherited rule category;
//   2. bottom-up (reverse pre-order): assign `category` to every node;
//   3. totals: Σ leaf contributions per category.
//
// Convention shared with `DeveloperRulesCatalog`: a match whose ruleID starts with
// "category." only contributes its category — no annotation, no recommendation.
//
// System policy (KlaDModels.SystemPolicy):
//   • `.opaque` accounting nodes keep the scanner's annotation and category and are
//     never evaluated by rules;
//   • `.protectedLocation` nodes are annotated `doNotDelete` (never recommended);
//   • a match whose action is `.moveToTrash` is downgraded to `.inspectOnly` (and not
//     recommended) when `SystemPolicy.mayModify` says KlaD may never touch that path.

import Foundation
import KlaDModels

public final class ClassificationEngine: StorageClassifying {
    private let catalog: any DeveloperRulesCataloging

    public init(catalog: any DeveloperRulesCataloging = DeveloperRulesCatalog()) {
        self.catalog = catalog
    }

    private static let noCategory: UInt8 = .max
    static let protectedRuleID = "system.protected_location"
    private static let categories: [StorageCategory] = {
        // rawValue is the index (contiguous 0…n-1).
        StorageCategory.allCases.sorted { $0.rawValue < $1.rawValue }
    }()

    private struct Frame {
        let node: FileTreeNode
        /// Parent path with trailing "/" (unused for the root and for disabled subtrees).
        let prefix: String
        /// Rule category inherited from the nearest matched ancestor.
        let inherited: UInt8
        /// False below a match with `descend == false`.
        let enabled: Bool
        let isRoot: Bool
    }

    public func classify(root: FileTreeNode, context: ClassificationContext) -> ClassificationResult {
        let expected = Int(min(UInt64(8_000_000), root.metrics.itemCount + 1))
        var order: [FileTreeNode] = []
        var ruleCategory: [UInt8] = []
        order.reserveCapacity(expected)
        ruleCategory.reserveCapacity(expected)

        var recommendations: [CleanupRecommendation] = []
        var annotated = 0

        // ── Pass 1: top-down rules ───────────────────────────────────────────────
        var stack: [Frame] = [Frame(node: root, prefix: "", inherited: Self.noCategory, enabled: true, isRoot: true)]
        while let frame = stack.popLast() {
            let node = frame.node
            let isOpaque = node.isOpaque
            // Idempotent re-classification — except the scanner's annotation on opaque nodes.
            if !isOpaque && node.annotation != nil { node.annotation = nil }

            var category = frame.inherited
            var childrenEnabled = frame.enabled
            var childPrefix = ""

            if isOpaque {
                // Synthetic accounting node ("macOS System (sealed)"): no rules, keep category.
                category = node.category.rawValue
                childrenEnabled = false
            } else if node.isProtectedLocation {
                let path = frame.isRoot ? root.path : (frame.enabled ? frame.prefix + node.name : node.path)
                let location = SystemPolicy.protectedLocation(containing: path, home: context.homeDirectory)
                category = (location?.category ?? .system).rawValue
                node.annotation = NodeAnnotation(
                    ruleID: Self.protectedRuleID,
                    title: location?.title ?? "Protected macOS data",
                    safety: .doNotDelete,
                    group: .system,
                    reason: location?.explanation ?? "Private macOS data that KlaD never opens or modifies."
                )
                annotated += 1
                childrenEnabled = false
            } else if frame.enabled {
                let path = frame.isRoot ? root.path : frame.prefix + node.name
                if let match = catalog.match(node: node, path: path, context: context) {
                    category = match.category.rawValue
                    childrenEnabled = match.descend
                    if !match.ruleID.hasPrefix("category.") {
                        node.annotation = NodeAnnotation(
                            ruleID: match.ruleID, title: match.title, safety: match.safety,
                            group: match.group, reason: Self.reason(for: match)
                        )
                        annotated += 1
                        // Never offer the Trash outside what SystemPolicy lets KlaD modify.
                        let blocked = match.action.isTrashable && !SystemPolicy.mayModify(path, home: context.homeDirectory)
                        if match.recommend && !blocked && node.metrics.allocatedBytes >= context.minimumRecommendationBytes {
                            recommendations.append(Self.recommendation(for: node, path: path, match: match, context: context))
                        }
                    }
                }
                if childrenEnabled && node.hasChildren {
                    childPrefix = path.hasSuffix("/") ? path : path + "/"
                }
            }

            order.append(node)
            ruleCategory.append(category)

            for child in node.children {
                stack.append(Frame(node: child, prefix: childPrefix, inherited: category, enabled: childrenEnabled, isRoot: false))
            }
        }

        // ── Pass 2 + 3: categories bottom-up, totals ──────────────────────────────────
        var totals = [StorageMetrics](repeating: .zero, count: Self.categories.count)
        var allocatedByCategory = [UInt64](repeating: 0, count: Self.categories.count)
        var logicalByCategory = [UInt64](repeating: 0, count: Self.categories.count)

        var index = order.count - 1
        while index >= 0 {
            defer { index -= 1 }
            let node = order[index]
            let inherited = ruleCategory[index]

            let category: StorageCategory
            if inherited != Self.noCategory {
                category = Self.categories[Int(inherited)]
            } else {
                switch node.kind {
                case .directory:
                    category = Self.dominantCategory(of: node, allocated: &allocatedByCategory, logical: &logicalByCategory)
                case .file:
                    category = catalog.categoryHint(forFileNamed: node.name) ?? .other
                case .symlink, .other:
                    category = .other
                }
            }
            node.category = category

            if node.kind != .directory {
                totals[Int(category.rawValue)].add(node.aggregateContribution)
            } else if !node.hasChildren {
                // A childless directory that still carries bytes (excluded / unreadable stub):
                // count them so the totals always add up to the root's metrics.
                var own = node.metrics
                own.directoryCount = 0
                own.fileCount = 0
                if !own.isEmpty { totals[Int(category.rawValue)].add(own) }
            }
        }

        var categoryTotals: [StorageCategory: StorageMetrics] = [:]
        for category in Self.categories {
            let metrics = totals[Int(category.rawValue)]
            if !metrics.isEmpty || metrics.fileCount > 0 { categoryTotals[category] = metrics }
        }

        recommendations.sort { a, b in
            if a.reclaimableBytes != b.reclaimableBytes { return a.reclaimableBytes > b.reclaimableBytes }
            return a.path < b.path
        }
        return ClassificationResult(recommendations: recommendations, categoryTotals: categoryTotals, annotatedNodeCount: annotated)
    }

    // MARK: - Directory category

    /// Category with the most allocated bytes among the children (logical bytes when everything
    /// is zero-allocation, e.g. a folder of iCloud placeholders); ties go to the lower raw value.
    private static func dominantCategory(
        of directory: FileTreeNode,
        allocated: inout [UInt64],
        logical: inout [UInt64]
    ) -> StorageCategory {
        for i in 0..<allocated.count { allocated[i] = 0; logical[i] = 0 }
        var anyAllocated = false
        var anyLogical = false
        for child in directory.children where !child.flags.contains(.hardLinkDuplicate) {
            let slot = Int(child.category.rawValue)
            let a = child.metrics.allocatedBytes
            let l = child.metrics.logicalBytes
            if a > 0 { allocated[slot] &+= a; anyAllocated = true }
            if l > 0 { logical[slot] &+= l; anyLogical = true }
        }
        guard anyAllocated || anyLogical else { return .other }
        let weights = anyAllocated ? allocated : logical
        var best = 0
        for i in 1..<weights.count where weights[i] > weights[best] { best = i }
        return categories[best]
    }

    // MARK: - Recommendations

    private static func reason(for match: RuleMatch) -> String {
        if match.evidence.isEmpty { return match.rationale }
        let details = match.evidence.prefix(3).map(\.detail)
        return details.joined(separator: "; ")
    }

    /// Defense in depth: only safeToClear / reviewFirst may ever carry `.moveToTrash`.
    private static func sanitized(_ action: CleanupAction, safety: SafetyLevel) -> CleanupAction {
        if case .moveToTrash = action, !safety.permitsTrash { return .inspectOnly }
        return action
    }

    private static func recommendation(
        for node: FileTreeNode, path: String, match: RuleMatch, context: ClassificationContext
    ) -> CleanupRecommendation {
        var signals = match.signals

        // Subtree facts: newest mtime and share of hard-linked bytes.
        var newest = node.modificationTime
        var hardLinkedBytes: UInt64 = 0
        node.walk { descendant in
            if descendant.modificationTime > newest { newest = descendant.modificationTime }
            if descendant.kind != .directory,
               descendant.flags.contains(.hardLinked),
               !descendant.flags.contains(.hardLinkDuplicate) {
                hardLinkedBytes &+= descendant.metrics.allocatedBytes
            }
            return .continue
        }

        let ageDays = max(0, Int(((context.now.timeIntervalSince1970 - Double(newest)) / 86_400).rounded(.down)))
        signals.append(ageDays >= context.inactivityThresholdDays ? .inactive(days: ageDays) : .recentlyModified(days: ageDays))

        let allocated = node.metrics.allocatedBytes
        if allocated > 0 && hardLinkedBytes &* 2 > allocated {
            signals.append(.hardLinkedContent)
        }
        if allocated > 0 && node.metrics.sharedBytes &* 4 > allocated {
            signals.append(.cloneSharedContent)
        }

        return CleanupRecommendation(
            ruleID: match.ruleID,
            title: match.title,
            path: path,
            category: match.category,
            safety: match.safety,
            group: match.group,
            metrics: node.metrics,
            rationale: match.rationale,
            evidence: match.evidence,
            signals: signals,
            action: sanitized(match.action, safety: match.safety),
            regenerateCommand: match.regenerateCommand,
            warnings: match.warnings,
            identity: node.identity
        )
    }
}
