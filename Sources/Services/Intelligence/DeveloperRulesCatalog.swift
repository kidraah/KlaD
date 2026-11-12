// DeveloperRulesCatalog.swift — KlaDIntelligence
//
// Pure, in-memory rule evaluation (no disk I/O). Evidence comes from the node,
// its children and its siblings in the scanned tree.
//
// Dispatch order (cheapest first, because `match` runs for every node):
//   directories: directory-name rules → extension rules (.app, .utm …) →
//                known absolute locations (name pre-filter, then path lookup) →
//                direct-child rules (App Support, Caches, Hugging Face, LM Studio)
//   files:       Docker.raw / Docker.qcow2 → stale installers in ~/Downloads

import Foundation
import KlaDModels

public struct DeveloperRulesCatalog: DeveloperRulesCataloging {
    private let cache = HomeTableCache()

    public init() {}

    // MARK: - DeveloperRulesCataloging

    public func match(node: FileTreeNode, path: String, context: ClassificationContext) -> RuleMatch? {
        switch node.kind {
        case .directory: return matchDirectory(node, path: path, context: context)
        case .file: return matchFile(node, path: path, context: context)
        case .symlink, .other: return nil
        }
    }

    public func categoryHint(forFileNamed name: String) -> StorageCategory? {
        CategoryHints.hint(forFileNamed: name)
    }

    // MARK: - Directory dispatch

    private enum DirRule: Sendable {
        case nodeModules, rustTarget, swiftBuild, pythonVenv, frameworkCache, distBuild
        case gradleProject, dartTool, cocoaPods, stackWork, elixir, terraform
    }

    private static let dirNameRules: [String: DirRule] = [
        "node_modules": .nodeModules,
        "target": .rustTarget,
        ".build": .swiftBuild,
        ".venv": .pythonVenv, "venv": .pythonVenv,
        ".next": .frameworkCache, ".nuxt": .frameworkCache, ".svelte-kit": .frameworkCache, ".turbo": .frameworkCache,
        ".parcel-cache": .frameworkCache, ".astro": .frameworkCache, ".angular": .frameworkCache,
        "dist": .distBuild, "build": .distBuild, "out": .distBuild,
        ".gradle": .gradleProject,
        ".dart_tool": .dartTool,
        "Pods": .cocoaPods,
        ".stack-work": .stackWork,
        "_build": .elixir, "deps": .elixir,
        ".terraform": .terraform,
    ]

    private enum ExtRule: Sendable {
        case app, mediaLibrary, utm, parallels, vmware
    }

    private static let dirExtensionRules: [String: ExtRule] = [
        "app": .app,
        "photoslibrary": .mediaLibrary, "musiclibrary": .mediaLibrary, "tvlibrary": .mediaLibrary,
        "fcpbundle": .mediaLibrary, "logicx": .mediaLibrary,
        "utm": .utm, "pvm": .parallels, "vmwarevm": .vmware,
    ]

    /// Names that can be the *parent* of a rule-bearing direct child.
    private static let parentGateNames: Set<String> = ["Application Support", "Containers", "Caches", "hub"]

    private func matchDirectory(_ node: FileTreeNode, path: String, context: ClassificationContext) -> RuleMatch? {
        let parent = node.parent
        // Root nodes are named by absolute path; rules key on the last component.
        let name = parent == nil ? NameKeys.lastComponent(of: node.name) : node.name
        let site = Site(node: node, name: name, path: path, parent: parent, context: context)

        if let rule = Self.dirNameRules[name] {
            let tables = cache.tables(for: context.homeDirectory)
            if let match = evaluate(rule, site, tables) { return match }
        }

        if name.utf8.count > 3, let ext = NameKeys.lowercasedExtension(of: name), let rule = Self.dirExtensionRules[ext] {
            return evaluate(rule, site)
        }

        let tables = cache.tables(for: context.homeDirectory)
        if tables.knownNames.contains(name), let entry = tables.known[path] {
            return resolve(entry, context)
        }

        if let parent {
            return matchByParent(site, parent: parent, tables: tables)
        }
        return nil
    }

