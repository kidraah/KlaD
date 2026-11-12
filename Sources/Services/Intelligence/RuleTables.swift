// RuleTables.swift — KlaDIntelligence
//
// Home-expanded "known location" rules, computed once per home directory and
// cached (the catalog's `match` runs for every node of multi-million node trees).

import Foundation
import os
import KlaDModels

enum KnownKind: Sendable {
    case plain
    /// Xcode DerivedData: adds the "Xcode is running" signal/warning at match time.
    case derivedData
}

struct KnownEntry: Sendable {
    let match: RuleMatch
    let kind: KnownKind
}

/// Thread-safe single-entry-hot cache of `HomeTables` keyed by home directory.
final class HomeTableCache: Sendable {
    private struct State {
        var last: HomeTables?
        var lastKey: String = ""
        var byHome: [String: HomeTables] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func tables(for home: String) -> HomeTables {
        state.withLock { state in
            if let last = state.last, state.lastKey == home { return last }
            if let existing = state.byHome[home] {
                state.last = existing
                state.lastKey = home
                return existing
            }
            let created = HomeTables(homeDirectory: home)
            state.byHome[home] = created
            state.last = created
            state.lastKey = home
            return created
        }
    }
}

final class HomeTables: Sendable {
    /// Absolute path → rule (exact match).
    let known: [String: KnownEntry]
    /// Last path components of every `known` key (cheap pre-filter before hashing the full path).
    let knownNames: Set<String>

    let downloadsPrefix: String
    let downloadsPrefixByteCount: Int
    let appSupportDir: String
    let containersDir: String
    let cachesDir: String
    let hfHubDir: String
    let gradleUserHome: String
    let lmStudioDirs: Set<String>
    /// Locations that hold installed application payloads (extensions, app support…).
    let installedAppDataPrefixes: [String]

    init(homeDirectory: String) {
        var normalized = homeDirectory
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        let h = normalized == "/" ? "" : normalized

        let table = Self.buildKnownRules(home: h)
        self.known = table
        self.knownNames = Set(table.keys.map { NameKeys.lastComponent(of: $0) })
        self.downloadsPrefix = h + "/Downloads/"
        self.downloadsPrefixByteCount = (h + "/Downloads/").utf8.count
        self.appSupportDir = h + "/Library/Application Support"
        self.containersDir = h + "/Library/Containers"
        self.cachesDir = h + "/Library/Caches"
        self.hfHubDir = h + "/.cache/huggingface/hub"
        self.gradleUserHome = h + "/.gradle"
        self.lmStudioDirs = [h + "/.lmstudio/models", h + "/.cache/lm-studio/models"]
        self.installedAppDataPrefixes = [
            h + "/Library/Application Support/",
            h + "/Library/Containers/",
            h + "/Library/Group Containers/",
            h + "/.vscode/", h + "/.vscode-insiders/", h + "/.cursor/", h + "/.windsurf/",
        ]
    }

    func isInsideInstalledAppData(_ path: String) -> Bool {
        installedAppDataPrefixes.contains { path.hasPrefix($0) }
    }

    // MARK: - Guided remediations

    static let dockerRemediation = GuidedRemediation(
        headline: "Reclaim Docker space with the Docker CLI",
        explanation: "Docker's VM disk holds every image, container and named volume (including databases). Trashing it destroys them all. Reclaim space through Docker instead.",
        commands: [
            GuidedCommand(label: "Inspect Docker disk usage", command: "docker system df", isDestructive: false),
            GuidedCommand(label: "Remove build cache", command: "docker builder prune", isDestructive: true),
            GuidedCommand(label: "Remove all unused images", command: "docker image prune -a", isDestructive: true),
            GuidedCommand(label: "Prune everything unused — Also deletes named volumes", command: "docker system prune -a --volumes", isDestructive: true),
        ],
        applicationBundleID: "com.docker.docker"
    )

    static let orbstackRemediation = GuidedRemediation(
        headline: "Reclaim OrbStack space with its CLI",
        explanation: "OrbStack stores its Linux machines, containers, images and volumes here. Trashing the folder destroys them all. Reclaim space through OrbStack or Docker instead.",
        commands: [
            GuidedCommand(label: "List OrbStack machines", command: "orb list", isDestructive: false),
            GuidedCommand(label: "Remove unused Docker data — Also deletes unused images and containers", command: "docker system prune -a", isDestructive: true),
        ],
        applicationBundleID: "dev.kdrag0n.MacVirt"
    )

