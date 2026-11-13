// AppState.swift — composition root & single source of truth.
//
// Threading follows the FileTreeNode contract: scan, classification, insights,
// snapshot capture, duplicate-candidate collection and cache saving all run
// off-main BEFORE publication. After publication the tree is mutated only here,
// on the MainActor (cleanup removals and FSEvents-driven subtree splices), and
// every mutation bumps `treeVersion`.

import AppKit
import Foundation
import Observation
import SwiftUI
import KlaDIntelligence
import KlaDModels
import KlaDScanner
import KlaDStorageOps

// MARK: - Navigation model

struct ScanLocation: Identifiable, Hashable, Codable {
    var id: String { path }
    let path: String
    let title: String
    let symbol: String

    static let disk = ScanLocation(path: "/", title: "Macintosh HD", symbol: "internaldrive")
    static var home: ScanLocation {
        ScanLocation(path: NSHomeDirectory(), title: FileManager.default.displayName(atPath: NSHomeDirectory()), symbol: "house")
    }
}

enum InsightSection: String, CaseIterable, Identifiable, Hashable {
    case overview, recommendations, largestFiles, fileTypes, similarFolders, duplicates, whereIsMySpace, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .recommendations: return "Recommendations"
        case .largestFiles: return "Largest Files"
        case .fileTypes: return "File Types"
        case .similarFolders: return "Similar Folders"
        case .duplicates: return "Duplicates"
        case .whereIsMySpace: return "Where Is My Space"
        case .history: return "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "chart.pie"
        case .recommendations: return "sparkles"
        case .largestFiles: return "arrow.up.doc"
        case .fileTypes: return "square.grid.2x2"
        case .similarFolders: return "folder.badge.questionmark"
        case .duplicates: return "doc.on.doc"
        case .whereIsMySpace: return "lock.shield"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

enum SidebarItem: Hashable {
    case location(String)
    case section(InsightSection)
}

struct CleanupRequest: Identifiable {
    let id = UUID()
    let target: CleanupTarget
    let recommendation: CleanupRecommendation?
    /// Context ("Keeping …/original.mov", "Inside node_modules").
    let note: String?

