// ClassificationTests.swift
import Testing
import Foundation
@testable import KlaDIntelligence
import KlaDModels

// MARK: - Fixture helpers

private let home = "/Users/tester"
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: Int64 = 86_400
private let MiB: UInt64 = 1 << 20

private func ctx(
    running: Set<String> = [],
    minimum: UInt64 = 1 << 20,
    inactivity: Int = 30,
    stale: Int = 30
) -> ClassificationContext {
    ClassificationContext(
        homeDirectory: home, now: now, runningApplicationBundleIDs: running,
        inactivityThresholdDays: inactivity, staleInstallerDays: stale, minimumRecommendationBytes: minimum
    )
}

/// File of `mib` MiB, modified `daysAgo` days before `now`.
private func f(_ name: String, mib: UInt64 = 2, daysAgo: Int64 = 100, flags: NodeFlags = []) -> FileTreeNode {
    .file(name, logical: mib * MiB, flags: flags, modificationTime: Int64(now.timeIntervalSince1970) - daysAgo * day)
}

private func d(_ name: String, daysAgo: Int64 = 100, _ children: FileTreeNode...) -> FileTreeNode {
    .directory(name, modificationTime: Int64(now.timeIntervalSince1970) - daysAgo * day, children: children)
}

private func d(_ name: String, _ children: [FileTreeNode]) -> FileTreeNode {
    .directory(name, modificationTime: Int64(now.timeIntervalSince1970) - 100 * day, children: children)
}

private func tree(_ children: FileTreeNode..., root: String = home) -> FileTreeNode {
    let node = FileTreeNode.directory(root, children: children)
    node.recomputeAggregates()
    return node
}

private struct Run {
    let root: FileTreeNode
    let result: ClassificationResult
    func rec(_ path: String) -> CleanupRecommendation? { result.recommendations.first { $0.path == path } }
    func node(_ path: String) -> FileTreeNode? { root.descendant(atPath: path) }
}

private func run(_ root: FileTreeNode, _ context: ClassificationContext = ctx()) -> Run {
    Run(root: root, result: ClassificationEngine().classify(root: root, context: context))
}

/// A project directory with the given extra children plus a big node_modules-like payload.
private func project(_ name: String, _ children: FileTreeNode...) -> FileTreeNode {
    .directory(name, modificationTime: Int64(now.timeIntervalSince1970) - 100 * day, children: children)
}

private func project(_ name: String, _ children: [FileTreeNode]) -> FileTreeNode {
    .directory(name, modificationTime: Int64(now.timeIntervalSince1970) - 100 * day, children: children)
}

private func hasSignal(_ r: CleanupRecommendation, _ s: SupportingSignal) -> Bool { r.signals.contains(s) }

// MARK: - Build artifacts

@Suite("Build artifacts")
struct BuildArtifactTests {
    private func nodeProject(_ extra: [FileTreeNode]) -> Run {
        let app = project("app", [f("package.json", mib: 1), d("node_modules", [f("a.js", mib: 3)])] + extra)
        return run(tree(d("Projects", [app])))
    }

    @Test(arguments: [
        ("package-lock.json", "npm ci"),
        ("npm-shrinkwrap.json", "npm ci"),
        ("pnpm-lock.yaml", "pnpm install --frozen-lockfile"),
        ("yarn.lock", "yarn install --frozen-lockfile"),
        ("bun.lockb", "bun install"),
        ("bun.lock", "bun install"),
    ])
    func nodeModulesWithLockfileIsSafe(lockfile: String, command: String) throws {
        let r = nodeProject([f(lockfile, mib: 1)])
        let rec = try #require(r.rec("\(home)/Projects/app/node_modules"))
        #expect(rec.safety == .safeToClear)
        #expect(rec.ruleID == "node.node_modules")
        #expect(rec.regenerateCommand == command)
        #expect(rec.group == .buildArtifacts)
        #expect(rec.category == .developerBuilds)
        #expect(rec.action.isTrashable)
        #expect(rec.evidence.contains { $0.kind == .manifest && $0.path == "\(home)/Projects/app/package.json" })
        #expect(rec.evidence.contains { $0.kind == .lockfile && $0.path == "\(home)/Projects/app/\(lockfile)" })
        #expect(!hasSignal(rec, .missingLockfile))
    }

    @Test func nodeModulesWithoutLockfileIsReviewFirst() throws {
        let r = nodeProject([])
        let rec = try #require(r.rec("\(home)/Projects/app/node_modules"))
        #expect(rec.safety == .reviewFirst)
        #expect(hasSignal(rec, .missingLockfile))
        #expect(rec.regenerateCommand == "npm install")
        #expect(rec.isTrashable)
    }

    @Test func nodeModulesWithoutPackageJsonIsNotRecommended() {
        let app = project("app", d("node_modules", [f("a.js", mib: 3)]), f("package-lock.json"))
        let r = run(tree(d("Projects", [app])))
        #expect(r.result.recommendations.isEmpty)
        #expect(r.node("\(home)/Projects/app/node_modules")?.annotation == nil)
    }

    @Test func pnpmNodeModulesWarnsAboutHardLinks() throws {
        let app = project("app", f("package.json", mib: 1), f("pnpm-lock.yaml", mib: 1),
                          d("node_modules", [d(".pnpm", [f("x", mib: 3)])]))
        let r = run(tree(d("Projects", [app])))
        let rec = try #require(r.rec("\(home)/Projects/app/node_modules"))
        #expect(rec.warnings.contains { $0.contains("hard-links packages from its global store") })
    }

