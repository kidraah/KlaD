// AppState.swift — composition root & single source of truth.
//
// Threading follows the FileTreeNode contract: scan, classification, snapshot
// capture and duplicate-candidate collection run off-main BEFORE publication.
// After publication the tree is mutated only here, on the MainActor (cleanup
// removals and FSEvents-driven subtree splices); every mutation bumps
// `treeVersion`.

import AppKit
import Foundation
import Observation
import SwiftUI
import KlaDIntelligence
import KlaDModels
import KlaDScanner
import KlaDStorageOps

// MARK: - Navigation model

/// Window appearance. Automatic follows the system (the default).
enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .automatic: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

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
    case overview, recommendations, duplicates, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .recommendations: return "Recommendations"
        case .duplicates: return "Duplicates"
        case .history: return "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "chart.pie"
        case .recommendations: return "sparkles"
        case .duplicates: return "doc.on.doc"
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
    /// Context ("Identical to …", "Inside node_modules").
    let note: String?

    var requiresReviewAcknowledgement: Bool { target.safety.requiresExplicitReview }
}

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
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
    private(set) var scannedAt: Date?
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

    // MARK: Live updates
    private(set) var dirtyPaths: [DirtyPath] = []
    private(set) var needsFullRescan = false
    private(set) var isRescanning = false
    private(set) var lastRescanSummary: String?
    private var watchTask: Task<Void, Never>?
    private var rescanThrottle: Task<Void, Never>?

    // MARK: Cleanup
    var cleanupRequest: CleanupRequest?
    private(set) var reclaimedThisSession: UInt64 = 0

    // MARK: Settings (persisted)
    var liveUpdates: Bool { didSet { defaults.set(liveUpdates, forKey: "liveUpdates"); liveUpdatesChanged() } }
    var gentleRescans: Bool { didSet { defaults.set(gentleRescans, forKey: "gentleRescans") } }
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    var excludedPaths: [String] { didSet { defaults.set(excludedPaths, forKey: "excludedPaths") } }
    var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); appearance.apply() } }

    // MARK: Services
    let scanner: any StorageScanning
    let volumeInspector: any VolumeInspecting
    let classifier: any StorageClassifying
    let git: any GitRepositoryInspecting
    let history: (any SnapshotHistoryStoring)?
    let duplicates: any DuplicateDetecting
    let cleanup: any SafeCleanupPerforming
    let watcher: any FileSystemWatching

    @ObservationIgnored private let defaults = UserDefaults.standard

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

        let defaults = UserDefaults.standard
        defaults.register(defaults: ["liveUpdates": true, "gentleRescans": true, "historyLimit": 60])
        liveUpdates = defaults.bool(forKey: "liveUpdates")
        gentleRescans = defaults.bool(forKey: "gentleRescans")
        historyLimit = max(5, defaults.integer(forKey: "historyLimit"))
        excludedPaths = defaults.stringArray(forKey: "excludedPaths") ?? []
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .automatic
        if let data = defaults.data(forKey: "customLocations"),
           let saved = try? JSONDecoder().decode([ScanLocation].self, from: data) {
            customLocations = saved
        }
    }

    // MARK: - Derived

    var isBusy: Bool { phase == .scanning || phase == .analyzing }
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
    }

    private func persistLocations() {
        if let data = try? JSONEncoder().encode(customLocations) { defaults.set(data, forKey: "customLocations") }
    }

    // MARK: Per-location sessions (switching never rescans)

    /// Everything shown for one scanned location, kept in memory so switching
    /// back is instant. Stashed sessions keep collecting FSEvents changes and
    /// catch up (changed folders only) when shown again.
    private struct LocationSession {
        let location: ScanLocation
        let result: ScanResult
        let focus: FileTreeNode?
        let selection: FileTreeNode?
        let volume: VolumeSpaceReport?
        let scannedAt: Date?
        let recommendations: [CleanupRecommendation]
        let categoryTotals: [StorageCategory: StorageMetrics]
        let duplicateGroups: [DuplicateGroup]
        let duplicatesSearched: Bool
        let duplicateCandidates: [DuplicateCandidate]
        let lastRescanSummary: String?
        var dirtyPaths: [DirtyPath]
        var needsFullRescan: Bool
    }

    /// Most-recently-used last; at most `maxSessions` kept (memory).
    @ObservationIgnored private var sessions: [String: LocationSession] = [:]
    @ObservationIgnored private var sessionOrder: [String] = []
    private static let maxSessions = 3

    /// Locations whose results are ready to show instantly.
    private(set) var cachedLocationPaths: Set<String> = []

    /// Shows a location: instantly if it was scanned this session, otherwise scans it.
    func open(_ location: ScanLocation) {
        if location == currentLocation, root != nil || isBusy { return }
        stashCurrent()
        currentLocation = location
        if let session = sessions.removeValue(forKey: location.path) {
            sessionOrder.removeAll { $0 == location.path }
            restore(session)
        } else {
            startScan(path: location.path)
        }
        cachedLocationPaths = Set(sessions.keys).union(root.map { _ in [location.path] } ?? [])
    }

    /// Full rescan of the current location (the only thing that rescans everything).
    func rescan() {
        guard let location = currentLocation else { return }
        sessions[location.path] = nil
        sessionOrder.removeAll { $0 == location.path }
        startScan(path: location.path)
    }

    /// Full rescan of any location from the sidebar.
    func rescan(_ location: ScanLocation) {
        if location == currentLocation { rescan(); return }
        sessions[location.path] = nil
        sessionOrder.removeAll { $0 == location.path }
        open(location)
    }

    private func stashCurrent() {
        guard let location = currentLocation else { return }
        guard phase == .ready, let result else {
            if isBusy { cancelScan() }
            return
        }
        sessions[location.path] = LocationSession(
            location: location, result: result, focus: focus, selection: selection, volume: volume,
            scannedAt: scannedAt, recommendations: recommendations, categoryTotals: categoryTotals,
            duplicateGroups: duplicateGroups, duplicatesSearched: duplicatesSearched,
            duplicateCandidates: duplicateCandidates, lastRescanSummary: lastRescanSummary,
            dirtyPaths: dirtyPaths, needsFullRescan: needsFullRescan)
        sessionOrder.removeAll { $0 == location.path }
        sessionOrder.append(location.path)
        while sessionOrder.count > Self.maxSessions {
            sessions[sessionOrder.removeFirst()] = nil
        }
        duplicateTask?.cancel()
        isFindingDuplicates = false
    }

    private func restore(_ session: LocationSession) {
        result = session.result
        root = session.result.root
        focus = session.focus ?? session.result.root
        selection = session.selection
        volume = session.volume
        scannedAt = session.scannedAt
        recommendations = session.recommendations
        categoryTotals = session.categoryTotals
        duplicateGroups = session.duplicateGroups
        duplicatesSearched = session.duplicatesSearched
        duplicateCandidates = session.duplicateCandidates
        lastRescanSummary = session.lastRescanSummary
        dirtyPaths = session.dirtyPaths
        needsFullRescan = session.needsFullRescan
        diff = nil
        diffBaseID = nil
        treeVersion += 1
        phase = .ready
        refreshVolume()
        Task { await self.reloadHistory() }
        restartWatching()
        // Catch up on what changed while this location wasn't shown.
        if liveUpdates && !dirtyPaths.isEmpty {
            Task { await self.rescanDirty(automatic: true) }
        }
    }

    // MARK: - Scanning

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
        let options = ScanOptions(rootPath: path, excludedPaths: Set(excludedPaths))
        let scanStart = ContinuousClock().now

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
                Trace.log("scan done (\(scanResult.root.metrics.itemCount) items)", since: scanStart)
                let processed = await self.postProcess(scanResult)
                let report = await volumeReport
                if Task.isCancelled { return }
                self.publish(scanResult, processed, volume: report)
                Trace.log("ready", since: scanStart)
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
        duplicateGroups = []
        duplicateCandidates = []
        duplicatesSearched = false
        dirtyPaths = []
        needsFullRescan = false
        diff = nil
        diffBaseID = nil
        lastRescanSummary = nil
    }

    private struct PostProcessed: Sendable {
        let classification: ClassificationResult
        let snapshot: ScanSnapshot
        let candidates: [DuplicateCandidate]
    }

    /// Classification (the only writer) runs first, then the read-only passes in parallel.
    private func postProcess(_ scanResult: ScanResult) async -> PostProcessed {
        let classifier = self.classifier
        let context = makeClassificationContext()
        return await Task.detached(priority: .userInitiated) {
            let start = ContinuousClock().now
            let root = scanResult.root
            let classification = classifier.classify(root: root, context: context)
            Trace.log("classify", since: start)
            async let snapshot = { () -> ScanSnapshot in
                let t = ContinuousClock().now
                let value = ScanSnapshot.capture(from: root, startedAt: scanResult.startedAt,
                                                 completedAt: scanResult.completedAt, volume: nil)
                Trace.log("snapshot capture", since: t)
                return value
            }()
            async let candidates = { () -> [DuplicateCandidate] in
                let t = ContinuousClock().now
                let value = DuplicateCandidate.collect(from: root, minimumBytes: 1 << 20)
                Trace.log("duplicate candidates (\(value.count))", since: t)
                return value
            }()
            let result = await PostProcessed(classification: classification, snapshot: snapshot, candidates: candidates)
            Trace.log("post-process", since: start)
            return result
        }.value
    }

    private func publish(_ scanResult: ScanResult, _ processed: PostProcessed, volume report: VolumeSpaceReport?) {
        result = scanResult
        root = scanResult.root
        focus = scanResult.root
        selection = nil
        volume = report
        scannedAt = scanResult.completedAt
        categoryTotals = processed.classification.categoryTotals
        recommendations = (processed.classification.recommendations + syntheticRecommendations(volume: report))
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        duplicateCandidates = processed.candidates
        treeVersion += 1
        phase = .ready

        var snapshot = processed.snapshot
        snapshot.volume = report
        Task { await self.saveAndReloadHistory(snapshot) }
        Task { await self.enrichWithGitSignals() }
        cachedLocationPaths.insert(currentLocation?.path ?? scanResult.root.path)
        restartWatching()
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
        if selection !== node { selection = node }
    }

    /// Selects a node by path, focusing its parent, and shows the overview.
    func reveal(path: String) {
        guard let root, let node = root.descendant(atPath: path) else { return }
        focus = node.isDirectory && !node.isProtectedLocation && node.hasChildren ? node : (node.parent ?? root)
        select(node)
        sidebarSelection = .section(.overview)
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

    /// Duplicates are never rule-proven, so always Review First.
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

    // MARK: - Live updates (FSEvents)

    private func liveUpdatesChanged() {
        restartWatching()
    }

    /// One FSEvents stream for every scanned location (shown or stashed).
    private func restartWatching() {
        stopWatching()
        guard liveUpdates else { return }
        var roots = sessions.values.map(\.result.root.path)
        if let root { roots.append(root.path) }
        let paths = Array(Set(roots.map { $0 == "/" ? NSHomeDirectory() : $0 })).sorted()
        guard !paths.isEmpty, let stream = try? watcher.start(paths: paths, latency: 2.5) else { return }
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

    /// Merges a batch into a location's dirty set (minimal cover). Returns
    /// whether the location's root itself needs a full rescan.
    private static func merge(_ existing: [DirtyPath], _ batch: [DirtyPath], rootPath: String) -> ([DirtyPath], Bool) {
        let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
        var merged = existing
        var full = false
        for dirty in batch where dirty.path == rootPath || dirty.path.hasPrefix(rootPrefix) {
            if dirty.path == rootPath {
                if dirty.recursive { full = true }
                continue
            }
            if let index = merged.firstIndex(where: { $0.path == dirty.path }) {
                merged[index].recursive = merged[index].recursive || dirty.recursive
            } else {
                merged.append(dirty)
            }
        }
        merged.sort { $0.path.count < $1.path.count }
        var cover: [DirtyPath] = []
        for candidate in merged where !cover.contains(where: { candidate.path.hasPrefix($0.path + "/") }) {
            cover.append(candidate)
        }
        return (cover, full)
    }

    private func absorb(_ batch: DirtyPathBatch) {
        for key in Array(sessions.keys) {
            guard var session = sessions[key] else { continue }
            let (cover, full) = Self.merge(session.dirtyPaths, batch.paths, rootPath: session.result.root.path)
            session.dirtyPaths = cover
            session.needsFullRescan = session.needsFullRescan || full
            sessions[key] = session
        }
        guard let root else { return }
        let (cover, full) = Self.merge(dirtyPaths, batch.paths, rootPath: root.path)
        if full { needsFullRescan = true }
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

/// `KLAD_TRACE=1` prints phase timings to stderr.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["KLAD_TRACE"] != nil

    static func log(_ label: String, since start: ContinuousClock.Instant) {
        guard enabled else { return }
        let elapsed = ContinuousClock().now - start
        FileHandle.standardError.write(Data("[klad] \(label): \(elapsed)\n".utf8))
    }
}