    static let colimaRemediation = GuidedRemediation(
        headline: "Manage Colima / Lima VMs with their CLIs",
        explanation: "These folders hold the virtual machine disks (and everything inside them) for Colima and Lima. Trashing them destroys the VMs. Inspect and delete VMs with the tools that own them.",
        commands: [
            GuidedCommand(label: "List Colima profiles", command: "colima list", isDestructive: false),
            GuidedCommand(label: "List Lima instances", command: "limactl list", isDestructive: false),
            GuidedCommand(label: "Delete a Colima profile (replace <profile>)", command: "colima delete <profile>", isDestructive: true),
        ]
    )

    static let podmanRemediation = GuidedRemediation(
        headline: "Reclaim Podman space with the Podman CLI",
        explanation: "Podman's machine disk holds every image, container and volume. Trashing it destroys them all. Reclaim space through Podman instead.",
        commands: [
            GuidedCommand(label: "List Podman machines", command: "podman machine list", isDestructive: false),
            GuidedCommand(label: "Remove all unused Podman data", command: "podman system prune -a", isDestructive: true),
        ]
    )

    static func vmRemediation(app: String, bundleID: String, kind: String) -> GuidedRemediation {
        GuidedRemediation(
            headline: "Delete \(kind) virtual machines from inside \(app)",
            explanation: "A virtual machine bundle is the VM's whole disk. Delete VMs from inside \(app) (or use its disk-reclaim tools) so nothing is left half-removed.",
            commands: [],
            applicationBundleID: bundleID
        )
    }

    static let androidRemediation = GuidedRemediation(
        headline: "Manage Android emulators in Android Studio",
        explanation: "Each Android Virtual Device stores its own disk images. Use Android Studio's Device Manager to wipe or delete emulators instead of trashing this folder.",
        commands: [
            GuidedCommand(label: "List Android virtual devices", command: "emulator -list-avds", isDestructive: false),
        ],
        applicationBundleID: "com.google.android.studio"
    )

    static let simulatorRemediation = GuidedRemediation(
        headline: "Manage iOS Simulators with simctl",
        explanation: "Simulator devices hold app data and installed runtimes' state. Deleting the folder behind simctl's back corrupts the device list. Let simctl remove them.",
        commands: [
            GuidedCommand(label: "List simulator devices", command: "xcrun simctl list devices", isDestructive: false),
            GuidedCommand(label: "Delete simulators whose runtime is gone", command: "xcrun simctl delete unavailable", isDestructive: true),
            GuidedCommand(label: "Erase all simulators (resets every device)", command: "xcrun simctl erase all", isDestructive: true),
        ],
        applicationBundleID: "com.apple.dt.Xcode"
    )

    static let goModCacheRemediation = GuidedRemediation(
        headline: "Clear the Go module cache with Go",
        explanation: "Go stores module files read-only, so they can't be trashed reliably. Let the Go tool remove them; modules are downloaded again on the next build.",
        commands: [
            GuidedCommand(label: "Show the module cache path", command: "go env GOMODCACHE", isDestructive: false),
            GuidedCommand(label: "Remove the module cache", command: "go clean -modcache", isDestructive: true),
        ]
    )

    static let pnpmStoreRemediation = GuidedRemediation(
        headline: "Prune the pnpm store with pnpm",
        explanation: "The pnpm store is hard-linked into every node_modules folder on this Mac. Trashing it frees little and can break installed projects. Let pnpm prune packages that no project uses.",
        commands: [
            GuidedCommand(label: "Show the store location", command: "pnpm store path", isDestructive: false),
            GuidedCommand(label: "Remove unreferenced packages", command: "pnpm store prune", isDestructive: true),
        ]
    )

    // MARK: - Known-location table