    // MARK: - Site helper

    private struct Site {
        let node: FileTreeNode
        let name: String
        let path: String
        let parent: FileTreeNode?
        let context: ClassificationContext

        var parentDir: String { NameKeys.parentPath(of: path, name: name) }

        func childPath(_ child: String) -> String {
            path.hasSuffix("/") ? path + child : path + "/" + child
        }

        func siblingPath(_ sibling: String) -> String {
            let dir = parentDir
            return dir.hasSuffix("/") ? dir + sibling : dir + "/" + sibling
        }

        /// One pass over the siblings, keeping only non-directory entries named in `names`.
        func siblings(_ names: Set<String>) -> [String: FileTreeNode] {
            guard let parent else { return [:] }
            var found: [String: FileTreeNode] = [:]
            for child in parent.children where child.kind != .directory && names.contains(child.name) {
                found[child.name] = child
            }
            return found
        }
    }

    // MARK: - Build-artifact rules (4.1)

    private func evaluate(_ rule: DirRule, _ site: Site, _ tables: HomeTables) -> RuleMatch? {
        guard site.parent != nil else { return nil }
        switch rule {
        case .nodeModules: return nodeModules(site, tables)
        case .rustTarget: return rustTarget(site, tables)
        case .swiftBuild: return swiftBuild(site, tables)
        case .pythonVenv: return pythonVenv(site, tables)
        case .frameworkCache: return frameworkCache(site, tables)
        case .distBuild: return distBuild(site, tables)
        case .gradleProject: return gradleProject(site, tables)
        case .dartTool: return dartTool(site, tables)
        case .cocoaPods: return cocoaPods(site, tables)
        case .stackWork: return stackWork(site, tables)
        case .elixir: return elixir(site, tables)
        case .terraform: return terraform(site, tables)
        }
    }

    /// Shared construction for every build-artifact rule. Cleanup target ⇒ `descend: false`.
    private func buildArtifact(
        _ site: Site, _ tables: HomeTables,
        id: String, title: String, safety: SafetyLevel, rationale: String,
        evidence: [Evidence], regenerate: String?, warnings: [String] = [], signals: [SupportingSignal] = []
    ) -> RuleMatch {
        var safety = safety
        var warnings = warnings
        // A folder inside application data / editor extensions is an installed payload, not a
        // project dependency: nobody will run `npm ci` there, so never call it "safe".
        if safety == .safeToClear && tables.isInsideInstalledAppData(site.path) {
            safety = .reviewFirst
            warnings.append("Located inside application data — it may be part of an installed app or editor extension, not a project you can rebuild.")
        }
        return RuleMatch(
            ruleID: id, title: title, category: .developerBuilds, safety: safety, group: .buildArtifacts,
            rationale: rationale, evidence: evidence, action: .moveToTrash, regenerateCommand: regenerate,
            warnings: warnings, signals: signals, recommend: true, descend: false
        )
    }