    @Test func nestedNodeModulesOnlyOuterRecommended() throws {
        let inner = project("dep", f("package.json", mib: 1), f("package-lock.json", mib: 1),
                            d("node_modules", [f("deep.js", mib: 5)]))
        let outer = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1),
                            d("node_modules", [inner]))
        let r = run(tree(d("Projects", [outer])))
        #expect(r.result.recommendations.count == 1)
        #expect(r.result.recommendations.first?.path == "\(home)/Projects/app/node_modules")
        #expect(r.node("\(home)/Projects/app/node_modules/dep/node_modules")?.annotation == nil)
        // Everything inside still inherits the category.
        #expect(r.node("\(home)/Projects/app/node_modules/dep/node_modules/deep.js")?.category == .developerBuilds)
    }

    @Test func rustTarget() throws {
        let with = project("crate", f("Cargo.toml", mib: 1), f("Cargo.lock", mib: 1), d("target", [f("CACHEDIR.TAG", mib: 1), f("debug.bin", mib: 4)]))
        let without = project("other", d("target", [f("x.bin", mib: 4)]))
        let r = run(tree(d("Projects", [with, without])))
        let rec = try #require(r.rec("\(home)/Projects/crate/target"))
        #expect(rec.safety == .safeToClear)
        #expect(rec.regenerateCommand == "cargo build")
        #expect(rec.evidence.contains { $0.kind == .lockfile })
        #expect(rec.evidence.contains { $0.kind == .configFile && $0.path?.hasSuffix("CACHEDIR.TAG") == true })
        #expect(r.rec("\(home)/Projects/other/target") == nil)
    }

    @Test func swiftBuild() throws {
        let with = project("pkg", f("Package.swift", mib: 1), d(".build", [f("x", mib: 5)]))
        let without = project("junk", d(".build", [f("x", mib: 5)]))
        let r = run(tree(d("Projects", [with, without])))
        let rec = try #require(r.rec("\(home)/Projects/pkg/.build"))
        #expect(rec.safety == .safeToClear)
        #expect(rec.regenerateCommand == "swift build")
        #expect(r.rec("\(home)/Projects/junk/.build") == nil)
    }

    @Test func pythonVenv() throws {
        let locked = project("a", f("pyproject.toml", mib: 1), f("uv.lock", mib: 1), d(".venv", [f("pyvenv.cfg", mib: 1), f("lib.so", mib: 4)]))
        let reqs = project("b", f("requirements.txt", mib: 1), d("venv", [f("pyvenv.cfg", mib: 1), f("lib.so", mib: 4)]))
        let poetry = project("c", f("pyproject.toml", mib: 1), f("poetry.lock", mib: 1), d(".venv", [f("pyvenv.cfg", mib: 1), f("lib.so", mib: 4)]))
        let unpinned = project("d", f("pyproject.toml", mib: 1), d(".venv", [f("pyvenv.cfg", mib: 1), f("lib.so", mib: 4)]))
        let noCfg = project("e", f("requirements.txt", mib: 1), d(".venv", [f("lib.so", mib: 4)]))
        let noManifest = project("f", d(".venv", [f("pyvenv.cfg", mib: 1), f("lib.so", mib: 4)]))
        let r = run(tree(d("Projects", [locked, reqs, poetry, unpinned, noCfg, noManifest])))

        let a = try #require(r.rec("\(home)/Projects/a/.venv"))
        #expect(a.safety == .safeToClear); #expect(a.regenerateCommand == "uv sync")
        #expect(a.evidence.contains { $0.kind == .configFile })
        let b = try #require(r.rec("\(home)/Projects/b/venv"))
        #expect(b.safety == .safeToClear); #expect(b.regenerateCommand == "pip install -r requirements.txt")
        let c = try #require(r.rec("\(home)/Projects/c/.venv"))
        #expect(c.regenerateCommand == "poetry install")
        let dd = try #require(r.rec("\(home)/Projects/d/.venv"))
        #expect(dd.safety == .reviewFirst); #expect(hasSignal(dd, .missingLockfile))
        #expect(r.rec("\(home)/Projects/e/.venv") == nil)
        #expect(r.rec("\(home)/Projects/f/.venv") == nil)
    }

    @Test func distNeedsManifestAndIsReviewFirst() throws {
        let with = project("web", f("package.json", mib: 1), d("dist", [f("bundle.js", mib: 4)]), d("build", [f("x", mib: 4)]))
        let without = project("loose", d("dist", [f("bundle.js", mib: 4)]))
        let r = run(tree(d("Projects", [with, without])))
        let dist = try #require(r.rec("\(home)/Projects/web/dist"))
        #expect(dist.safety == .reviewFirst)
        #expect(dist.ruleID == "generic.dist_build")
        #expect(dist.regenerateCommand == "npm run build")
        #expect(r.rec("\(home)/Projects/web/build") != nil)
        #expect(r.rec("\(home)/Projects/loose/dist") == nil)
    }

    @Test func otherEcosystems() throws {
        let next = project("n", f("package.json", mib: 1), d(".next", [f("x", mib: 4)]))
        let gradle = project("g", f("build.gradle.kts", mib: 1), d(".gradle", [f("x", mib: 4)]))
        let dart = project("dt", f("pubspec.yaml", mib: 1), d(".dart_tool", [f("x", mib: 4)]))
        let pods = project("p", f("Podfile", mib: 1), f("Podfile.lock", mib: 1), d("Pods", [f("x", mib: 4)]))
        let podsNoLock = project("p2", f("Podfile", mib: 1), d("Pods", [f("x", mib: 4)]))
        let stack = project("s", f("stack.yaml", mib: 1), d(".stack-work", [f("x", mib: 4)]))
        let mix = project("m", f("mix.exs", mib: 1), d("_build", [f("x", mib: 4)]), d("deps", [f("y", mib: 4)]))
        let tf = project("t", f("main.tf", mib: 1), d(".terraform", [f("x", mib: 4)]))
        let r = run(tree(d("Projects", [next, gradle, dart, pods, podsNoLock, stack, mix, tf])))
        #expect(r.rec("\(home)/Projects/n/.next")?.safety == .safeToClear)
        #expect(r.rec("\(home)/Projects/g/.gradle")?.regenerateCommand == "./gradlew build")
        #expect(r.rec("\(home)/Projects/dt/.dart_tool")?.regenerateCommand == "dart pub get")
        #expect(r.rec("\(home)/Projects/p/Pods")?.regenerateCommand == "pod install")
        #expect(r.rec("\(home)/Projects/p2/Pods") == nil)
        #expect(r.rec("\(home)/Projects/s/.stack-work")?.regenerateCommand == "stack build")
        #expect(r.rec("\(home)/Projects/m/_build")?.regenerateCommand == "mix deps.get && mix compile")
        #expect(r.rec("\(home)/Projects/m/deps") != nil)
        #expect(r.rec("\(home)/Projects/t/.terraform")?.safety == .reviewFirst)
    }

    @Test func userGradleHomeIsNotAProjectCache() {
        let r = run(tree(d(".gradle", [f("build.gradle", mib: 1), f("x", mib: 4)]), f("build.gradle", mib: 1)))
        #expect(r.rec("\(home)/.gradle") == nil)
    }

    @Test func buildArtifactInsideAppDataIsDowngraded() throws {
        let ext = project("ext", f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [f("a.js", mib: 3)]))
        let r = run(tree(d("Library", [d("Application Support", [d("Code", [ext])])])))
        let rec = try #require(r.rec("\(home)/Library/Application Support/Code/ext/node_modules"))
        #expect(rec.safety == .reviewFirst)
    }
}

