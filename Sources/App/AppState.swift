// AppState.swift — composition root& single source of truth
//
// Owns every service and the published tree. Threading follows the
// FileTreeNode contract: scan + classification + snapshot capture + duplicate
// candidate collection all run off-main BEFORE publication; after publication
// the tree is only mutated here, on the MainActor (cleanup removals and
// FSEvents-driven subtree splices), each mutation bumping `treeVersion`.

import AppKit
import Foundation
import Observation
import SwiftUI
import KlaDIntelligence
import KlaDModels
import KlaDScanner
import KlaDStorageOps

struct CleanupRequest: Identifiable {
    let id = UUID()
    let target: CleanupTarget
    let recommendation: CleanupRecommendation?
    /// Extra context for duplicates ("Keeping …/original.mov").
    let note: String?

    var requiresAcknowledgement: Bool { target.safety.requiresExplicitReview }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
}

@MainActor
@Observable
final class AppState {
    enum Tab: String, CaseIterable, Identifiable {
        case explore, saveSpace, history
        var id: String { rawValue }
        var title: String {
            switch self {
            case .explore: return "Explore"
            case .saveSpace: return "Save Space"
            case .history: return "History"
            }
        }
        var symbol: String {
            switch self {
            case .explore: return "circle.hexagongrid.circle"
            case .saveSpace: return "sparkles"
            case .history: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
            }
        }
    }

    enum ScanPhase: Equatable {
        case idle
        case scanning
        case analyzing
        case ready
        case failed(String)
    }

    // MARK: Navigation
    var tab: Tab = .explore
    var visualizerMode: VisualizerMode = .sunburst
    var measure: SizeMeasure = .allocated

    // MARK: Scan
    var phase: ScanPhase = .idle
    var progress = ScanProgress()
    var scanRootPath: String = NSHomeDirectory()
    private(set) var result: ScanResult?
    private(set) var root: FileTreeNode?
    var focus: FileTreeNode?
    var selection: FileTreeNode?
    private(set) var treeVersion = 0
    private var scanTask: Task<Void, Never>?

    // MARK: Volume
    private(set) var volume: VolumeSpaceReport?

    // MARK: Intelligence
    private(set) var recommendations: [CleanupRecommendation] = []
    private(set) var categoryTotals: [StorageCategory: StorageMetrics] = [:]

    // MARK: Duplicates
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var duplicateProgress: DuplicateScanProgress?
    private(set) var isFindingDuplicates = false
    private(set) var duplicatesSearched = false
    private var duplicateCandidates: [DuplicateCandidate] = []
    private var duplicateTask: Task<Void, Never>?

    // MARK: History
    private(set) var snapshots: [ScanSnapshotSummary] = []
    private(set) var diff: SnapshotDiff?
    var diffBaseID: UUID?
    private(set) var historyError: String?

    // MARK: Watcher
    private(set) var dirtyPaths: [DirtyPath] = []
    /// FSEvents asked for a recursive rescan of the scan root itself.
    private(set) var needsFullRescan = false
    var autoRescan = true
    private(set) var isRescanning = false
    private(set) var lastRescanSummary: String?
    private var watchTask: Task<Void, Never>?
    private var rescanDebounce: Task<Void, Never>?

    // MARK: Cleanup
    var cleanupRequest: CleanupRequest?
    var toast: Toast?
    private(set) var reclaimedThisSession: UInt64 = 0
    private(set) var trashedThisSession: UInt64 = 0

    // MARK: Services
    let scanner: any StorageScanning
    let volumeInspector: any VolumeInspecting
    let classifier: any StorageClassifying
    let git: any GitRepositoryInspecting
    let history: (any SnapshotHistoryStoring)?
    let duplicates: any DuplicateDetecting
    let cleanup: any SafeCleanupPerforming
    let watcher: any FileSystemWatching