    private static func buildKnownRules(home h: String) -> [String: KnownEntry] {
        var b = KnownRuleBuilder()

        // 4.2 Xcode ---------------------------------------------------------------
        let dev = h + "/Library/Developer"
        b.add(dev + "/Xcode/DerivedData", id: "xcode.derived_data", title: "Xcode DerivedData",
              category: .xcode, safety: .safeToClear, group: .xcode,
              rationale: "Build products and indexes that Xcode regenerates automatically on the next build.",
              evidence: "Xcode's DerivedData folder", regenerate: "Rebuilt automatically by Xcode", kind: .derivedData)
        b.add(dev + "/Xcode/Archives", id: "xcode.archives", title: "Xcode Archives",
              category: .xcode, safety: .reviewFirst, group: .xcode,
              rationale: "Archived app builds. Contains dSYMs needed to symbolicate crash reports of shipped builds.",
              evidence: "Xcode's Archives folder",
              warnings: ["Contains dSYMs needed to symbolicate crash reports of shipped builds."])
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            b.add("\(dev)/Xcode/\(platform) DeviceSupport", id: "xcode.device_support", title: "\(platform) DeviceSupport",
                  category: .xcode, safety: .reviewFirst, group: .xcode,
                  rationale: "Debug symbols Xcode copied from connected \(platform) devices.",
                  evidence: "Xcode's \(platform) DeviceSupport folder", regenerate: "Re-copied from the device the next time it connects.",
                  warnings: ["Re-copied from the device the next time it connects."])
        }
        b.add(dev + "/CoreSimulator/Devices", id: "xcode.simulator_devices", title: "Simulator devices",
              category: .xcode, safety: .guidedExternalAction, group: .xcode,
              rationale: "iOS Simulator device data. Manage it with simctl, not by trashing the folder.",
              evidence: "CoreSimulator's Devices folder", action: .guided(simulatorRemediation))
        b.add(dev + "/CoreSimulator/Caches", id: "xcode.simulator_caches", title: "Simulator caches",
              category: .xcode, safety: .safeToClear, group: .xcode,
              rationale: "Simulator caches that CoreSimulator rebuilds when needed.",
              evidence: "CoreSimulator's Caches folder", regenerate: "Rebuilt automatically by the Simulator")
        b.add(dev + "/Xcode/UserData/Previews", id: "xcode.previews", title: "SwiftUI Previews data",
              category: .xcode, safety: .safeToClear, group: .xcode,
              rationale: "Preview simulator data that Xcode recreates when a preview runs.",
              evidence: "Xcode's SwiftUI Previews folder", regenerate: "Rebuilt automatically by Xcode")
        b.categoryOnly(dev, .xcode, id: "category.xcode")

        // 4.3 Package caches -------------------------------------------------------
        b.cache(h + "/Library/Caches/Homebrew", id: "cache.homebrew", title: "Homebrew download cache",
                rationale: "Downloaded bottles and sources; Homebrew fetches them again when needed.", regenerate: "brew cleanup --prune=all")
        b.cache(h + "/.npm/_cacache", id: "cache.npm", title: "npm cache",
                rationale: "npm's content-addressed download cache; packages are fetched again on demand.", regenerate: "Re-downloaded automatically by npm")
        b.cache(h + "/Library/Caches/Yarn", id: "cache.yarn", title: "Yarn cache",
                rationale: "Yarn's package download cache.", regenerate: "Re-downloaded automatically by yarn")
        b.cache(h + "/.yarn/berry/cache", id: "cache.yarn_berry", title: "Yarn Berry cache",
                rationale: "Yarn Berry's global package cache.", regenerate: "Re-downloaded automatically by yarn")
        b.cache(h + "/.bun/install/cache", id: "cache.bun", title: "Bun install cache",
                rationale: "Bun's package download cache.", regenerate: "Re-downloaded automatically by bun")
        b.cache(h + "/Library/Caches/pip", id: "cache.pip", title: "pip cache",
                rationale: "pip's wheel and HTTP cache.", regenerate: "Re-downloaded automatically by pip")
        b.cache(h + "/Library/Caches/pypoetry", id: "cache.poetry", title: "Poetry cache",
                rationale: "Poetry's package and virtualenv cache.", regenerate: "Re-downloaded automatically by poetry")
        b.cache(h + "/.cache/uv", id: "cache.uv", title: "uv cache",
                rationale: "uv's package cache.", regenerate: "Re-downloaded automatically by uv")
        b.cache(h + "/Library/Caches/uv", id: "cache.uv", title: "uv cache",
                rationale: "uv's package cache.", regenerate: "Re-downloaded automatically by uv")
        b.cache(h + "/.cargo/registry", id: "cache.cargo_registry", title: "Cargo registry cache",
                rationale: "Downloaded crate sources and indexes; cargo fetches them again on the next build.", regenerate: "Re-downloaded by cargo build")
        b.cache(h + "/.cargo/git", id: "cache.cargo_git", title: "Cargo git cache",
                rationale: "Git checkouts of crate dependencies; cargo fetches them again on the next build.", regenerate: "Re-downloaded by cargo build")
        b.cache(h + "/.gradle/caches", id: "cache.gradle", title: "Gradle caches",
                rationale: "Gradle's dependency and build caches.", regenerate: "Rebuilt automatically by Gradle")
        b.cache(h + "/Library/Caches/CocoaPods", id: "cache.cocoapods", title: "CocoaPods cache",
                rationale: "CocoaPods' downloaded pod sources.", regenerate: "Re-downloaded by pod install")
        b.cache(h + "/Library/Caches/org.carthage.CarthageKit", id: "cache.carthage", title: "Carthage cache",
                rationale: "Carthage's downloaded dependency checkouts and builds.", regenerate: "Rebuilt by carthage bootstrap")
        b.cache(h + "/Library/Caches/go-build", id: "cache.go_build", title: "Go build cache",
                rationale: "Go's compiled-package cache.", regenerate: "Rebuilt automatically by go build")
        b.add(h + "/go/pkg/mod", id: "cache.go_modcache", title: "Go module cache",
              category: .caches, safety: .guidedExternalAction, group: .packageCaches,
              rationale: "Downloaded Go modules. Their files are read-only, so Go must remove them.",
              evidence: "Go's module cache", action: .guided(goModCacheRemediation))
        for store in ["/Library/pnpm/store", "/.local/share/pnpm/store", "/.pnpm-store"] {
            b.add(h + store, id: "cache.pnpm_store", title: "pnpm store",
                  category: .caches, safety: .guidedExternalAction, group: .packageCaches,
                  rationale: "pnpm's global package store is hard-linked into every node_modules folder, so trashing it frees little and can break projects.",
                  evidence: "pnpm's global store", action: .guided(pnpmStoreRemediation))
        }
        b.add(h + "/.m2/repository", id: "cache.maven", title: "Maven local repository",
              category: .caches, safety: .reviewFirst, group: .packageCaches,
              rationale: "Downloaded Maven artifacts. Most are fetched again on demand.",
              evidence: "Maven's local repository", regenerate: "Re-downloaded automatically by mvn",
              warnings: ["May contain artifacts installed locally with `mvn install`."])
        b.categoryOnly(h + "/Library/Caches", .caches, id: "category.caches")
        b.categoryOnly("/Library/Caches", .caches, id: "category.caches")