// MARK: - Xcode, caches, AI, containers

@Suite("Known locations")
struct KnownLocationTests {
    private func xcodeTree() -> FileTreeNode {
        tree(d("Library", [d("Developer", [
            d("Xcode", [
                d("DerivedData", [f("idx", mib: 10)]),
                d("Archives", [f("a.xcarchive", mib: 10)]),
                d("iOS DeviceSupport", [f("sym", mib: 10)]),
                d("UserData", [d("Previews", [f("p", mib: 10)])]),
            ]),
            d("CoreSimulator", [d("Devices", [f("dev", mib: 10)]), d("Caches", [f("c", mib: 10)])]),
        ])]))
    }

    @Test func xcodeRules() throws {
        let r = run(xcodeTree())
        let derived = try #require(r.rec("\(home)/Library/Developer/Xcode/DerivedData"))
        #expect(derived.safety == .safeToClear)
        #expect(derived.group == .xcode); #expect(derived.category == .xcode)
        #expect(derived.evidence.first?.kind == .knownLocation)
        #expect(!derived.signals.contains { if case .applicationRunning = $0 { return true } else { return false } })

        #expect(r.rec("\(home)/Library/Developer/Xcode/Archives")?.safety == .reviewFirst)
        #expect(r.rec("\(home)/Library/Developer/Xcode/iOS DeviceSupport")?.safety == .reviewFirst)
        #expect(r.rec("\(home)/Library/Developer/CoreSimulator/Caches")?.safety == .safeToClear)
        #expect(r.rec("\(home)/Library/Developer/Xcode/UserData/Previews")?.safety == .safeToClear)
    }

    @Test func derivedDataWhileXcodeRuns() throws {
        let r = run(xcodeTree(), ctx(running: ["com.apple.dt.Xcode"]))
        let derived = try #require(r.rec("\(home)/Library/Developer/Xcode/DerivedData"))
        #expect(hasSignal(derived, .applicationRunning(name: "Xcode")))
        #expect(derived.warnings.contains("Quit Xcode first — it may be mid-build."))
        #expect(derived.safety == .safeToClear)
    }

    @Test func simulatorsAreGuided() throws {
        let r = run(xcodeTree())
        let sims = try #require(r.rec("\(home)/Library/Developer/CoreSimulator/Devices"))
        #expect(sims.safety == .guidedExternalAction)
        #expect(!sims.isTrashable)
        let commands = try #require(sims.action.guidedRemediation).commands.map(\.command)
        #expect(commands == ["xcrun simctl list devices", "xcrun simctl delete unavailable", "xcrun simctl erase all"])
    }