    init(
        scanner: any StorageScanning = BulkAPFSScanner(),
        volumeInspector: any VolumeInspecting = APFSVolumeInspector(),
        classifier: any StorageClassifying = ClassificationEngine(),
        git: any GitRepositoryInspecting = GitRepoInspector(),
        history: (any SnapshotHistoryStoring)? = try? SnapshotHistoryService(databaseURL: SnapshotHistoryService.defaultDatabaseURL()),
        duplicates: any DuplicateDetecting = DuplicateDetectorService(),
        cleanup: any SafeCleanupPerforming = SafeCleanupService(),
        watcher: any FileSystemWatching = FSEventsMonitor()
    ) {
        self.scanner = scanner
        self.volumeInspector = volumeInspector
        self.classifier = classifier
        self.git = git
        self.history = history
        self.duplicates = duplicates
        self.cleanup = cleanup
        self.watcher = watcher
    }

    // MARK: - Derived

    var isBusy: Bool { phase == .scanning || phase == .analyzing }

    var permissionIssues: [ScanIssue] { result?.issues.filter(\.isPermissionDenied) ?? [] }

    func recommendations(for safety: SafetyLevel) -> [CleanupRecommendation] {
        recommendations.filter { $0.safety == safety }
    }

    func reclaimable(for safety: SafetyLevel) -> UInt64 {
        recommendations(for: safety).reduce(0) { $0 + $1.reclaimableBytes }
    }

    /// Breadcrumb from the scan root to the focus.
    var focusChain: [FileTreeNode] {
        guard let focus else { return [] }
        return focus.ancestors + [focus]
    }

    // MARK: - Scanning