        // 4.4 AI models --------------------------------------------------------------
        b.add(h + "/.ollama/models", id: "ai.ollama", title: "Ollama models",
              category: .aiModels, safety: .reviewFirst, group: .aiModels,
              rationale: "Downloaded Ollama model weights.", evidence: "Ollama's model store", regenerate: "ollama pull <model>",
              warnings: ["Deleting requires re-downloading multi-GB model weights.", "Prefer `ollama rm <model>` to remove individual models."])
        b.categoryOnly(h + "/.cache/huggingface/hub", .aiModels, id: "category.ai_huggingface")
        b.categoryOnly(h + "/.lmstudio/models", .aiModels, id: "category.ai_lmstudio")
        b.categoryOnly(h + "/.cache/lm-studio/models", .aiModels, id: "category.ai_lmstudio")

        // 4.5 Containers & VMs (guided only) ---------------------------------------------
        for path in [h + "/.orbstack", h + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack"] {
            b.add(path, id: "orbstack.data", title: "OrbStack data",
                  category: .containersVMs, safety: .guidedExternalAction, group: .containersAndVMs,
                  rationale: "OrbStack's machines, containers and volumes. Manage them with OrbStack, not by trashing the folder.",
                  evidence: "OrbStack's data folder", action: .guided(orbstackRemediation))
        }
        for path in [h + "/.colima", h + "/.lima"] {
            b.add(path, id: "colima.vm", title: "Colima / Lima VMs",
                  category: .containersVMs, safety: .guidedExternalAction, group: .containersAndVMs,
                  rationale: "Virtual machine disks for Colima and Lima. Manage them with their CLIs, not by trashing the folder.",
                  evidence: "Colima / Lima data folder", action: .guided(colimaRemediation))
        }
        b.add(h + "/.local/share/containers/podman/machine", id: "podman.machine", title: "Podman machine",
              category: .containersVMs, safety: .guidedExternalAction, group: .containersAndVMs,
              rationale: "Podman's VM disk and images. Manage it with the Podman CLI, not by trashing the folder.",
              evidence: "Podman's machine folder", action: .guided(podmanRemediation))
        b.add(h + "/.android/avd", id: "android.avd", title: "Android virtual devices",
              category: .containersVMs, safety: .guidedExternalAction, group: .containersAndVMs,
              rationale: "Android emulator disks. Use Android Studio's Device Manager to remove them.",
              evidence: "Android's AVD folder", action: .guided(androidRemediation))

