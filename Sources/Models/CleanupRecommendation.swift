// CleanupRecommendation.swift — KlaDModels
//
// A recommendation is what the Save Space Hub renders as a card: what the item
// is, the POSITIVE evidence behind its safety tier, informational supporting
// signals (never proof), and exactly what KlaD will (or will not) do about it.

import Foundation

/// Save Space Hub grouping.
public enum RecommendationGroup: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    /// node_modules, target/, .build/, .next/, dist/, build/, virtualenvs.
    case buildArtifacts
    /// Homebrew, npm, pnpm, pip, cargo registry, Go mod cache…
    case packageCaches
    /// DerivedData, Archives, iOS DeviceSupport, simulators.
    case xcode
    /// Ollama, Hugging Face, LM Studio weights.
    case aiModels
    /// Old .dmg / .pkg / .zip installers.
    case installersAndArchives
    /// Docker.raw, OrbStack, Colima, UTM, Parallels.
    case containersAndVMs
    /// Local APFS / Time Machine snapshots.
    case snapshots
    /// Byte-identical files (verified SHA-256, never cloud stubs, never clones).
    case duplicates
    /// ~/Library/Application Support and similar app-owned data (inspect only).
    case appData
    /// Data left behind by apps that are no longer installed (review first, hints only).
    case appLeftovers
    /// OS-owned locations.
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .buildArtifacts: return "Regeneratable Build Artifacts"
        case .packageCaches: return "Package Manager Caches"
        case .xcode: return "Xcode Data"
        case .aiModels: return "AI Model Weights"
        case .installersAndArchives: return "Installers & Archives"
        case .containersAndVMs: return "Containers & Virtual Machines"
        case .snapshots: return "Local Snapshots"
        case .duplicates: return "Duplicate Files"
        case .appData: return "Application Data"
        case .appLeftovers: return "Leftovers of Removed Apps"
        case .system: return "System"
        }
    }

    public var symbolName: String {
        switch self {
        case .buildArtifacts: return "hammer.fill"
        case .packageCaches: return "shippingbox.and.arrow.backward.fill"
        case .xcode: return "swift"
        case .aiModels: return "brain"
        case .installersAndArchives: return "opticaldiscdrive.fill"
        case .containersAndVMs: return "cube.box.fill"
        case .snapshots: return "clock.arrow.circlepath"
        case .duplicates: return "doc.on.doc.fill"
        case .appData: return "app.dashed"
        case .appLeftovers: return "trash.square"
        case .system: return "lock.shield.fill"
        }
    }
}

/// Positive evidence backing a safety tier.
public struct Evidence: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// A build manifest (package.json, Cargo.toml, Package.swift, pyproject.toml…).
        case manifest
        /// A dependency lockfile (package-lock.json, pnpm-lock.yaml, Cargo.lock…).
        case lockfile
        /// A tool marker inside the item (pyvenv.cfg, CACHEDIR.TAG…).
        case configFile
        /// A well-known location owned by a tool (~/Library/Developer/Xcode/DerivedData).
        case knownLocation
        /// Content-based proof (matching SHA-256).
        case contentSignature
        /// Live system state (Xcode not running, no open file handles).
        case runtimeState
    }

    public var kind: Kind
    /// Human sentence: "Sibling package.json found".
    public var detail: String
    /// The file that constitutes the evidence, if any.
    public var path: String?

    public init(kind: Kind, detail: String, path: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.path = path
    }
}

/// Informational badges. These NEVER constitute proof of safety on their own.
public enum SupportingSignal: Sendable, Hashable, Codable {
    /// Not modified for N days.
    case inactive(days: Int)
    /// Modified within the last N days.
    case recentlyModified(days: Int)
    /// Enclosing git working tree is clean.
    case gitClean
    /// Enclosing git working tree has N uncommitted changes.
    case gitUncommittedChanges(count: Int)
    /// Last commit N days ago.
    case gitLastCommit(daysAgo: Int)
    /// Not inside a git repository.
    case notGitRepository
    /// Manifest present but no lockfile — reinstall may resolve different versions.
    case missingLockfile
    /// A related application is running (e.g. Xcode for DerivedData).
    case applicationRunning(name: String)
    /// Processes hold open file descriptors inside the item.
    case openFileHandles(processNames: [String])
    /// Content is hard-linked elsewhere (e.g. pnpm store) — deleting frees little.
    case hardLinkedContent
    /// Content shares blocks with APFS clones — deleting frees only private bytes.
    case cloneSharedContent
    /// Free-form.
    case custom(text: String, isWarning: Bool)

    public var text: String {
        switch self {
        case .inactive(let days): return "Inactive for \(days) day\(days == 1 ? "" : "s")"
        case .recentlyModified(let days):
            return days == 0 ? "Modified today" : "Modified \(days) day\(days == 1 ? "" : "s") ago"
        case .gitClean: return "Clean Git tree"
        case .gitUncommittedChanges(let count):
            return "\(count) uncommitted change\(count == 1 ? "" : "s") in repo"
        case .gitLastCommit(let daysAgo):
            return daysAgo == 0 ? "Committed today" : "Last commit \(daysAgo)d ago"
        case .notGitRepository: return "Not in a Git repo"
        case .missingLockfile: return "No lockfile — reinstall may pick different versions"
        case .applicationRunning(let name): return "\(name) is running"
        case .openFileHandles(let names):
            return "Open in " + (names.isEmpty ? "another process" : names.prefix(3).joined(separator: ", "))
        case .hardLinkedContent: return "Hard-linked content (frees little)"
        case .cloneSharedContent: return "Shares blocks with APFS clones"
        case .custom(let text, _): return text
        }
    }