    @Test func packageCaches() throws {
        let r = run(tree(
            d("Library", [d("Caches", [d("Homebrew", [f("b", mib: 5)]), d("pip", [f("w", mib: 5)])])]),
            d(".npm", [d("_cacache", [f("c", mib: 5)])]),
            d(".cargo", [d("registry", [f("r", mib: 5)]), d("git", [f("g", mib: 5)])]),
            d("go", [d("pkg", [d("mod", [f("m", mib: 5)])])]),
            d(".pnpm-store", [f("s", mib: 5)]),
            d(".m2", [d("repository", [f("j", mib: 5)])])
        ))
        let brew = try #require(r.rec("\(home)/Library/Caches/Homebrew"))
        #expect(brew.safety == .safeToClear); #expect(brew.group == .packageCaches); #expect(brew.category == .caches)
        #expect(brew.regenerateCommand == "brew cleanup --prune=all")
        #expect(r.rec("\(home)/.npm/_cacache")?.safety == .safeToClear)
        #expect(r.rec("\(home)/.cargo/registry")?.safety == .safeToClear)
        #expect(r.rec("\(home)/.cargo/git")?.safety == .safeToClear)
        #expect(r.rec("\(home)/Library/Caches/pip")?.safety == .safeToClear)
        let go = try #require(r.rec("\(home)/go/pkg/mod"))
        #expect(go.safety == .guidedExternalAction); #expect(go.action.guidedRemediation?.commands.map(\.command).contains("go clean -modcache") == true)
        let pnpm = try #require(r.rec("\(home)/.pnpm-store"))
        #expect(pnpm.safety == .guidedExternalAction); #expect(!pnpm.isTrashable)
        #expect(pnpm.action.guidedRemediation?.commands.map(\.command) == ["pnpm store path", "pnpm store prune"])
        #expect(r.rec("\(home)/.m2/repository")?.safety == .reviewFirst)
    }

    @Test func largeAppCachesAreReviewFirst() throws {
        let r = run(tree(d("Library", [d("Caches", [
            d("com.big.cache", [f("blob", mib: 300)]),
            d("com.small.cache", [f("blob", mib: 10)]),
        ])])))
        let big = try #require(r.rec("\(home)/Library/Caches/com.big.cache"))
        #expect(big.safety == .reviewFirst); #expect(big.ruleID == "caches.app_cache")
        #expect(r.rec("\(home)/Library/Caches/com.small.cache") == nil)
        #expect(r.node("\(home)/Library/Caches/com.small.cache/blob")?.category == .caches)
    }

    @Test func ollamaAndHuggingFace() throws {
        let r = run(tree(
            d(".ollama", [d("models", [f("blob", mib: 50)]), f("id_ed25519", mib: 1)]),
            d(".cache", [d("huggingface", [d("hub", [
                d("models--meta-llama--Llama-3-8B", [f("w.safetensors", mib: 40)]),
                d("datasets--squad", [f("d", mib: 10)]),
                d("version.txt-dir", [f("x", mib: 10)]),
            ])])])
        ))
        let ollama = try #require(r.rec("\(home)/.ollama/models"))
        #expect(ollama.safety == .reviewFirst); #expect(ollama.group == .aiModels); #expect(ollama.category == .aiModels)
        #expect(ollama.action.isTrashable)
        #expect(ollama.warnings.contains("Deleting requires re-downloading multi-GB model weights."))
        #expect(ollama.warnings.contains("Prefer `ollama rm <model>` to remove individual models."))

        let hf = try #require(r.rec("\(home)/.cache/huggingface/hub/models--meta-llama--Llama-3-8B"))
        #expect(hf.title == "meta-llama/Llama-3-8B"); #expect(hf.safety == .reviewFirst)
        #expect(r.rec("\(home)/.cache/huggingface/hub/datasets--squad")?.title == "squad")
        #expect(r.rec("\(home)/.cache/huggingface/hub") == nil)
        #expect(r.rec("\(home)/.cache/huggingface/hub/version.txt-dir") == nil)
        #expect(r.node("\(home)/.cache/huggingface/hub")?.category == .aiModels)
    }

    @Test func lmStudioModelsAreRecommendedPerModel() throws {
        let r = run(tree(d(".lmstudio", [d("models", [
            d("TheBloke", [d("llama-7b-GGUF", [f("m.gguf", mib: 30)]), d("mistral-GGUF", [f("m.gguf", mib: 20)])]),
        ])])))
        let a = try #require(r.rec("\(home)/.lmstudio/models/TheBloke/llama-7b-GGUF"))
        #expect(a.title == "TheBloke/llama-7b-GGUF"); #expect(a.safety == .reviewFirst)
        #expect(r.rec("\(home)/.lmstudio/models/TheBloke/mistral-GGUF") != nil)
        #expect(r.rec("\(home)/.lmstudio/models/TheBloke") == nil)
    }

    @Test func dockerRawIsGuidedNeverTrashable() throws {
        let raw = d("Library", [d("Containers", [d("com.docker.docker", [d("Data", [d("vms", [d("0", [d("data", [f("Docker.raw", mib: 500)])])])])])])])
        let r = run(tree(raw))
        let path = "\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        let rec = try #require(r.rec(path))
        #expect(rec.safety == .guidedExternalAction)
        #expect(rec.group == .containersAndVMs); #expect(rec.category == .containersVMs)
        #expect(rec.guided != nil)
        #expect(!rec.action.isTrashable); #expect(!rec.isTrashable)
        let guided = try #require(rec.action.guidedRemediation)
        #expect(guided.applicationBundleID == "com.docker.docker")
        #expect(guided.commands.map(\.command) == ["docker system df", "docker builder prune", "docker image prune -a", "docker system prune -a --volumes"])
        #expect(guided.commands.map(\.isDestructive) == [false, true, true, true])
        #expect(guided.commands.last?.label.contains("named volumes") == true)
        #expect(guided.explanation.contains("Trashing it destroys them all"))
    }