    func startScan(path: String) {
        cancelScan()
        stopWatching()
        duplicateTask?.cancel()
        scanRootPath = path
        phase = .scanning
        progress = ScanProgress()
        result = nil
        root = nil
        focus = nil
        selection = nil
        recommendations = []
        categoryTotals = [:]
        duplicateGroups = []
        duplicateCandidates = []
        duplicatesSearched = false
        dirtyPaths = []
        needsFullRescan = false
        diff = nil
        diffBaseID = nil
        lastRescanSummary = nil

        let scanner = self.scanner
        let classifier = self.classifier
        let inspector = self.volumeInspector
        let context = makeClassificationContext()

        scanTask = Task { [weak self] in
            async let volumeReport = inspector.report(forPath: path)
            do {
                let scanResult = try await scanner.scan(ScanOptions(rootPath: path)) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.phase == .scanning else { return }
                        self.progress = progress
                    }
                }
                if Task.isCancelled { return }
                self?.phase = .analyzing
                let processed = await Task.detached(priority: .userInitiated) {
                    PostProcessed(
                        classification: classifier.classify(root: scanResult.root, context: context),
                        snapshot: ScanSnapshot.capture(
                            from: scanResult.root,
                            startedAt: scanResult.startedAt,
                            completedAt: scanResult.completedAt,
                            volume: nil
                        ),
                        candidates: DuplicateCandidate.collect(from: scanResult.root, minimumBytes: 1 << 20)
                    )
                }.value
                let report = await volumeReport
                if Task.isCancelled { return }
                self?.publish(scanResult, processed, volume: report)
            } catch {
                if Task.isCancelled { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if isBusy { phase = root == nil ? .idle : .ready }
    }

    private struct PostProcessed: Sendable {
        let classification: ClassificationResult
        let snapshot: ScanSnapshot
        let candidates: [DuplicateCandidate]
    }

    private func publish(_ scanResult: ScanResult, _ processed: PostProcessed, volume report: VolumeSpaceReport?) {
        result = scanResult
        root = scanResult.root
        focus = scanResult.root
        selection = nil
        volume = report
        categoryTotals = processed.classification.categoryTotals
        recommendations = processed.classification.recommendations + syntheticRecommendations(volume: report)
        duplicateCandidates = processed.candidates
        treeVersion += 1
        phase = .ready

        var snapshot = processed.snapshot
        snapshot.volume = report
        Task { await self.saveAndReloadHistory(snapshot) }
        Task { await self.enrichWithGitSignals() }
        startWatching(path: scanResult.root.path)
    }

    private func makeClassificationContext() -> ClassificationContext {
        ClassificationContext(
            homeDirectory: NSHomeDirectory(),
            now: Date(),
            runningApplicationBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        )
    }

    /// Cards the rules engine can't produce from files alone.
    private func syntheticRecommendations(volume report: VolumeSpaceReport?) -> [CleanupRecommendation] {
        guard let report, !report.localSnapshotNames.isEmpty else { return [] }
        let names = report.localSnapshotNames
        let updateSnapshots = names.filter { $0.hasPrefix("com.apple.os.update") }.count
        let tmSnapshots = names.count - updateSnapshots
        var commands = [
            GuidedCommand(label: "List local snapshots", command: "tmutil listlocalsnapshots /", isDestructive: false),
        ]
        if tmSnapshots > 0 {
            commands.append(GuidedCommand(label: "Thin Time Machine snapshots (asks APFS to free up to 100 GB)",
                                          command: "tmutil thinlocalsnapshots / 100000000000 4", isDestructive: true))
        }
        let explanation = """
        \(names.count) local APFS snapshot\(names.count == 1 ? "" : "s") pin blocks of files you have since deleted or changed — \
        that space shows up as "System Data" and as the gap between Allocated and Reclaimable in KlaD. \
        \(updateSnapshots > 0 ? "\(updateSnapshots) belong to macOS Software Update and are released automatically after the update completes. " : "")\
        Time Machine snapshots expire on their own after 24 hours, or when macOS needs the space. \
        The volume currently reports \(formatBytes(report.purgeableCapacity)) as purgeable (snapshots, caches and evictable iCloud files combined).
        """
        return [CleanupRecommendation(
            ruleID: "apfs.local_snapshots",
            title: "Local APFS Snapshots",
            path: report.volumePath,
            category: .system,
            safety: .guidedExternalAction,
            group: .snapshots,
            metrics: .zero,   // snapshot sizes aren't exposed without root; see explanation
            rationale: "Snapshots are managed by macOS. Deleting snapshot data directly is impossible and unsafe; thin them with tmutil instead.",
            evidence: [Evidence(kind: .runtimeState, detail: "\(names.count) snapshot(s) reported by tmutil")],
            action: .guided(GuidedRemediation(headline: "Thin snapshots with tmutil", explanation: explanation, commands: commands)),
            identity: NodeIdentity(fileID: 0, deviceID: 0, modificationTime: 0)
        )]
    }

    // MARK: - Navigation

    func drill(into node: FileTreeNode) {
        guard node.isDirectory else {
            selection = node
            return
        }
        focus = node
        selection = node
    }

    func drillUp() {
        guard let parent = focus?.parent else { return }
        focus = parent
    }

    func select(_ node: FileTreeNode?) {
        selection = node
    }

    /// Selects a node by path (from Save Space / History), focusing its parent.
    func reveal(path: String, switchTo explore: Bool = true) {
        guard let root, let node = root.descendant(atPath: path) else { return }
        focus = node.isDirectory ? node : (node.parent ?? root)
        selection = node
        if explore { tab = .explore }
    }

    // MARK: - Volume

    func refreshVolume() {
        let path = root?.path ?? scanRootPath
        let inspector = volumeInspector
        Task { [weak self] in
            let report = await inspector.report(forPath: path)
            self?.volume = report
        }
    }

    // MARK: - Git enrichment

    private func enrichWithGitSignals() async {
        // git may read (and thus download) dataless files: skip iCloud-synced
        // Desktop/Documents (detected via sync-root flags or cloud stubs).
        let home = NSHomeDirectory()
        let syncedRoots = [home + "/Desktop", home + "/Documents"].filter { path in
            guard let node = root?.descendant(atPath: path) else { return false }
            return node.flags.contains(.syncRoot) || node.metrics.cloudStubBytes > 0
        } + [home + "/Library/Mobile Documents", home + "/Library/CloudStorage"]
        let candidates = recommendations
            .filter { $0.group == .buildArtifacts }
            .filter { rec in !syncedRoots.contains { rec.path.hasPrefix($0 + "/") } }
            .prefix(80)
            .map { (id: $0.id, path: ($0.path as NSString).deletingLastPathComponent) }
        guard !candidates.isEmpty else { return }
        let git = self.git
        let now = Date()
        let results = await withTaskGroup(of: (String, [SupportingSignal]).self) { group in
            var running = 0
            var output: [(String, [SupportingSignal])] = []
            for candidate in candidates {
                if running >= 6, let next = await group.next() {
                    output.append(next)
                    running -= 1
                }
                group.addTask { (candidate.id, await git.supportingSignals(forPath: candidate.path, now: now)) }
                running += 1
            }
            for await next in group { output.append(next) }
            return output
        }
        let byID = Dictionary(results, uniquingKeysWith: { a, _ in a })
        recommendations = recommendations.map { rec in
            guard let extra = byID[rec.id], !extra.isEmpty else { return rec }
            var updated = rec
            updated.signals.append(contentsOf: extra.filter { !rec.signals.contains($0) })
            return updated
        }
    }

    // MARK: - Cleanup

    func requestCleanup(_ recommendation: CleanupRecommendation) {
        guard recommendation.isTrashable else { return }
        let node = root?.descendant(atPath: recommendation.path)
        let target = CleanupTarget(
            path: recommendation.path,
            displayName: recommendation.title,
            safety: recommendation.safety,
            identity: recommendation.identity,
            metrics: node?.metrics ?? recommendation.metrics,
            conflictingApplicationBundleIDs: conflictingApps(for: recommendation.ruleID),
            isDirectory: node?.isDirectory ?? true
        )
        cleanupRequest = CleanupRequest(target: target, recommendation: recommendation, note: nil)
    }

    /// Explorer entry point: only nodes covered by a trash-permitting rule.
    func requestCleanup(node: FileTreeNode) {
        if let rec = recommendations.first(where: { $0.path == node.path }) {
            requestCleanup(rec)
            return
        }
        guard let annotation = node.effectiveAnnotation, annotation.safety.permitsTrash else { return }
        let target = CleanupTarget(
            path: node.path,
            displayName: node.name,
            safety: annotation.safety,
            identity: node.identity,
            metrics: node.metrics,
            conflictingApplicationBundleIDs: conflictingApps(for: annotation.ruleID),
            isDirectory: node.isDirectory
        )
        cleanupRequest = CleanupRequest(target: target, recommendation: nil, note: "Inside \(annotation.title)")
    }

    func canTrash(_ node: FileTreeNode) -> Bool {
        guard node.parent != nil else { return false }
        return node.effectiveAnnotation?.safety.permitsTrash ?? false
    }

    func requestDuplicateCleanup(path: String, in group: DuplicateGroup) {
        guard let node = root?.descendant(atPath: path), let keep = group.paths.first, keep != path else { return }
        let target = CleanupTarget(
            path: path,
            displayName: node.name,
            safety: .reviewFirst,
            identity: node.identity,
            metrics: node.metrics,
            isDirectory: false
        )
        cleanupRequest = CleanupRequest(target: target, recommendation: nil, note: "Keeping \(abbreviatePath(keep))")
    }

    private func conflictingApps(for ruleID: String) -> [String] {
        ruleID.hasPrefix("xcode.") ? ["com.apple.dt.Xcode"] : []
    }

    func runPreflight(_ request: CleanupRequest) async -> PreflightReport {
        await cleanup.preflight(request.target)
    }

    func performCleanup(_ request: CleanupRequest, report: PreflightReport) async -> CleanupOutcome {
        let outcome = await cleanup.moveToTrash(request.target, report: report)
        guard outcome.succeeded else { return outcome }
        applyRemoval(path: request.target.path)
        reclaimedThisSession += outcome.reclaimedPrivateBytes
        trashedThisSession += outcome.movedAllocatedBytes
        toast = Toast(
            title: "Moved \(request.target.displayName) to the Trash",
            detail: "\(formatBytes(outcome.reclaimedPrivateBytes)) frees immediately when the Trash is emptied (\(formatBytes(outcome.movedAllocatedBytes)) allocated).",
            symbol: "trash.fill",
            tint: Theme.positive
        )
        refreshVolume()
        return outcome
    }

    private func applyRemoval(path: String) {
        let prefix = path + "/"
        recommendations.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
        duplicateCandidates.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
        duplicateGroups = duplicateGroups.compactMap { group in
            var g = group
            g.paths.removeAll { $0 == path || $0.hasPrefix(prefix) }
            return g.paths.count >= 2 ? g : nil
        }
        guard let node = root?.descendant(atPath: path), node.parent != nil else { return }
        if let focus, focus === node || focus.ancestors.contains(where: { $0 === node }) {
            self.focus = node.parent
        }
        if let selection, selection === node || selection.ancestors.contains(where: { $0 === node }) {
            self.selection = nil
        }
        node.removeFromParent()
        treeVersion += 1
    }

    // MARK: - Duplicates

    func findDuplicates() {
        guard !isFindingDuplicates else { return }
        isFindingDuplicates = true
        duplicatesSearched = true
        duplicateGroups = []
        duplicateProgress = nil
        let candidates = duplicateCandidates
        let detector = duplicates
        duplicateTask = Task { [weak self] in
            do {
                let groups = try await detector.findDuplicates(among: candidates, options: DuplicateScanOptions()) { [weak self] progress in
                    Task { @MainActor in self?.duplicateProgress = progress }
                }
                self?.duplicateGroups = groups
            } catch {
                self?.duplicateGroups = []
            }
            self?.isFindingDuplicates = false
        }
    }

    func cancelDuplicates() {
        duplicateTask?.cancel()
        isFindingDuplicates = false
    }

    var duplicateReclaimable: UInt64 { duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes } }

    // MARK: - History

    private func saveAndReloadHistory(_ snapshot: ScanSnapshot) async {
        guard let history else {
            historyError = "History database unavailable."
            return
        }
        do {
            try await history.save(snapshot)
            try await history.prune(keepingLatest: 60)
        } catch {
            historyError = error.localizedDescription
        }
        await reloadHistory()
    }

    func reloadHistory() async {
        guard let history else { return }
        do {
            snapshots = try await history.summaries(rootPath: root?.path ?? scanRootPath)
            if diffBaseID == nil || !snapshots.contains(where: { $0.id == diffBaseID }) {
                diffBaseID = snapshots.dropFirst().first?.id
            }
            await computeDiff()
        } catch {
            historyError = error.localizedDescription
        }
    }

    func computeDiff() async {
        guard let history, let current = snapshots.first, let base = diffBaseID, base != current.id else {
            diff = nil
            return
        }
        do {
            diff = try await history.diff(baseID: base, currentID: current.id, significanceBytes: 50_000_000)
        } catch {
            historyError = error.localizedDescription
            diff = nil
        }
    }

    func deleteSnapshot(_ id: UUID) async {
        guard let history else { return }
        try? await history.delete(id: id)
        if diffBaseID == id { diffBaseID = nil }
        await reloadHistory()
    }

