// swift-tools-version: 6.0
//
// KlaD — APFS Storage Intelligence, Developer Purge & Visual Disk Analyzer.
//
// Module graph:
//
//   KlaDModels ──┬── KlaDScanner ─────────────┐
//   (frozen       ├── KlaDIntelligence ────────┤
//    contracts)   └── KlaDStorageOps ──────────┴── KlaD (App + UI executable)
//
// Each service lives in its own target that depends ONLY on
// KlaDModels, so each module can be type-checked and tested without the UI
// (or the other services) compiling.

import PackageDescription
import Foundation

// Command Line Tools ship Swift Testing (`import Testing`) but SwiftPM does not
// add its framework search path when Xcode.app isn't the active developer dir.
// Detect that case and wire the paths in for test targets only.
let cltRoot = "/Library/Developer/CommandLineTools"
let cltFrameworks = cltRoot + "/Library/Developer/Frameworks"
let activeDeveloperDir = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
let needsCLTTestingShim = (activeDeveloperDir.hasPrefix(cltRoot) || activeDeveloperDir.isEmpty)
    && FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
let testSwiftSettings: [SwiftSetting] = needsCLTTestingShim ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testLinkerSettings: [LinkerSetting] = needsCLTTestingShim ? [.unsafeFlags(["-F", cltFrameworks])] : []
// NOTE: the SwiftPM-generated test *runner* only enables Swift Testing when it
// can `import Testing` itself, which per-target flags can't reach — always run
// tests through `Scripts/test.sh` (or `make test`), which adds the global flags
// and the runtime rpaths on Command-Line-Tools-only machines.

let package = Package(
    name: "KlaD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KlaD", targets: ["KlaD"]),
        .executable(name: "klad-probe", targets: ["KlaDProbe"]),
    ],
    targets: [
        // ── Data contracts ───────────────────────────────
        .target(
            name: "KlaDModels",
            path: "Sources/Models"
        ),

        // ── BSD/APFS kernel scanner ─────────────────────────────
        .target(
            name: "KlaDScanner",
            dependencies: ["KlaDModels"],
            path: "Sources/Scanner"
        ),

        // ── Intelligence: rules and classification ───────────────────────────
        .target(
            name: "KlaDIntelligence",
            dependencies: ["KlaDModels"],
            path: "Sources/Services/Intelligence"
        ),

        // ── Storage operations: history, duplicates, cleanup ────────────────────────────
        .target(
            name: "KlaDStorageOps",
            dependencies: ["KlaDModels"],
            path: "Sources/Services/StorageOps",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // ── SwiftUI app (App + UI) ──────────────────────────────
        .executableTarget(
            name: "KlaD",
            dependencies: ["KlaDModels", "KlaDScanner", "KlaDIntelligence", "KlaDStorageOps"],
            path: "Sources",
            exclude: ["Models", "Scanner", "Services", "Probe"],
            sources: ["App", "UI"]
        ),

        // ── Headless scanner probe / benchmark CLI ──────────────
        .executableTarget(
            name: "KlaDProbe",
            dependencies: ["KlaDModels", "KlaDScanner"],
            path: "Sources/Probe"
        ),

        // ── Tests (Swift Testing; one target per module) ─────────────────────
        .testTarget(
            name: "KlaDCoreTests",
            dependencies: ["KlaDModels", "KlaDScanner", "KlaD"],
            path: "Tests/KlaDTests/Core",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "KlaDIntelligenceTests",
            dependencies: ["KlaDModels", "KlaDIntelligence"],
            path: "Tests/KlaDTests/Intelligence",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "KlaDStorageOpsTests",
            dependencies: ["KlaDModels", "KlaDStorageOps"],
            path: "Tests/KlaDTests/StorageOps",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