    @Test func otherContainerRules() throws {
        let r = run(tree(
            d(".orbstack", [f("data.img", mib: 20)]),
            d(".colima", [f("disk", mib: 20)]),
            d(".local", [d("share", [d("containers", [d("podman", [d("machine", [f("disk", mib: 20)])])])])]),
            d(".android", [d("avd", [f("sdcard.img", mib: 20)])]),
            d("VMs", [d("win.utm", [f("disk.qcow2", mib: 20)]), d("mac.pvm", [f("d", mib: 20)]), d("l.vmwarevm", [f("d", mib: 20)])])
        ))
        for path in ["\(home)/.orbstack", "\(home)/.colima", "\(home)/.local/share/containers/podman/machine", "\(home)/.android/avd",
                     "\(home)/VMs/win.utm", "\(home)/VMs/mac.pvm", "\(home)/VMs/l.vmwarevm"] {
            let rec = try #require(r.rec(path), "missing \(path)")
            #expect(rec.safety == .guidedExternalAction)
            #expect(!rec.isTrashable)
            #expect(rec.action.guidedRemediation != nil)
        }
        #expect(r.rec("\(home)/VMs/win.utm")?.action.guidedRemediation?.applicationBundleID == "com.utmapp.UTM")
        #expect(r.rec("\(home)/.orbstack")?.action.guidedRemediation?.applicationBundleID == "dev.kdrag0n.MacVirt")
    }
}

private extension CleanupRecommendation {
    var guided: GuidedRemediation? { action.guidedRemediation }
}

// MARK: - Installers

@Suite("Installers")
struct InstallerTests {
    @Test func staleInstallersAreReviewFirst() throws {
        let r = run(tree(d("Downloads", [
            f("Old.dmg", mib: 50, daysAgo: 90),
            f("Fresh.dmg", mib: 50, daysAgo: 2),
            f("big.zip", mib: 200, daysAgo: 90),
            f("small.zip", mib: 20, daysAgo: 90),
            f("notes.pdf", mib: 20, daysAgo: 90),
            d("sub", [f("Setup.pkg", mib: 30, daysAgo: 90), d("deeper", [f("Hidden.iso", mib: 30, daysAgo: 90)])]),
        ])))
        let old = try #require(r.rec("\(home)/Downloads/Old.dmg"))
        #expect(old.safety == .reviewFirst); #expect(old.group == .installersAndArchives); #expect(old.category == .documents)
        #expect(old.evidence.first?.kind == .knownLocation)
        #expect(old.evidence.first?.detail == "Installer in Downloads, unchanged for 90 days")
        #expect(r.rec("\(home)/Downloads/Fresh.dmg") == nil)
        #expect(r.rec("\(home)/Downloads/big.zip") != nil)
        #expect(r.rec("\(home)/Downloads/small.zip") == nil)
        #expect(r.rec("\(home)/Downloads/notes.pdf") == nil)
        #expect(r.rec("\(home)/Downloads/sub/Setup.pkg") != nil)
        #expect(r.rec("\(home)/Downloads/sub/deeper/Hidden.iso") == nil)   // depth 3
    }

    @Test func installersOutsideDownloadsIgnored() {
        let r = run(tree(d("Projects", [f("Old.dmg", mib: 50, daysAgo: 90)])))
        #expect(r.result.recommendations.isEmpty)
    }
}

// MARK: - Protected locations

@Suite("Protected locations")
struct ProtectedTests {
    @Test func buildArtifactsInsideDocumentsAreStillFound() throws {
        let app = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [f("x.js", mib: 5)]))
        let r = run(tree(d("Documents", [app])))
        #expect(r.node("\(home)/Documents")?.annotation?.safety == .doNotDelete)
        #expect(r.node("\(home)/Documents")?.annotation?.ruleID == "user.documents")
        let rec = try #require(r.rec("\(home)/Documents/app/node_modules"))
        #expect(rec.safety == .safeToClear)
        // The node_modules annotation wins over the inherited protection.
        #expect(r.node("\(home)/Documents/app/node_modules/x.js")?.effectiveAnnotation?.ruleID == "node.node_modules")
    }

    @Test func nothingInsideAnAppBundleIsRecommended() {
        let bundle = d("Foo.app", [d("Contents", [
            f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [f("x.js", mib: 5)]),
            d("Resources", [d("target", [f("big", mib: 50)]), f("Cargo.toml", mib: 1), f("Docker.raw", mib: 100)]),
        ])])
        let r = run(tree(d("Applications", [bundle]), root: "/", ))
        #expect(r.result.recommendations.isEmpty)
        #expect(r.node("/Applications/Foo.app")?.annotation?.safety == .doNotDelete)
        #expect(r.node("/Applications/Foo.app/Contents/Resources/Docker.raw")?.category == .applications)
        #expect(r.result.annotatedNodeCount == 1)
    }

    @Test func systemAndUserProtections() {
        let r = run(tree(
            d("Pictures", [d("Photos Library.photoslibrary", [f("db", mib: 5)])]),
            d("Library", [d("Mobile Documents", [f("x", mib: 2)]), d("Mail", [f("m", mib: 2)])]),
            d("Desktop", [f("a", mib: 2)])
        ))
        #expect(r.node("\(home)/Pictures/Photos Library.photoslibrary")?.annotation?.ruleID == "user.media_library")
        #expect(r.node("\(home)/Library/Mobile Documents")?.annotation?.safety == .doNotDelete)
        #expect(r.node("\(home)/Library/Mail")?.annotation?.ruleID == "user.mail_messages")
        #expect(r.node("\(home)/Desktop")?.annotation?.safety == .doNotDelete)
        #expect(r.result.recommendations.isEmpty)

        let sys = run(tree(
            d("System", [d("Library", [f("kext", mib: 5)])]),
            d("usr", [d("bin", [f("ls", mib: 5)]), d("local", [f("brew", mib: 5)])]),
            d("private", [d("var", [d("db", [f("x", mib: 5)]), d("folders", [f("y", mib: 5)])])]),
            root: "/"
        ))
        #expect(sys.node("/System")?.annotation?.safety == .doNotDelete)
        #expect(sys.node("/usr")?.annotation?.safety == .doNotDelete)
        #expect(sys.node("/usr/local")?.annotation?.safety != .doNotDelete)
        #expect(sys.node("/private/var/db")?.annotation?.safety == .doNotDelete)
        #expect(sys.node("/System/Library/kext")?.category == .system)
        #expect(sys.node("/private/var/folders/y")?.category == .system)
        #expect(sys.node("/usr/local")?.category != .system)
    }

    @Test func appSupportChildrenAreUnknown() {
        let r = run(tree(d("Library", [d("Application Support", [d("Slack", [f("cache", mib: 5)])]), d("Containers", [d("com.x", [f("a", mib: 5)])])])))
        let slack = r.node("\(home)/Library/Application Support/Slack")?.annotation
        #expect(slack?.safety == .unknown); #expect(slack?.group == .appData)
        #expect(r.node("\(home)/Library/Containers/com.x")?.annotation?.ruleID == "appdata.support")
        #expect(r.result.recommendations.isEmpty)
        #expect(r.node("\(home)/Library/Application Support/Slack/cache")?.category == .applications)
    }
}