        // 4.7 Protected / category-only ----------------------------------------------------
        for path in ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/private/var/vm", "/Library/Apple", "/cores"] {
            b.add(path, id: "system.protected", title: "System location",
                  category: .system, safety: .doNotDelete, group: .system,
                  rationale: "Owned by macOS. KlaD never deletes system files.",
                  evidence: "Protected system location", recommend: false, descend: true)
        }
        // `/usr/local` is the one part of `/usr` that is not OS-owned: give it its own
        // (inspect-only) annotation so it does not inherit "Protected" from `/usr`.
        b.add("/usr/local", id: "system.usr_local", title: "/usr/local",
              category: .other, safety: .unknown, group: .system,
              rationale: "Locally installed software (not owned by macOS). No evidence it is regeneratable — inspect only.",
              evidence: "/usr/local", recommend: false, descend: true)
        for path in [h + "/Documents", h + "/Desktop"] {
            b.add(path, id: "user.documents", title: "Personal documents",
                  category: .documents, safety: .doNotDelete, group: .appData,
                  rationale: "Your personal files. KlaD never recommends deleting them.",
                  evidence: "User documents folder", recommend: false, descend: true)
        }
        for path in [h + "/Library/Mobile Documents", h + "/Library/CloudStorage"] {
            b.add(path, id: "user.icloud", title: "iCloud / cloud storage",
                  category: .documents, safety: .doNotDelete, group: .appData,
                  rationale: "Synced cloud files. KlaD never reads or deletes them.",
                  evidence: "Cloud storage folder", recommend: false, descend: true)
        }
        for path in [h + "/Library/Mail", h + "/Library/Messages"] {
            b.add(path, id: "user.mail_messages", title: "Mail & Messages",
                  category: .documents, safety: .doNotDelete, group: .appData,
                  rationale: "Your mail and message history. KlaD never deletes it.",
                  evidence: "Mail / Messages data", recommend: false, descend: true)
        }
        b.categoryOnly(h + "/Library/Application Support", .applications, id: "category.applications")
        b.categoryOnly(h + "/Library/Containers", .applications, id: "category.applications")
        b.categoryOnly(h + "/Movies", .media, id: "category.media")
        b.categoryOnly(h + "/Music", .media, id: "category.media")
        b.categoryOnly(h + "/Pictures", .media, id: "category.media")
        b.categoryOnly("/Applications", .applications, id: "category.applications")
        b.categoryOnly(h + "/Applications", .applications, id: "category.applications")
        for path in ["/Library", "/private"] {
            b.categoryOnly(path, .system, id: "category.system")
        }
        return b.entries
    }
}

struct KnownRuleBuilder {
    private(set) var entries: [String: KnownEntry] = [:]

    mutating func add(
        _ path: String,
        id: String,
        title: String,
        category: StorageCategory,
        safety: SafetyLevel,
        group: RecommendationGroup,
        rationale: String,
        evidence: String = "Well-known tool location",
        action: CleanupAction? = nil,
        regenerate: String? = nil,
        warnings: [String] = [],
        recommend: Bool = true,
        descend: Bool = false,
        kind: KnownKind = .plain
    ) {
        let resolvedAction = action ?? (safety.permitsTrash ? .moveToTrash : .inspectOnly)
        let match = RuleMatch(
            ruleID: id, title: title, category: category, safety: safety, group: group,
            rationale: rationale,
            evidence: [Evidence(kind: .knownLocation, detail: evidence, path: path)],
            action: resolvedAction,
            regenerateCommand: regenerate,
            warnings: warnings,
            signals: [],
            recommend: recommend,
            descend: descend
        )
        entries[path] = KnownEntry(match: match, kind: kind)
    }

    /// Package-manager cache: safeToClear, `.caches`, `.packageCaches`.
    mutating func cache(_ path: String, id: String, title: String, rationale: String, regenerate: String?) {
        add(path, id: id, title: title, category: .caches, safety: .safeToClear, group: .packageCaches,
            rationale: rationale, evidence: "Known package-manager cache location", regenerate: regenerate)
    }

    /// Category-only rule: the engine sets the category (and descendants inherit it) but attaches no
    /// annotation and emits no recommendation. Convention: ruleID starts with "category.".
    mutating func categoryOnly(_ path: String, _ category: StorageCategory, id: String) {
        let group: RecommendationGroup
        switch category {
        case .caches: group = .packageCaches
        case .xcode: group = .xcode
        case .aiModels: group = .aiModels
        case .system: group = .system
        default: group = .appData
        }
        add(path, id: id, title: category.displayName, category: category, safety: .unknown, group: group,
            rationale: "Category only.", recommend: false, descend: true)
    }
}