    private static let nodeLockfiles = ["pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "package-lock.json", "npm-shrinkwrap.json"]
    private static let nodeSiblingNames: Set<String> = Set(nodeLockfiles + ["package.json"])

    private func nodeModules(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        let sib = s.siblings(Self.nodeSiblingNames)
        guard sib["package.json"] != nil else { return nil }
        var evidence = [Evidence(kind: .manifest, detail: "Sibling package.json found", path: s.siblingPath("package.json"))]
        let locks = Self.nodeLockfiles.filter { sib[$0] != nil }
        for lock in locks {
            evidence.append(Evidence(kind: .lockfile, detail: "Sibling \(lock) found", path: s.siblingPath(lock)))
        }

        var pnpmMarker = false
        for child in s.node.children where child.name == ".pnpm" || child.name == ".modules.yaml" {
            pnpmMarker = true
            break
        }
        var warnings: [String] = []
        if pnpmMarker {
            warnings.append("pnpm hard-links packages from its global store — deleting this folder frees less than its size.")
        }

        guard let firstLock = locks.first else {
            return buildArtifact(
                s, t, id: "node.node_modules", title: "node_modules (npm dependencies)", safety: .reviewFirst,
                rationale: "node_modules sits next to package.json, but there is no lockfile, so a reinstall may resolve different versions.",
                evidence: evidence, regenerate: pnpmMarker ? "pnpm install" : "npm install",
                warnings: warnings, signals: [.missingLockfile]
            )
        }
        let command: String
        switch firstLock {
        case "pnpm-lock.yaml": command = "pnpm install --frozen-lockfile"
        case "yarn.lock": command = "yarn install --frozen-lockfile"
        case "bun.lockb", "bun.lock": command = "bun install"
        default: command = "npm ci"
        }
        return buildArtifact(
            s, t, id: "node.node_modules", title: "node_modules (npm dependencies)", safety: .safeToClear,
            rationale: "node_modules sits next to package.json and \(firstLock), so `\(command)` recreates it exactly.",
            evidence: evidence, regenerate: command, warnings: warnings
        )
    }

    private func rustTarget(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        let sib = s.siblings(["Cargo.toml", "Cargo.lock"])
        guard sib["Cargo.toml"] != nil else { return nil }
        var evidence = [Evidence(kind: .manifest, detail: "Sibling Cargo.toml found", path: s.siblingPath("Cargo.toml"))]
        if sib["Cargo.lock"] != nil {
            evidence.append(Evidence(kind: .lockfile, detail: "Sibling Cargo.lock found", path: s.siblingPath("Cargo.lock")))
        }
        if let tag = s.node.child(named: "CACHEDIR.TAG"), tag.kind != .directory {
            evidence.append(Evidence(kind: .configFile, detail: "CACHEDIR.TAG marks this as a regenerable cache", path: s.childPath("CACHEDIR.TAG")))
        }
        return buildArtifact(
            s, t, id: "rust.target", title: "target (Rust build output)", safety: .safeToClear,
            rationale: "target/ sits next to Cargo.toml; cargo rebuilds everything in it.",
            evidence: evidence, regenerate: "cargo build"
        )
    }

    private func swiftBuild(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        guard s.siblings(["Package.swift"])["Package.swift"] != nil else { return nil }
        return buildArtifact(
            s, t, id: "swift.build", title: ".build (Swift build output)", safety: .safeToClear,
            rationale: ".build sits next to Package.swift; SwiftPM rebuilds everything in it.",
            evidence: [Evidence(kind: .manifest, detail: "Sibling Package.swift found", path: s.siblingPath("Package.swift"))],
            regenerate: "swift build"
        )
    }

    private static let pythonManifests = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"]
    private static let pythonPins = ["uv.lock", "poetry.lock", "pdm.lock", "Pipfile.lock", "requirements.txt"]
    private static let pythonSiblingNames: Set<String> = Set(pythonManifests + pythonPins)

    private func pythonVenv(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        guard let cfg = s.node.child(named: "pyvenv.cfg"), cfg.kind != .directory else { return nil }
        let sib = s.siblings(Self.pythonSiblingNames)
        let manifests = Self.pythonManifests.filter { sib[$0] != nil }
        guard !manifests.isEmpty else { return nil }

        var evidence = [Evidence(kind: .configFile, detail: "pyvenv.cfg marks a Python virtual environment", path: s.childPath("pyvenv.cfg"))]
        for manifest in manifests {
            evidence.append(Evidence(kind: .manifest, detail: "Sibling \(manifest) found", path: s.siblingPath(manifest)))
        }
        let pins = Self.pythonPins.filter { sib[$0] != nil }
        for pin in pins where pin != "requirements.txt" {
            evidence.append(Evidence(kind: .lockfile, detail: "Sibling \(pin) found", path: s.siblingPath(pin)))
        }

        let title = "\(s.name) (Python virtual environment)"
        guard let pin = pins.first else {
            let command: String
            if manifests.contains("Pipfile") { command = "pipenv install" }
            else if manifests.contains("setup.py") { command = "pip install -e ." }
            else { command = "pip install ." }
            return buildArtifact(
                s, t, id: "python.venv", title: title, safety: .reviewFirst,
                rationale: "The environment has a manifest but no pinned dependency file, so recreating it may install different versions.",
                evidence: evidence, regenerate: command, signals: [.missingLockfile]
            )
        }
        let command: String
        switch pin {
        case "uv.lock": command = "uv sync"
        case "poetry.lock": command = "poetry install"
        case "pdm.lock": command = "pdm sync"
        case "Pipfile.lock": command = "pipenv sync"
        default: command = "pip install -r requirements.txt"
        }
        return buildArtifact(
            s, t, id: "python.venv", title: title, safety: .safeToClear,
            rationale: "A pinned dependency spec (\(pin)) sits next to the environment, so `\(command)` recreates it.",
            evidence: evidence, regenerate: command
        )
    }

    private func frameworkCache(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        guard s.siblings(["package.json"])["package.json"] != nil else { return nil }
        return buildArtifact(
            s, t, id: "js.framework_cache", title: "\(s.name) (JavaScript build cache)", safety: .safeToClear,
            rationale: "\(s.name) is a framework build cache next to package.json; the next build recreates it.",
            evidence: [Evidence(kind: .manifest, detail: "Sibling package.json found", path: s.siblingPath("package.json"))],
            regenerate: "npm run build"
        )
    }

    private static let distManifests: [(file: String, command: String)] = [
        ("package.json", "npm run build"),
        ("pyproject.toml", "python -m build"),
        ("setup.py", "python setup.py build"),
        ("CMakeLists.txt", "cmake --build build"),
        ("build.gradle", "./gradlew build"),
        ("build.gradle.kts", "./gradlew build"),
        ("Makefile", "make"),
        ("meson.build", "meson compile -C build"),
    ]
    private static let distManifestNames: Set<String> = Set(distManifests.map(\.file))

    private func distBuild(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        let sib = s.siblings(Self.distManifestNames)
        let found = Self.distManifests.filter { sib[$0.file] != nil }
        guard let first = found.first else { return nil }
        return buildArtifact(
            s, t, id: "generic.dist_build", title: "\(s.name) (build output)", safety: .reviewFirst,
            rationale: "\(s.name)/ sits next to \(first.file) and is probably build output, but it may also hold hand-placed assets.",
            evidence: found.map { Evidence(kind: .manifest, detail: "Sibling \($0.file) found", path: s.siblingPath($0.file)) },
            regenerate: first.command,
            warnings: ["May contain files that are not produced by the build (hand-placed assets, release artifacts)."]
        )
    }

    private static let gradleManifests = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    private func gradleProject(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        // `~/.gradle` itself is Gradle's user home, never a project cache.
        guard s.path != t.gradleUserHome else { return nil }
        let sib = s.siblings(Set(Self.gradleManifests))
        let found = Self.gradleManifests.filter { sib[$0] != nil }
        guard let first = found.first else { return nil }
        return buildArtifact(
            s, t, id: "gradle.project_cache", title: ".gradle (Gradle project cache)", safety: .safeToClear,
            rationale: "The project's .gradle cache sits next to \(first); Gradle recreates it.",
            evidence: [Evidence(kind: .manifest, detail: "Sibling \(first) found", path: s.siblingPath(first))],
            regenerate: "./gradlew build"
        )
    }

    private func dartTool(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        guard s.siblings(["pubspec.yaml"])["pubspec.yaml"] != nil else { return nil }
        return buildArtifact(
            s, t, id: "dart.tool", title: ".dart_tool (Dart tool cache)", safety: .safeToClear,
            rationale: ".dart_tool sits next to pubspec.yaml; `dart pub get` recreates it.",
            evidence: [Evidence(kind: .manifest, detail: "Sibling pubspec.yaml found", path: s.siblingPath("pubspec.yaml"))],
            regenerate: "dart pub get"
        )
    }

    private func cocoaPods(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        let sib = s.siblings(["Podfile", "Podfile.lock"])
        guard sib["Podfile"] != nil, sib["Podfile.lock"] != nil else { return nil }
        return buildArtifact(
            s, t, id: "cocoapods.pods", title: "Pods (CocoaPods dependencies)", safety: .safeToClear,
            rationale: "Pods/ sits next to Podfile and Podfile.lock; `pod install` recreates it exactly.",
            evidence: [
                Evidence(kind: .manifest, detail: "Sibling Podfile found", path: s.siblingPath("Podfile")),
                Evidence(kind: .lockfile, detail: "Sibling Podfile.lock found", path: s.siblingPath("Podfile.lock")),
            ],
            regenerate: "pod install"
        )
    }

    private func stackWork(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        guard s.siblings(["stack.yaml"])["stack.yaml"] != nil else { return nil }
        return buildArtifact(
            s, t, id: "haskell.stack_work", title: ".stack-work (Haskell build output)", safety: .safeToClear,
            rationale: ".stack-work sits next to stack.yaml; `stack build` recreates it.",
            evidence: [Evidence(kind: .manifest, detail: "Sibling stack.yaml found", path: s.siblingPath("stack.yaml"))],
            regenerate: "stack build"
        )
    }

    private func elixir(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        guard s.siblings(["mix.exs"])["mix.exs"] != nil else { return nil }
        let isDeps = s.name == "deps"
        return buildArtifact(
            s, t, id: "elixir.build", title: isDeps ? "deps (Elixir dependencies)" : "_build (Elixir build output)", safety: .safeToClear,
            rationale: "\(s.name)/ sits next to mix.exs; mix recreates it.",
            evidence: [Evidence(kind: .manifest, detail: "Sibling mix.exs found", path: s.siblingPath("mix.exs"))],
            regenerate: "mix deps.get && mix compile"
        )
    }

    private func terraform(_ s: Site, _ t: HomeTables) -> RuleMatch? {
        guard let parent = s.parent else { return nil }
        var firstTF: String?
        for child in parent.children where child.kind != .directory && child.name.hasSuffix(".tf") {
            if firstTF == nil || child.name < firstTF! { firstTF = child.name }
        }
        guard let tf = firstTF else { return nil }
        return buildArtifact(
            s, t, id: "terraform.providers", title: ".terraform (Terraform providers)", safety: .reviewFirst,
            rationale: ".terraform holds downloaded providers and modules next to \(tf); `terraform init` restores them.",
            evidence: [Evidence(kind: .manifest, detail: "Sibling \(tf) found", path: s.siblingPath(tf))],
            regenerate: "terraform init",
            warnings: ["Re-initializing needs network access and may select different provider versions than the ones installed."]
        )
    }

    // MARK: - Extension rules (apps, media libraries, VM bundles)

    private func evaluate(_ rule: ExtRule, _ site: Site) -> RuleMatch? {
        let path = site.path
        switch rule {
        case .app:
            return RuleMatch(
                ruleID: "apps.bundle", title: site.name, category: .applications, safety: .doNotDelete, group: .appData,
                rationale: "Application bundle. Remove apps with the system or the app's uninstaller, not KlaD.",
                evidence: [Evidence(kind: .knownLocation, detail: "Application bundle (.app)", path: path)],
                action: .inspectOnly, recommend: false, descend: false
            )
        case .mediaLibrary:
            return RuleMatch(
                ruleID: "user.media_library", title: site.name, category: .media, safety: .doNotDelete, group: .appData,
                rationale: "A media library package holding your personal photos, music or projects.",
                evidence: [Evidence(kind: .knownLocation, detail: "Media library package", path: path)],
                action: .inspectOnly, recommend: false, descend: true
            )
        case .utm:
            return vmBundle(site, id: "utm.vm", app: "UTM", bundleID: "com.utmapp.UTM", kind: "UTM")
        case .parallels:
            return vmBundle(site, id: "parallels.vm", app: "Parallels Desktop", bundleID: "com.parallels.desktop.console", kind: "Parallels")
        case .vmware:
            return vmBundle(site, id: "vmware.vm", app: "VMware Fusion", bundleID: "com.vmware.fusion", kind: "VMware")
        }
    }

    private func vmBundle(_ site: Site, id: String, app: String, bundleID: String, kind: String) -> RuleMatch {
        RuleMatch(
            ruleID: id, title: site.name, category: .containersVMs, safety: .guidedExternalAction, group: .containersAndVMs,
            rationale: "A \(kind) virtual machine disk. Delete VMs from inside \(app) so nothing is left half-removed.",
            evidence: [Evidence(kind: .knownLocation, detail: "\(kind) virtual machine bundle", path: site.path)],
            action: .guided(HomeTables.vmRemediation(app: app, bundleID: bundleID, kind: kind)),
            recommend: true, descend: false
        )
    }

    // MARK: - Known locations

    private func resolve(_ entry: KnownEntry, _ context: ClassificationContext) -> RuleMatch {
        guard entry.kind == .derivedData else { return entry.match }
        var match = entry.match
        if context.runningApplicationBundleIDs.contains("com.apple.dt.Xcode") {
            match.signals.append(.applicationRunning(name: "Xcode"))
            match.warnings.append("Quit Xcode first — it may be mid-build.")
        }
        return match
    }

    // MARK: - Direct-child rules

    private static let appCacheThreshold: UInt64 = 256 << 20

    private func matchByParent(_ site: Site, parent: FileTreeNode, tables: HomeTables) -> RuleMatch? {
        let grandparent = parent.parent
        let parentName = grandparent == nil ? NameKeys.lastComponent(of: parent.name) : parent.name
        let node = site.node

        if Self.parentGateNames.contains(parentName) {
            let parentDir = site.parentDir
            switch parentName {
            case "Application Support", "Containers":
                if parentDir == tables.appSupportDir || parentDir == tables.containersDir {
                    return RuleMatch(
                        ruleID: "appdata.support", title: site.name, category: .applications, safety: .unknown, group: .appData,
                        rationale: "Application-owned data. There is no evidence it can be regenerated — inspect only.",
                        evidence: [Evidence(kind: .knownLocation, detail: "Application data folder", path: site.path)],
                        action: .inspectOnly, recommend: false, descend: true
                    )
                }
            case "Caches":
                if parentDir == tables.cachesDir && node.metrics.allocatedBytes >= Self.appCacheThreshold {
                    return RuleMatch(
                        ruleID: "caches.app_cache", title: "\(site.name) cache", category: .caches, safety: .reviewFirst, group: .packageCaches,
                        rationale: "A large application cache. Caches regenerate, but the app may be running and lose state.",
                        evidence: [Evidence(kind: .knownLocation, detail: "Application cache in ~/Library/Caches", path: site.path)],
                        action: .moveToTrash, warnings: ["App caches regenerate, but the app may be running and lose state."],
                        recommend: true, descend: false
                    )
                }
            case "hub":
                if parentDir == tables.hfHubDir, let match = huggingFace(site) { return match }
            default:
                break
            }
        }

        // LM Studio: <models>/<publisher>/<model>
        if let grandparent, grandparent.name == "models" {
            let publisherDir = site.parentDir
            let modelsDir = NameKeys.parentPath(of: publisherDir, name: parent.name)
            if tables.lmStudioDirs.contains(modelsDir) {
                let id = "\(parent.name)/\(site.name)"
                return RuleMatch(
                    ruleID: "ai.lmstudio", title: id, category: .aiModels, safety: .reviewFirst, group: .aiModels,
                    rationale: "A downloaded LM Studio model (\(id)).",
                    evidence: [Evidence(kind: .knownLocation, detail: "LM Studio model folder", path: site.path)],
                    action: .moveToTrash, regenerateCommand: "Re-download from LM Studio's model browser",
                    warnings: ["Deleting requires re-downloading multi-GB model weights."],
                    recommend: true, descend: false
                )
            }
        }
        return nil
    }

    private func huggingFace(_ site: Site) -> RuleMatch? {
        let name = site.name
        let isModel = name.hasPrefix("models--")
        let isDataset = name.hasPrefix("datasets--")
        guard isModel || isDataset else { return nil }
        let encoded = name.dropFirst(isModel ? "models--".count : "datasets--".count)
        let decoded = encoded.replacingOccurrences(of: "--", with: "/")
        guard !decoded.isEmpty else { return nil }
        return RuleMatch(
            ruleID: "ai.huggingface", title: decoded, category: .aiModels, safety: .reviewFirst, group: .aiModels,
            rationale: "A Hugging Face \(isModel ? "model" : "dataset") (\(decoded)) cached by the hub library.",
            evidence: [Evidence(kind: .knownLocation, detail: "Hugging Face hub cache entry", path: site.path)],
            action: .moveToTrash,
            regenerateCommand: isModel ? "hf download \(decoded)" : "hf download \(decoded) --repo-type dataset",
            warnings: ["Deleting requires re-downloading multi-GB model weights."],
            recommend: true, descend: false
        )
    }

    // MARK: - Files

    private static let dockerFileNames: Set<String> = ["Docker.raw", "Docker.qcow2"]
    private static let installerKeys: Set<UInt64> = Set(["dmg", "pkg", "mpkg", "iso", "xip", "zip"].map(NameKeys.key))
    private static let zipKey = NameKeys.key("zip")
    private static let zipThreshold: UInt64 = 100 << 20

    private func matchFile(_ node: FileTreeNode, path: String, context: ClassificationContext) -> RuleMatch? {
        let name = node.name
        if Self.dockerFileNames.contains(name) {
            return RuleMatch(
                ruleID: "docker.raw", title: name, category: .containersVMs, safety: .guidedExternalAction, group: .containersAndVMs,
                rationale: "Docker's VM disk. It holds every image, container and volume, so it must be reclaimed through Docker.",
                evidence: [Evidence(kind: .knownLocation, detail: "Docker Desktop VM disk image (\(name))", path: path)],
                action: .guided(HomeTables.dockerRemediation),
                recommend: true, descend: false
            )
        }

        let key = NameKeys.extensionKey(name)
        guard key != 0, Self.installerKeys.contains(key) else { return nil }
        if key == Self.zipKey && node.metrics.allocatedBytes < Self.zipThreshold { return nil }

        let tables = cache.tables(for: context.homeDirectory)
        guard path.utf8.starts(with: tables.downloadsPrefix.utf8) else { return nil }
        // Depth 1 or 2: directly in ~/Downloads or one folder below it.
        var slashes = 0
        for byte in path.utf8.dropFirst(tables.downloadsPrefixByteCount) where byte == 0x2F { slashes += 1 }
        guard slashes <= 1 else { return nil }

        let ageSeconds = context.now.timeIntervalSince1970 - Double(node.modificationTime)
        let days = Int((ageSeconds / 86_400).rounded(.down))
        guard days > context.staleInstallerDays else { return nil }
        return RuleMatch(
            ruleID: "installers.stale", title: name, category: .documents, safety: .reviewFirst, group: .installersAndArchives,
            rationale: "An installer or archive in Downloads that hasn't changed in \(days) days. If the app is installed, the installer is usually no longer needed.",
            evidence: [Evidence(kind: .knownLocation, detail: "Installer in Downloads, unchanged for \(days) days", path: path)],
            action: .moveToTrash,
            warnings: ["Make sure you don't still need this installer or archive."],
            recommend: true, descend: false
        )
    }
}