// MARK: - Categories & totals

@Suite("Categories")
struct CategoryTests {
    @Test func categoryHints() {
        let catalog = DeveloperRulesCatalog()
        #expect(catalog.categoryHint(forFileNamed: "Movie.MP4") == .media)
        #expect(catalog.categoryHint(forFileNamed: "x.heic") == .media)
        #expect(catalog.categoryHint(forFileNamed: "model.gguf") == .aiModels)
        #expect(catalog.categoryHint(forFileNamed: "disk.QCOW2") == .containersVMs)
        #expect(catalog.categoryHint(forFileNamed: "a.pdf") == .documents)
        #expect(catalog.categoryHint(forFileNamed: "archive.tar") == .documents)
        #expect(catalog.categoryHint(forFileNamed: "x.o") == .developerBuilds)
        #expect(catalog.categoryHint(forFileNamed: "Foo.dSYM") == .developerBuilds)
        #expect(catalog.categoryHint(forFileNamed: "Foo.swiftmodule") == .developerBuilds)
        #expect(catalog.categoryHint(forFileNamed: "noextension") == nil)
        #expect(catalog.categoryHint(forFileNamed: ".mp4") == nil)
        #expect(catalog.categoryHint(forFileNamed: "weird.unknownext") == nil)
    }

    @Test func fileAndDirectoryCategories() {
        let app = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [f("a.js", mib: 5), f("clip.mp4", mib: 5)]))
        let r = run(tree(
            d("Projects", [app]),
            d("Clips", [f("a.mp4", mib: 30), f("b.mov", mib: 30), f("readme.txt", mib: 1)]),
            d("Mixed", [f("doc.pdf", mib: 10), f("movie.mp4", mib: 5)]),
            f("mystery.bin", mib: 3)
        ))
        #expect(r.node("\(home)/Projects/app/node_modules/a.js")?.category == .developerBuilds)
        // Inherited rule category beats the file-name hint.
        #expect(r.node("\(home)/Projects/app/node_modules/clip.mp4")?.category == .developerBuilds)
        #expect(r.node("\(home)/Clips/a.mp4")?.category == .media)
        #expect(r.node("\(home)/Clips")?.category == .media)
        #expect(r.node("\(home)/Mixed")?.category == .documents)
        #expect(r.node("\(home)/mystery.bin")?.category == .other)
        #expect(r.node("\(home)/Projects/app/node_modules")?.category == .developerBuilds)
    }

    @Test func categoryTotalsSumToRootMetrics() {
        let app = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [f("a.js", mib: 5)]))
        let linked = f("linked.bin", mib: 8, flags: [.hardLinked])
        let dup = f("linked-dup.bin", mib: 8, flags: [.hardLinked, .hardLinkDuplicate])
        let stub = f("stub.mov", mib: 100, flags: [.cloudPlaceholder])
        let r = run(tree(d("Projects", [app]), d("Clips", [f("a.mp4", mib: 30), stub]), d("Other", [linked, dup]), d("Empty", [])))
        let totals = r.result.categoryTotals
        let allocated = totals.values.reduce(UInt64(0)) { $0 + $1.allocatedBytes }
        let logical = totals.values.reduce(UInt64(0)) { $0 + $1.logicalBytes }
        let priv = totals.values.reduce(UInt64(0)) { $0 + $1.privateBytes }
        let files = totals.values.reduce(UInt32(0)) { $0 + $1.fileCount }
        #expect(allocated == r.root.metrics.allocatedBytes)
        #expect(logical == r.root.metrics.logicalBytes)
        #expect(priv == r.root.metrics.privateBytes)
        #expect(files == r.root.metrics.fileCount)
        #expect(totals[.developerBuilds]?.allocatedBytes == 5 * MiB)
        #expect(totals[.media]?.allocatedBytes == 30 * MiB)
    }

    @Test func everyNodeGetsACategoryAndReclassificationIsIdempotent() {
        let app = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [f("a.js", mib: 5)]))
        let root = tree(d("Projects", [app]))
        let engine = ClassificationEngine()
        let first = engine.classify(root: root, context: ctx())
        let second = engine.classify(root: root, context: ctx())
        #expect(first.recommendations.map(\.id) == second.recommendations.map(\.id))
        #expect(first.annotatedNodeCount == second.annotatedNodeCount)
        var annotations = 0
        root.walk { if $0.annotation != nil { annotations += 1 }; return .continue }
        #expect(annotations == second.annotatedNodeCount)   // no stale annotations accumulate
    }
}