    public var isWarning: Bool {
        switch self {
        case .gitUncommittedChanges, .missingLockfile, .applicationRunning, .openFileHandles,
             .hardLinkedContent, .cloneSharedContent, .recentlyModified:
            return true
        case .custom(_, let warning): return warning
        case .inactive, .gitClean, .gitLastCommit, .notGitRepository: return false
        }
    }

    public var symbolName: String {
        switch self {
        case .inactive: return "moon.zzz.fill"
        case .recentlyModified: return "clock.badge.exclamationmark"
        case .gitClean: return "checkmark.circle"
        case .gitUncommittedChanges: return "exclamationmark.circle"
        case .gitLastCommit: return "point.topleft.down.to.point.bottomright.curvepath"
        case .notGitRepository: return "circle.dashed"
        case .missingLockfile: return "lock.open"
        case .applicationRunning: return "app.badge"
        case .openFileHandles: return "doc.badge.ellipsis"
        case .hardLinkedContent: return "link"
        case .cloneSharedContent: return "square.on.square"
        case .custom(_, let warning): return warning ? "exclamationmark.triangle" : "info.circle"
        }
    }
}

/// One copyable CLI step in a guided remediation.
public struct GuidedCommand: Sendable, Hashable, Codable, Identifiable {
    public var id: String { command }
    /// "Inspect Docker disk usage".
    public var label: String
    /// "docker system df".
    public var command: String
    /// True for commands that delete data (rendered with a warning).
    public var isDestructive: Bool

    public init(label: String, command: String, isDestructive: Bool) {
        self.label = label
        self.command = command
        self.isDestructive = isDestructive
    }
}

/// How to reclaim space WITHOUT KlaD touching the backing file.
public struct GuidedRemediation: Sendable, Hashable, Codable {
    /// "Reclaim Docker space with the Docker CLI".
    public var headline: String
    /// Why the file must not be trashed and what the commands do.
    public var explanation: String
    public var commands: [GuidedCommand]
    /// Bundle id of the owning app to offer an "Open App" button (e.g. "com.docker.docker").
    public var applicationBundleID: String?

    public init(headline: String, explanation: String, commands: [GuidedCommand], applicationBundleID: String? = nil) {
        self.headline = headline
        self.explanation = explanation
        self.commands = commands
        self.applicationBundleID = applicationBundleID
    }
}

/// What KlaD offers for a recommendation.
public enum CleanupAction: Sendable, Hashable, Codable {
    /// Move to Trash after pre-flight (`FileManager.trashItem`, never `removeItem`).
    case moveToTrash
    /// Never trash — show the guided remediation.
    case guided(GuidedRemediation)
    /// Show and explain only.
    case inspectOnly

    public var isTrashable: Bool {
        if case .moveToTrash = self { return true }
        return false
    }

    public var guidedRemediation: GuidedRemediation? {
        if case .guided(let remediation) = self { return remediation }
        return nil
    }
}

public struct CleanupRecommendation: Sendable, Identifiable, Hashable {
    /// Stable id: "\(ruleID)|\(path)".
    public var id: String
    /// Rule that produced this ("node.node_modules", "xcode.derived_data", …).
    public var ruleID: String
    /// "node_modules", "DerivedData", "Docker.raw".
    public var title: String
    /// Absolute path of the target.
    public var path: String
    public var category: StorageCategory
    public var safety: SafetyLevel
    public var group: RecommendationGroup
    /// Size snapshot at scan time. Reclaimable = `metrics.privateBytes`.
    public var metrics: StorageMetrics
    /// Why it was flagged, one or two sentences.
    public var rationale: String
    /// Positive evidence backing `safety`.
    public var evidence: [Evidence]
    /// Informational badges (age, git, open handles…). May be appended asynchronously.
    public var signals: [SupportingSignal]
    public var action: CleanupAction
    /// Command that recreates the content ("npm install", "cargo build").
    public var regenerateCommand: String?
    /// Extra cautions shown in the pre-flight sheet.
    public var warnings: [String]
    /// Identity at scan time, re-verified before trashing.
    public var identity: NodeIdentity

    public init(
        ruleID: String,
        title: String,
        path: String,
        category: StorageCategory,
        safety: SafetyLevel,
        group: RecommendationGroup,
        metrics: StorageMetrics,
        rationale: String,
        evidence: [Evidence] = [],
        signals: [SupportingSignal] = [],
        action: CleanupAction,
        regenerateCommand: String? = nil,
        warnings: [String] = [],
        identity: NodeIdentity
    ) {
        self.id = "\(ruleID)|\(path)"
        self.ruleID = ruleID
        self.title = title
        self.path = path
        self.category = category
        self.safety = safety
        self.group = group
        self.metrics = metrics
        self.rationale = rationale
        self.evidence = evidence
        self.signals = signals
        self.action = action
        self.regenerateCommand = regenerateCommand
        self.warnings = warnings
        self.identity = identity
    }

    /// Bytes freed immediately if trashed (and the Trash emptied).
    public var reclaimableBytes: UInt64 { metrics.privateBytes }

    /// Whether KlaD may offer "Move to Trash" for this recommendation.
    public var isTrashable: Bool { safety.permitsTrash && action.isTrashable }
}