    var requiresReviewAcknowledgement: Bool { target.safety.requiresExplicitReview }
}

struct BatchCleanupRequest: Identifiable {
    let id = UUID()
    let items: [CleanupRecommendation]
}

struct BatchItemResult: Identifiable {
    var id: String { recommendation.id }
    let recommendation: CleanupRecommendation
    let succeeded: Bool
    let detail: String
}

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
        case loading
        case scanning
        case analyzing
        case ready
        case failed(String)
    }

    // MARK: Navigation
    var sidebarSelection: SidebarItem? = .section(.overview)
    var section: InsightSection {
        if case .section(let section) = sidebarSelection { return section }
        return .overview
    }
    var showInspector = true
    var visualizerMode: VisualizerMode = .sunburst
    var measure: SizeMeasure = .allocated
    var colorMode: ColorMode = .category

    // MARK: Locations
    private(set) var customLocations: [ScanLocation] = []
    var locations: [ScanLocation] { [.disk, .home] + customLocations }
    private(set) var currentLocation: ScanLocation?

    // MARK: Scan
    var phase: Phase = .idle
    var progress = ScanProgress()
    private(set) var result: ScanResult?
    private(set) var root: FileTreeNode?
    var focus: FileTreeNode?
    var selection: FileTreeNode?
    private(set) var treeVersion = 0
    /// When the published tree was scanned (older than now when restored from cache).
    private(set) var scannedAt: Date?
    private(set) var restoredFromCache = false
    private var scanTask: Task<Void, Never>?

    // MARK: Volume
    private(set) var volume: VolumeSpaceReport?

    // MARK: Insights
    private(set) var recommendations: [CleanupRecommendation] = []
    private(set) var categoryTotals: [StorageCategory: StorageMetrics] = [:]
    private(set) var largestFiles: [LargeFileEntry] = []
    private(set) var fileTypes: [FileTypeSummary] = []
    private(set) var similarFolders: [SimilarFolderGroup] = []
    private(set) var protectedNodes: [FileTreeNode] = []
    private(set) var opaqueNodes: [FileTreeNode] = []

    // MARK: Search
    var searchText = "" {
        didSet { scheduleSearch() }
    }
    private(set) var searchResults: [FileTreeNode] = []
    private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?

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
    private(set) var usageSeries: [UsageSample] = []
    private(set) var forecast: ForecastOutcome?
    private(set) var folderSeries: [SizeSample] = []
    private var folderSeriesPath: String?

    // MARK: Live updates
    private(set) var dirtyPaths: [DirtyPath] = []
    private(set) var needsFullRescan = false
    private(set) var isRescanning = false
    private(set) var lastRescanSummary: String?
    private var watchTask: Task<Void, Never>?
    private var rescanThrottle: Task<Void, Never>?

    // MARK: Cleanup
    var cleanupRequest: CleanupRequest?
    var batchRequest: BatchCleanupRequest?
    private(set) var reclaimedThisSession: UInt64 = 0

    // MARK: Settings (persisted)
    var liveUpdates: Bool { didSet { defaults.set(liveUpdates, forKey: "liveUpdates"); liveUpdatesChanged() } }
    var gentleRescans: Bool { didSet { defaults.set(gentleRescans, forKey: "gentleRescans") } }
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    var excludedPaths: [String] { didSet { defaults.set(excludedPaths, forKey: "excludedPaths") } }
    var reopenLastScan: Bool { didSet { defaults.set(reopenLastScan, forKey: "reopenLastScan") } }

    // MARK: Services
    let scanner: any StorageScanning
    let volumeInspector: any VolumeInspecting
    let classifier: any StorageClassifying
    let git: any GitRepositoryInspecting
    let history: (any SnapshotHistoryStoring)?
    let duplicates: any DuplicateDetecting
    let cleanup: any SafeCleanupPerforming
    let watcher: any FileSystemWatching
    let cache: (any ScanCaching)?
    let forecaster: (any StorageForecasting)?
    let inventory: (any InventoryReporting)?
    let similarDetector: (any SimilarFolderDetecting)?
    let leftovers: (any LeftoverDetecting)?

    @ObservationIgnored private let defaults = UserDefaults.standard

    init(
        scanner: any StorageScanning = BulkAPFSScanner(),
        volumeInspector: any VolumeInspecting = APFSVolumeInspector(),
        classifier: any StorageClassifying = ClassificationEngine(),
        git: any GitRepositoryInspecting = GitRepoInspector(),
        history: (any SnapshotHistoryStoring)? = try? SnapshotHistoryService(databaseURL: SnapshotHistoryService.defaultDatabaseURL()),
        duplicates: any DuplicateDetecting = DuplicateDetectorService(),
        cleanup: any SafeCleanupPerforming = SafeCleanupService(),
        watcher: any FileSystemWatching = FSEventsMonitor(),
        cache: (any ScanCaching)? = nil,
        forecaster: (any StorageForecasting)? = nil,
        inventory: (any InventoryReporting)? = InventoryReporter(),
        similarDetector: (any SimilarFolderDetecting)? = SimilarFolderDetector(),
        leftovers: (any LeftoverDetecting)? = LeftoverDetector()
    ) {
        self.scanner = scanner
        self.volumeInspector = volumeInspector
        self.classifier = classifier
        self.git = git
        self.history = history
        self.duplicates = duplicates
        self.cleanup = cleanup
        self.watcher = watcher
        self.cache = cache
        self.forecaster = forecaster
        self.inventory = inventory
        self.similarDetector = similarDetector
        self.leftovers = leftovers

        let defaults = UserDefaults.standard
        defaults.register(defaults: ["liveUpdates": true, "gentleRescans": true, "historyLimit": 60, "reopenLastScan": true])
        liveUpdates = defaults.bool(forKey: "liveUpdates")
        gentleRescans = defaults.bool(forKey: "gentleRescans")
        historyLimit = max(5, defaults.integer(forKey: "historyLimit"))
        excludedPaths = defaults.stringArray(forKey: "excludedPaths") ?? []
        reopenLastScan = defaults.bool(forKey: "reopenLastScan")
        if let data = defaults.data(forKey: "customLocations"),
           let saved = try? JSONDecoder().decode([ScanLocation].self, from: data) {
            customLocations = saved
        }
    }

    // MARK: - Derived

    var isBusy: Bool { phase == .scanning || phase == .analyzing || phase == .loading }
    var hasResults: Bool { root != nil }

    func recommendations(for safety: SafetyLevel) -> [CleanupRecommendation] {
        recommendations.filter { $0.safety == safety }
    }

    func reclaimable(for safety: SafetyLevel) -> UInt64 {
        recommendations(for: safety).reduce(0) { $0 + $1.reclaimableBytes }
    }

    var focusChain: [FileTreeNode] {
        guard let focus else { return [] }
        return focus.ancestors + [focus]
    }

    /// Root metrics without opaque accounting nodes (what was actually enumerated).
    var scannedMetrics: StorageMetrics {
        guard let root else { return .zero }
        var metrics = root.metrics
        for node in opaqueNodes { metrics.subtract(node.aggregateContribution) }
        return metrics
    }

    // MARK: - Locations

    func addLocation(path: String) -> ScanLocation {
        let resolved = (path as NSString).standardizingPath
        if let existing = locations.first(where: { $0.path == resolved }) { return existing }
        let location = ScanLocation(path: resolved, title: FileManager.default.displayName(atPath: resolved), symbol: "folder")
        customLocations.append(location)
        persistLocations()
        return location
    }

    func removeLocation(_ location: ScanLocation) {
        customLocations.removeAll { $0 == location }
        persistLocations()
        Task { try? await cache?.remove(rootPath: location.path) }
    }

    private func persistLocations() {
        if let data = try? JSONEncoder().encode(customLocations) { defaults.set(data, forKey: "customLocations") }
    }

    /// Shows a location: instantly from the cached scan when available (then
    /// catches up via FSEvents history), otherwise scans it.
    func open(_ location: ScanLocation, forceRescan: Bool = false) {
        currentLocation = location
        if !forceRescan, let cache {
            cancelScan()
            stopWatching()
            phase = .loading
            let resolvedPath = location.path == "/" ? "/" : (location.path as NSString).resolvingSymlinksInPath
            scanTask = Task { [weak self] in
                if let cached = try? await cache.load(rootPath: resolvedPath) {
                    if Task.isCancelled { return }
                    await self?.publishCached(cached.root, meta: cached.meta)
                } else {
                    if Task.isCancelled { return }
                    self?.startScan(path: location.path)
                }
            }
        } else {
            startScan(path: location.path)
        }
    }

    /// Restores the most recent cached scan at launch.
    func restoreLastSession() async {
        refreshVolume()
        guard reopenLastScan, root == nil, phase == .idle, let cache else { return }
        guard let latest = await cache.cachedScans().first else { return }
        let location = locations.first { $0.path == latest.rootPath }
            ?? ScanLocation(path: latest.rootPath, title: FileManager.default.displayName(atPath: latest.rootPath), symbol: "folder")
        open(location)
    }

    // MARK: - Scanning

    func rescan() {
        guard let location = currentLocation else { return }
        open(location, forceRescan: true)
    }

    func startScan(path: String) {
        cancelScan()
        stopWatching()
        duplicateTask?.cancel()
        resetResults()
        phase = .scanning
        progress = ScanProgress()
        if currentLocation?.path != path {
            currentLocation = locations.first { $0.path == path }
                ?? ScanLocation(path: path, title: FileManager.default.displayName(atPath: path), symbol: "folder")
        }

        let scanner = self.scanner
        let inspector = self.volumeInspector
        let eventID = watcher.currentEventID
        let options = ScanOptions(rootPath: path, excludedPaths: Set(excludedPaths))

        scanTask = Task { [weak self] in
            async let volumeReport = inspector.report(forPath: path)
            do {
                let scanResult = try await scanner.scan(options) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.phase == .scanning else { return }
                        self.progress = progress
                    }
                }
                if Task.isCancelled { return }
                guard let self else { return }
                self.phase = .analyzing
                let processed = await self.postProcess(scanResult.root, startedAt: scanResult.startedAt, completedAt: scanResult.completedAt)
                if let cache = self.cache {
                    let meta = ScanCacheMeta(rootPath: scanResult.root.path, scannedAt: scanResult.completedAt, fsEventsID: eventID,
                                             privateSizeSupported: scanResult.privateSizeSupported,
                                             unreadableCount: scanResult.unreadableCount,
                                             nodeCount: Int(scanResult.root.metrics.itemCount) + 1)
                    try? await cache.save(scanResult.root, meta: meta)   // reads the tree: must finish before publication
                }
                let report = await volumeReport
                if Task.isCancelled { return }
                self.publish(scanResult, processed, volume: report, restored: false)
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

    private func resetResults() {
        result = nil
        root = nil
        focus = nil
        selection = nil
        recommendations = []
        categoryTotals = [:]
        largestFiles = []
        fileTypes = []
        similarFolders = []
        protectedNodes = []
        opaqueNodes = []
        searchResults = []
        duplicateGroups = []
        duplicateCandidates = []
        duplicatesSearched = false
        dirtyPaths = []
        needsFullRescan = false
        diff = nil
        diffBaseID = nil
        lastRescanSummary = nil
        folderSeries = []
        folderSeriesPath = nil
    }

    private struct PostProcessed: Sendable {
        let classification: ClassificationResult
        let leftovers: [CleanupRecommendation]
        let largest: [LargeFileEntry]
        let types: [FileTypeSummary]
        let similar: [SimilarFolderGroup]
        let snapshot: ScanSnapshot
        let candidates: [DuplicateCandidate]
        let protectedPaths: [String]
    }

    /// Everything that reads or annotates the tree, off-main, before publication.
    private func postProcess(_ root: FileTreeNode, startedAt: Date, completedAt: Date) async -> PostProcessed {
        let classifier = self.classifier
        let inventory = self.inventory
        let similarDetector = self.similarDetector
        let leftovers = self.leftovers
        let context = makeClassificationContext()
        let installed = SystemActions.installedApps()
        return await Task.detached(priority: .userInitiated) {
            AppState.reannotateOpaque(root)
            let classification = classifier.classify(root: root, context: context)
            var protectedPaths: [String] = []
            root.walkWithPaths { node, path in
                if node.isOpaque { return .skipChildren }
                if node.isProtectedLocation { protectedPaths.append(path); return .skipChildren }
                return .continue
            }
            return PostProcessed(
                classification: classification,
                leftovers: leftovers?.findLeftovers(in: root, context: context, installed: installed) ?? [],
                largest: inventory?.largestFiles(in: root, limit: 500, measure: .allocated) ?? [],
                types: inventory?.fileTypes(in: root, limit: 300) ?? [],
                similar: similarDetector?.findSimilarFolders(in: root, minimumBytes: 50_000_000) ?? [],
                snapshot: ScanSnapshot.capture(from: root, startedAt: startedAt, completedAt: completedAt, volume: nil),
                candidates: DuplicateCandidate.collect(from: root, minimumBytes: 1 << 20),
                protectedPaths: protectedPaths
            )
        }.value
    }

    /// Opaque accounting nodes restored from cache lose their annotation.
    nonisolated private static func reannotateOpaque(_ root: FileTreeNode) {
        for node in root.children where node.isOpaque && node.annotation == nil {
            node.annotation = NodeAnnotation(ruleID: "apfs.accounting", title: node.name, safety: .doNotDelete, group: .system,
                                             reason: "Sized from APFS volume totals. Managed by macOS.")
        }
    }

    private func publishCached(_ cachedRoot: FileTreeNode, meta: ScanCacheMeta) async {
        let processed = await postProcess(cachedRoot, startedAt: meta.scannedAt, completedAt: meta.scannedAt)
        let report = await volumeInspector.report(forPath: meta.rootPath)
        let scanResult = ScanResult(root: cachedRoot, options: ScanOptions(rootPath: meta.rootPath), startedAt: meta.scannedAt,
                                    completedAt: meta.scannedAt, issues: [], unreadableCount: meta.unreadableCount,
                                    privateSizeSupported: meta.privateSizeSupported, hardLinkDuplicateCount: 0, wasCancelled: false)
        publish(scanResult, processed, volume: report, restored: true, sinceEventID: meta.fsEventsID)
    }

    private func publish(_ scanResult: ScanResult, _ processed: PostProcessed, volume report: VolumeSpaceReport?,
                         restored: Bool, sinceEventID: UInt64? = nil) {
        result = scanResult
        root = scanResult.root
        focus = scanResult.root
        selection = nil
        volume = report
        scannedAt = scanResult.completedAt
        restoredFromCache = restored
        categoryTotals = processed.classification.categoryTotals
        recommendations = (processed.classification.recommendations + processed.leftovers + syntheticRecommendations(volume: report))
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        largestFiles = processed.largest
        fileTypes = processed.types
        similarFolders = processed.similar
        duplicateCandidates = processed.candidates
        protectedNodes = processed.protectedPaths.compactMap { scanResult.root.descendant(atPath: $0) }
        opaqueNodes = scanResult.root.children.filter(\.isOpaque)
        treeVersion += 1
        phase = .ready

        if !restored {
            var snapshot = processed.snapshot
            snapshot.volume = report
            Task { await self.saveAndReloadHistory(snapshot) }
        } else {
            Task { await self.reloadHistory() }
        }
        Task { await self.enrichWithGitSignals() }
        if liveUpdates { startWatching(path: scanResult.root.path, sinceEventID: sinceEventID) }
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
        var cards: [CleanupRecommendation] = []
        if let report, !report.localSnapshotNames.isEmpty {
            let names = report.localSnapshotNames
            let updates = names.filter { $0.hasPrefix("com.apple.os.update") }.count
            var commands = [GuidedCommand(label: "List local snapshots", command: "tmutil listlocalsnapshots /", isDestructive: false)]
            if names.count > updates {
                commands.append(GuidedCommand(label: "Ask macOS to thin Time Machine snapshots",
                                              command: "tmutil thinlocalsnapshots / 100000000000 4", isDestructive: true))
            }
            let explanation = "\(names.count) local snapshot\(names.count == 1 ? "" : "s") keep blocks of files you have since changed or deleted. "
                + (updates > 0 ? "\(updates) belong\(updates == 1 ? "s" : "") to Software Update and \(updates == 1 ? "is" : "are") released automatically. " : "")
                + "Time Machine snapshots expire on their own, or when macOS needs the space."
            cards.append(CleanupRecommendation(
                ruleID: "apfs.local_snapshots", title: "Local Snapshots", path: report.volumePath, category: .system,
                safety: .guidedExternalAction, group: .snapshots, metrics: .zero,
                rationale: "Managed by macOS. KlaD never deletes snapshot data; use tmutil if you need the space now.",
                evidence: [Evidence(kind: .runtimeState, detail: "\(names.count) snapshot\(names.count == 1 ? "" : "s") reported by tmutil")],
                action: .guided(GuidedRemediation(headline: "Thin snapshots with tmutil", explanation: explanation, commands: commands)),
                identity: NodeIdentity(fileID: 0, deviceID: 0, modificationTime: 0)
            ))
        }
        for (bundleID, title) in [("com.docker.docker", "Docker Desktop"), ("dev.kdrag0n.MacVirt", "OrbStack"), ("com.utmapp.UTM", "UTM")]
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            let isDocker = bundleID != "com.utmapp.UTM"
            cards.append(CleanupRecommendation(
                ruleID: "app.\(bundleID)", title: title, path: "/Applications", category: .containersVMs,
                safety: .guidedExternalAction, group: .containersAndVMs, metrics: .zero,
                rationale: "\(title) keeps its disk image in its private, macOS-protected container, which KlaD never opens. Reclaim space through \(title) itself.",
                evidence: [Evidence(kind: .runtimeState, detail: "\(title) is installed")],
                action: .guided(GuidedRemediation(
                    headline: "Reclaim space with \(title)",
                    explanation: isDocker
                        ? "Images, build cache and stopped containers live inside the VM disk. Prune them with the CLI; volumes hold databases, so prune those only on purpose."
                        : "Delete virtual machines you no longer need from inside UTM.",
                    commands: isDocker ? [
                        GuidedCommand(label: "See what uses space", command: "docker system df", isDestructive: false),
                        GuidedCommand(label: "Remove build cache", command: "docker builder prune", isDestructive: true),
                        GuidedCommand(label: "Remove unused images", command: "docker image prune -a", isDestructive: true),
                    ] : [],
                    applicationBundleID: bundleID)),
                identity: NodeIdentity(fileID: 0, deviceID: 0, modificationTime: 0)
            ))
        }
        return cards
    }

    // MARK: - Navigation

    func drill(into node: FileTreeNode) {
        guard node.isDirectory, !node.isProtectedLocation, node.hasChildren else {
            select(node)
            return
        }
        focus = node
        select(node)
    }

    func drillUp() {
        guard let parent = focus?.parent else { return }
        focus = parent
    }

    func select(_ node: FileTreeNode?) {
        selection = node
        loadFolderSeries()
    }

    /// Selects a node by path, focusing its parent, and shows the overview.
    func reveal(path: String) {
        guard let root, let node = root.descendant(atPath: path) else { return }
        focus = node.isDirectory && !node.isProtectedLocation && node.hasChildren ? node : (node.parent ?? root)
        select(node)
        sidebarSelection = .section(.overview)
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, root != nil else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            let results = await self.search(query)
            guard !Task.isCancelled else { return }
            self.searchResults = results
            self.isSearching = false
        }
    }

    /// Case-insensitive name search on the MainActor, yielding every 40k nodes.
    private func search(_ query: String) async -> [FileTreeNode] {
        guard let root else { return [] }
        var matches: [FileTreeNode] = []
        var stack: [FileTreeNode] = [root]
        var visited = 0
        while let node = stack.popLast() {
            if node !== root, !node.isOpaque,
               node.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                matches.append(node)
                if matches.count >= 5_000 { break }
            }
            stack.append(contentsOf: node.children)
            visited += 1
            if visited % 40_000 == 0 {
                await Task.yield()
                if Task.isCancelled { return [] }
            }
        }
        return Array(matches.sorted { $0.metrics.allocatedBytes > $1.metrics.allocatedBytes }.prefix(400))
    }

    // MARK: - Volume

    func refreshVolume() {
        let path = root?.path ?? currentLocation?.path ?? NSHomeDirectory()
        let inspector = volumeInspector
        Task { [weak self] in
            let report = await inspector.report(forPath: path)
            self?.volume = report
        }
    }

    // MARK: - Git enrichment

    private func enrichWithGitSignals() async {
        // git may read (and thus download) dataless files: skip iCloud-synced places.
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

    /// Trash is only ever possible for policy-allowed paths covered by a
    /// trash-permitting safety tier.
    func canTrash(_ node: FileTreeNode) -> Bool {
        guard node.parent != nil, !node.isOpaque, !node.isProtectedLocation else { return false }
        guard SystemPolicy.mayModify(node.path, home: NSHomeDirectory()) else { return false }
        return node.effectiveAnnotation?.safety.permitsTrash ?? false
    }

    func mayModify(path: String) -> Bool {
        SystemPolicy.mayModify(path, home: NSHomeDirectory())
    }

    func requestCleanup(_ recommendation: CleanupRecommendation) {
        guard recommendation.isTrashable, mayModify(path: recommendation.path) else { return }
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

    func requestCleanup(node: FileTreeNode) {
        if let rec = recommendations.first(where: { $0.path == node.path }) {
            requestCleanup(rec)
            return
        }
        guard canTrash(node), let annotation = node.effectiveAnnotation else { return }
        let target = CleanupTarget(
            path: node.path, displayName: node.name, safety: annotation.safety, identity: node.identity,
            metrics: node.metrics, conflictingApplicationBundleIDs: conflictingApps(for: annotation.ruleID),
            isDirectory: node.isDirectory
        )
        cleanupRequest = CleanupRequest(target: target, recommendation: nil, note: "Inside \(annotation.title)")
    }

    /// Duplicates and similar folders: never rule-proven, so always Review First.
    func requestReviewCleanup(path: String, note: String) {
        guard mayModify(path: path), let node = root?.descendant(atPath: path), !node.isOpaque, !node.isProtectedLocation else { return }
        let target = CleanupTarget(path: path, displayName: node.name, safety: .reviewFirst, identity: node.identity,
                                   metrics: node.metrics, isDirectory: node.isDirectory)
        cleanupRequest = CleanupRequest(target: target, recommendation: nil, note: note)
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
        refreshVolume()
        return outcome
    }

    var batchCandidates: [CleanupRecommendation] {
        recommendations(for: .safeToClear).filter { $0.isTrashable && mayModify(path: $0.path) }
    }

    func requestBatchCleanup() {
        guard !batchCandidates.isEmpty else { return }
        batchRequest = BatchCleanupRequest(items: batchCandidates)
    }

    /// Sequential pre-flight + trash. Items that fail a check or need an
    /// individual acknowledgement are skipped, never forced.
    func performBatch(_ items: [CleanupRecommendation], progress: @escaping (Int) -> Void) async -> [BatchItemResult] {
        var results: [BatchItemResult] = []
        for (index, rec) in items.enumerated() {
            progress(index)
            guard let node = root?.descendant(atPath: rec.path) else {
                results.append(BatchItemResult(recommendation: rec, succeeded: false, detail: "No longer in the scan"))
                continue
            }
            let target = CleanupTarget(path: rec.path, displayName: rec.title, safety: rec.safety, identity: rec.identity,
                                       metrics: node.metrics, conflictingApplicationBundleIDs: conflictingApps(for: rec.ruleID),
                                       isDirectory: node.isDirectory)
            let report = await cleanup.preflight(target)
            if let failed = report.checks.first(where: { $0.status == .failed }) {
                results.append(BatchItemResult(recommendation: rec, succeeded: false, detail: failed.title + ": " + failed.detail))
                continue
            }
            if let ack = report.acknowledgementsRequired.first {
                results.append(BatchItemResult(recommendation: rec, succeeded: false, detail: "Needs individual review — " + ack.title))
                continue
            }
            if let busy = report.checks.first(where: { $0.id == "openFiles" && $0.status == .warning }) {
                results.append(BatchItemResult(recommendation: rec, succeeded: false, detail: busy.detail))
                continue
            }
            let outcome = await cleanup.moveToTrash(target, report: report)
            if outcome.succeeded {
                applyRemoval(path: rec.path)
                reclaimedThisSession += outcome.reclaimedPrivateBytes
                results.append(BatchItemResult(recommendation: rec, succeeded: true, detail: formatBytes(outcome.reclaimedPrivateBytes)))
            } else {
                results.append(BatchItemResult(recommendation: rec, succeeded: false, detail: outcome.errorMessage ?? "Could not move"))
            }
        }
        progress(items.count)
        refreshVolume()
        return results
    }

    private func applyRemoval(path: String) {
        let prefix = path + "/"
        recommendations.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
        duplicateCandidates.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
        largestFiles.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
        searchResults.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
        duplicateGroups = duplicateGroups.compactMap { group in
            var g = group
            g.paths.removeAll { $0 == path || $0.hasPrefix(prefix) }
            return g.paths.count >= 2 ? g : nil
        }
        similarFolders = similarFolders.compactMap { group in
            var g = group
            g.folders.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
            return g.folders.count >= 2 ? g : nil
        }
        guard let node = root?.descendant(atPath: path), node.parent != nil else { return }
        if let focus, focus === node || focus.ancestors.contains(where: { $0 === node }) { self.focus = node.parent }
        if let selection, selection === node || selection.ancestors.contains(where: { $0 === node }) { self.selection = nil }
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
            try await history.prune(keepingLatest: historyLimit)
        } catch {
            historyError = error.localizedDescription
        }
        await reloadHistory()
    }

    func reloadHistory() async {
        guard let history else { return }
        do {
            snapshots = try await history.summaries(rootPath: root?.path)
            if diffBaseID == nil || !snapshots.contains(where: { $0.id == diffBaseID }) {
                diffBaseID = snapshots.dropFirst().first?.id
            }
            await computeDiff()
            if let series = history as? any SnapshotSeriesProviding {
                usageSeries = (try? await series.usageSeries()) ?? []
                forecast = forecaster?.forecast(samples: usageSeries, now: Date())
            }
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

    private func loadFolderSeries() {
        guard let node = selection, node.isDirectory, !node.isOpaque,
              let series = history as? any SnapshotSeriesProviding else {
            folderSeries = []
            folderSeriesPath = nil
            return
        }
        let path = node.path
        guard path != folderSeriesPath else { return }
        folderSeriesPath = path
        Task { [weak self] in
            let samples = (try? await series.sizeSeries(path: path)) ?? []
            guard self?.folderSeriesPath == path else { return }
            self?.folderSeries = samples
        }
    }

    // MARK: - Live updates (FSEvents)

    private func liveUpdatesChanged() {
        if liveUpdates, let root { startWatching(path: root.path, sinceEventID: nil) } else { stopWatching() }
    }

    private func startWatching(path: String, sinceEventID: UInt64?) {
        stopWatching()
        let watchPath = path == "/" ? NSHomeDirectory() : path
        guard let stream = try? watcher.start(paths: [watchPath], latency: 2.5, sinceEventID: sinceEventID) else { return }
        watchTask = Task { [weak self] in
            for await batch in stream {
                self?.absorb(batch)
            }
        }
    }

    private func stopWatching() {
        rescanThrottle?.cancel()
        rescanThrottle = nil
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
                if dirty.recursive { needsFullRescan = true }
                continue
            }
            if let existing = merged.firstIndex(where: { $0.path == dirty.path }) {
                merged[existing].recursive = merged[existing].recursive || dirty.recursive
            } else {
                merged.append(dirty)
            }
        }
        merged.sort { $0.path.count < $1.path.count }
        var cover: [DirtyPath] = []
        for candidate in merged where !cover.contains(where: { candidate.path.hasPrefix($0.path + "/") }) {
            cover.append(candidate)
        }
        dirtyPaths = cover
        guard liveUpdates, !cover.isEmpty, rescanThrottle == nil else { return }
        // Throttle (not debounce): constant churn must not postpone updates forever.
        rescanThrottle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await self?.rescanDirty(automatic: true)
            self?.rescanThrottle = nil
        }
    }

    /// Rescans changed subtrees (gently) and splices them into the live tree.
    func rescanDirty(automatic: Bool = false) async {
        guard let root, !isRescanning, !isBusy, !dirtyPaths.isEmpty else { return }
        isRescanning = true
        defer { isRescanning = false }
        let pending = dirtyPaths
        var remaining: [DirtyPath] = []
        var spliced = 0
        let context = makeClassificationContext()

        for dirty in pending.prefix(24) {
            var path = dirty.path
            var node = root.descendant(atPath: path)
            while node == nil || node?.isDirectory == false || node?.isProtectedLocation == true {
                let parent = (path as NSString).deletingLastPathComponent
                if parent == path || parent.count < root.path.count { break }
                path = parent
                node = root.descendant(atPath: path)
            }
            guard let target = node, let parent = target.parent, !target.isProtectedLocation, !target.isOpaque else {
                remaining.append(dirty)
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
                let fresh = try await scanner.rescanSubtree(atPath: target.path,
                                                            options: ScanOptions(rootPath: target.path, lowPriority: gentleRescans))
                let classification = await Task.detached(priority: .utility) { () -> ClassificationResult in
                    let shadow = FileTreeNode(name: parentPath, kind: .directory)
                    shadow.setChildren([fresh])
                    let result = classifier.classify(root: fresh, context: context)
                    if insideCleanupTarget {
                        fresh.walk { $0.category = inheritedCategory; return .continue }
                    }
                    return result
                }.value
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
        let handled = Set(pending.map(\.path))
        dirtyPaths = remaining + dirtyPaths.filter { !handled.contains($0.path) }
        if spliced > 0 {
            treeVersion += 1
            lastRescanSummary = "Updated \(spliced) changed folder\(spliced == 1 ? "" : "s") at \(Date().formatted(date: .omitted, time: .shortened))"
            refreshVolume()
        }
    }
}