// MARK: - Recommendation mechanics

@Suite("Recommendation mechanics")
struct MechanicsTests {
    private func sized(_ mibs: [(String, UInt64)]) -> FileTreeNode {
        let projects = mibs.map { name, mib in
            project(name, f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [f("blob", mib: mib)]))
        }
        return tree(d("Projects", projects))
    }

    @Test func minimumBytesRespected() {
        let root = sized([("big", 50), ("tiny", 0)])
        let r = run(root, ctx(minimum: 10 * MiB))
        #expect(r.result.recommendations.map(\.path) == ["\(home)/Projects/big/node_modules"])
        // Still annotated even when below the threshold.
        #expect(r.node("\(home)/Projects/tiny/node_modules")?.annotation != nil)
    }

    @Test func sortedByReclaimableThenPath() {
        let root = sized([("a", 10), ("b", 30), ("c", 20), ("d", 20)])
        let r = run(root)
        #expect(r.result.recommendations.map(\.path) == [
            "\(home)/Projects/b/node_modules", "\(home)/Projects/c/node_modules",
            "\(home)/Projects/d/node_modules", "\(home)/Projects/a/node_modules",
        ])
        #expect(r.result.recommendations.first?.id == "node.node_modules|\(home)/Projects/b/node_modules")
    }

    @Test func reclaimableUsesPrivateBytes() throws {
        let shared = FileTreeNode.file("blob", logical: 40 * MiB, allocated: 40 * MiB, privateBytes: 4 * MiB)
        let app = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [shared]))
        let r = run(tree(d("Projects", [app])))
        let rec = try #require(r.rec("\(home)/Projects/app/node_modules"))
        #expect(rec.reclaimableBytes == 4 * MiB)
        #expect(hasSignal(rec, .cloneSharedContent))
    }

    @Test func ageSignalsUseNewestDescendant() throws {
        let nm = d("node_modules", [f("old.js", mib: 3, daysAgo: 200), f("new.js", mib: 3, daysAgo: 5)])
        let app = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1), nm)
        let recent = try #require(run(tree(d("Projects", [app]))).rec("\(home)/Projects/app/node_modules"))
        #expect(hasSignal(recent, .recentlyModified(days: 5)))
        #expect(!recent.signals.contains { if case .inactive = $0 { return true } else { return false } })

        let nm2 = d("node_modules", [f("old.js", mib: 3, daysAgo: 200), f("older.js", mib: 3, daysAgo: 45)])
        let app2 = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1), nm2)
        let inactive = try #require(run(tree(d("Projects", [app2]))).rec("\(home)/Projects/app/node_modules"))
        // The matched directory's own mtime (100 days) is older than its newest file (45).
        #expect(hasSignal(inactive, .inactive(days: 45)))

        // Thresholds come from the context.
        let strict = try #require(run(tree(d("Projects", [app2])), ctx(inactivity: 60)).rec("\(home)/Projects/app/node_modules"))
        #expect(hasSignal(strict, .recentlyModified(days: 45)))
    }

    @Test func hardLinkedContentSignal() throws {
        let linked = (0..<4).map { f("l\($0)", mib: 5, flags: [.hardLinked]) }
        let own = f("own", mib: 5)
        let heavy = project("heavy", f("package.json", mib: 1), f("pnpm-lock.yaml", mib: 1), d("node_modules", linked + [own]))
        let light = project("light", f("package.json", mib: 1), f("pnpm-lock.yaml", mib: 1), d("node_modules", [f("l", mib: 5, flags: [.hardLinked]), f("a", mib: 5), f("b", mib: 5)]))
        let r = run(tree(d("Projects", [heavy, light])))
        #expect(hasSignal(try #require(r.rec("\(home)/Projects/heavy/node_modules")), .hardLinkedContent))
        #expect(!hasSignal(try #require(r.rec("\(home)/Projects/light/node_modules")), .hardLinkedContent))
    }

    @Test func missingLockfileSignalSurvivesAgeSignals() throws {
        let app = project("app", f("package.json", mib: 1), d("node_modules", [f("a", mib: 3)]))
        let rec = try #require(run(tree(d("Projects", [app]))).rec("\(home)/Projects/app/node_modules"))
        #expect(rec.signals.first == .missingLockfile)
        #expect(rec.signals.count >= 2)
    }

    @Test func annotationsMirrorMatches() throws {
        let app = project("app", f("package.json", mib: 1), f("package-lock.json", mib: 1), d("node_modules", [f("a", mib: 3)]))
        let r = run(tree(d("Projects", [app])))
        let annotation = try #require(r.node("\(home)/Projects/app/node_modules")?.annotation)
        #expect(annotation.ruleID == "node.node_modules")
        #expect(annotation.safety == .safeToClear)
        #expect(annotation.reason.contains("package.json"))
        #expect(r.result.annotatedNodeCount == 1)
    }

    @Test func safetyInvariantsHoldForEveryRecommendation() {
        let r = run(KnownFixtures.everything())
        #expect(!r.result.recommendations.isEmpty)
        for rec in r.result.recommendations {
            switch rec.safety {
            case .safeToClear, .reviewFirst:
                #expect(rec.action.isTrashable, "\(rec.id)")
                #expect(!rec.evidence.isEmpty, "\(rec.id)")
            case .guidedExternalAction:
                #expect(!rec.action.isTrashable, "\(rec.id)")
                #expect(rec.action.guidedRemediation != nil, "\(rec.id)")
            case .doNotDelete, .unknown:
                #expect(!rec.isTrashable, "\(rec.id)")
            }
        }
    }

    @Test func untrustedCatalogCannotMakeProtectedTrashable() throws {
        struct Rogue: DeveloperRulesCataloging {
            func match(node: FileTreeNode, path: String, context: ClassificationContext) -> RuleMatch? {
                guard node.name == "x" else { return nil }
                return RuleMatch(ruleID: "rogue", title: "x", category: .other, safety: .doNotDelete, group: .system,
                                 rationale: "r", action: .moveToTrash, recommend: true, descend: false)
            }
            func categoryHint(forFileNamed name: String) -> StorageCategory? { nil }
        }
        let root = tree(f("x", mib: 5))
        let result = ClassificationEngine(catalog: Rogue()).classify(root: root, context: ctx())
        let rec = try #require(result.recommendations.first)
        #expect(!rec.action.isTrashable)
        #expect(!rec.isTrashable)
    }
}