    // MARK: - FSEvents watcher

    private func startWatching(path: String) {
        stopWatching()
        guard let stream = try? watcher.start(paths: [path], latency: 2.5) else { return }
        watchTask = Task { [weak self] in
            for await batch in stream {
                self?.absorb(batch)
            }
        }
    }

    private func stopWatching() {
        rescanDebounce?.cancel()
        rescanDebounce = nil
        watchTask?.cancel()
        watchTask = nil
        watcher.stop()
    }

    private func absorb(_ batch: DirtyPathBatch) {
        guard let root else { return }
        let rootPath = root.path
        let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
        var merged = dirtyPaths
        for dirty in batch.paths where dirty.path == rootPath || dirty.path.hasPrefix(rootPrefix) {
            if dirty.path == rootPath {
                // The root can't be spliced. Top-level churn (shell history, dotfiles)
                // is left to the next full scan; a recursive root event (dropped
                // events, MustScanSubDirs) means the whole tree may be stale.
                if dirty.recursive { needsFullRescan = true }
                continue
            }
            if let existing = merged.firstIndex(where: { $0.path == dirty.path }) {
                merged[existing].recursive = merged[existing].recursive || dirty.recursive
            } else {
                merged.append(dirty)
            }
        }
        // Minimal cover: drop paths inside another dirty path (subtree rescans are recursive).
        merged.sort { $0.path.count < $1.path.count }
        var cover: [DirtyPath] = []
        for candidate in merged where !cover.contains(where: { candidate.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }) {
            cover.append(candidate)
        }
        dirtyPaths = cover
        guard autoRescan, !cover.isEmpty, rescanDebounce == nil else { return }
        // Throttle (not debounce): under constant churn (Spotlight, caches) a
        // debounce would be reset by every batch and never fire.
        rescanDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await self?.rescanDirty(automatic: true)
            self?.rescanDebounce = nil
        }
    }

    /// Rescans changed subtrees and splices them into the live tree. Large
    /// subtrees (or the root) are left for an explicit full rescan.
    func rescanDirty(automatic: Bool = false) async {
        guard let root, !isRescanning, !isBusy, !dirtyPaths.isEmpty else { return }
        isRescanning = true
        defer { isRescanning = false }
        let pending = dirtyPaths
        var remaining: [DirtyPath] = []
        var spliced = 0
        let context = makeClassificationContext()

        for dirty in pending.prefix(24) {
            // Deepest existing directory node for this path.
            var path = dirty.path
            var node = root.descendant(atPath: path)
            while node == nil || node?.isDirectory == false {
                let parent = (path as NSString).deletingLastPathComponent
                if parent == path || parent.count < root.path.count { break }
                path = parent
                node = root.descendant(atPath: path)
            }
            guard let target = node, let parent = target.parent else {
                remaining.append(dirty)   // root itself changed → needs a full rescan
                continue
            }
            if automatic && target.metrics.itemCount > 150_000 {
                remaining.append(dirty)
                continue
            }
            let insideCleanupTarget = target.ancestors.contains { $0.annotation?.safety.permitsTrash == true }
            let inheritedCategory = target.category
            let parentPath = parent.path
            let scanner = self.scanner
            let classifier = self.classifier
            do {
                let fresh = try await scanner.rescanSubtree(atPath: target.path, options: ScanOptions(rootPath: target.path))
                let classification = await Task.detached(priority: .utility) { () -> ClassificationResult in
                    // Temporary parent so rules see absolute paths before the splice.
                    let shadow = FileTreeNode(name: parentPath, kind: .directory)
                    shadow.setChildren([fresh])
                    let result = classifier.classify(root: fresh, context: context)
                    if insideCleanupTarget {
                        fresh.walk { $0.category = inheritedCategory; return .continue }
                    }
                    return result
                }.value
                // Splice on the MainActor.
                let oldPath = target.path
                if let focus, focus === target || focus.ancestors.contains(where: { $0 === target }) { self.focus = fresh }
                if let selection, selection === target || selection.ancestors.contains(where: { $0 === target }) { self.selection = nil }
                target.replace(with: fresh)
                let prefix = oldPath + "/"
                recommendations.removeAll { $0.path == oldPath || $0.path.hasPrefix(prefix) }
                if !insideCleanupTarget {
                    recommendations.append(contentsOf: classification.recommendations)
                    recommendations.sort { $0.reclaimableBytes > $1.reclaimableBytes }
                }
                spliced += 1
            } catch {
                remaining.append(dirty)
            }
        }
        remaining.append(contentsOf: pending.dropFirst(24))
        // Keep paths that arrived while we were rescanning.
        let handled = Set(pending.map(\.path))
        dirtyPaths = remaining + dirtyPaths.filter { !handled.contains($0.path) }
        if spliced > 0 {
            treeVersion += 1
            lastRescanSummary = "Updated \(spliced) changed folder\(spliced == 1 ? "" : "s") · \(Date().formatted(date: .omitted, time: .shortened))"
            refreshVolume()
        }
    }
}