enum KnownFixtures {
    static func everything() -> FileTreeNode {
        let app = project("app", f("package.json", mib: 1), d("node_modules", [f("a", mib: 3)]))
        return tree(
            d("Projects", [app]),
            d("Downloads", [f("Old.dmg", mib: 50, daysAgo: 90)]),
            d(".ollama", [d("models", [f("b", mib: 20)])]),
            d(".orbstack", [f("d", mib: 20)]),
            d("Library", [d("Developer", [d("Xcode", [d("DerivedData", [f("i", mib: 10)])]), d("CoreSimulator", [d("Devices", [f("d", mib: 10)])])]),
                          d("Containers", [d("com.docker.docker", [f("Docker.raw", mib: 100)])])])
        )
    }
}

// MARK: - Performance & deep trees

@Suite("Scale")
struct ScaleTests {
    @Test func classifiesHundredsOfThousandsOfNodesQuickly() {
        let exts = ["swift", "txt", "mp4", "pdf", "o", "json", "png", "bin", "gz", "md"]
        var projects: [FileTreeNode] = []
        var count = 0
        for p in 0..<300 {
            var modules: [FileTreeNode] = []
            for m in 0..<20 {
                var files: [FileTreeNode] = []
                for i in 0..<50 { files.append(.file("f\(i).\(exts[(i + m) % exts.count])", logical: 5_000, modificationTime: 1_000)); count += 1 }
                modules.append(.directory("mod\(m)", children: files)); count += 1
            }
            // A node_modules with plenty of files that must be skipped quickly.
            var nm: [FileTreeNode] = []
            for i in 0..<100 { nm.append(.file("n\(i).js", logical: 9_000)); count += 1 }
            let manifest = [FileTreeNode.file("package.json", logical: 1_000), .file("package-lock.json", logical: 1_000)]
            let project = FileTreeNode.directory("proj\(p)", children: manifest + [.directory("src", children: modules), .directory("node_modules", children: nm)])
            projects.append(project)
            count += 5
        }
        let root = FileTreeNode.directory(home, children: [.directory("Projects", children: projects)])
        root.recomputeAggregates()
        #expect(count >= 300_000)

        let start = Date()
        let result = ClassificationEngine().classify(root: root, context: ctx(minimum: 1))
        let elapsed = Date().timeIntervalSince(start)
        print("⏱ classified \(count) nodes in \(String(format: "%.2f", elapsed)) s (\(result.recommendations.count) recommendations)")
        #expect(elapsed < 3.0)
        #expect(result.recommendations.count == 300)
        let total = result.categoryTotals.values.reduce(UInt64(0)) { $0 + $1.allocatedBytes }
        #expect(total == root.metrics.allocatedBytes)
    }

    @Test func deepTreesDoNotRecurse() throws {
        let leaf = FileTreeNode.directory("node_modules", children: [.file("deep.js", logical: 5 * MiB)])
        var chain: FileTreeNode = .directory("app", children: [.file("package.json", logical: 10), .file("package-lock.json", logical: 10), leaf])
        for level in 0..<300 { chain = .directory("d\(level)", children: [chain]) }
        let root = FileTreeNode.directory(home, children: [chain])
        root.recomputeAggregates()
        let result = ClassificationEngine().classify(root: root, context: ctx())
        #expect(result.recommendations.count == 1)
        #expect(result.recommendations[0].path.hasSuffix("/app/node_modules"))
        #expect(result.recommendations[0].path.split(separator: "/").count > 300)
    }
}
