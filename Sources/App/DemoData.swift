// DemoData.swift — a realistic, fictional developer Mac for screenshots and
// demos (`--demo`). Nothing here touches the disk; no real files are shown.

import Foundation
import KlaDModels

enum DemoData {
    static let home = "/Users/you"

    private static let now = Int64(Date().timeIntervalSince1970)
    private static func daysAgo(_ days: Int) -> Int64 { now - Int64(days) * 86_400 }

    private static let GB: UInt64 = 1_000_000_000
    private static let MB: UInt64 = 1_000_000

    private static func file(_ name: String, _ bytes: UInt64, age: Int = 30, flags: NodeFlags = []) -> FileTreeNode {
        .file(name, logical: bytes, flags: flags, modificationTime: daysAgo(age))
    }

    private static func dir(_ name: String, age: Int = 30, _ children: [FileTreeNode]) -> FileTreeNode {
        .directory(name, modificationTime: daysAgo(age), children: children)
    }

    /// Many files of varying size (deterministic).
    private static func spread(_ prefix: String, count: Int, total: UInt64, ext: String, age: Int = 30) -> [FileTreeNode] {
        var generator = SplitMix(seed: UInt64(prefix.utf8.reduce(7) { $0 &* 31 &+ UInt64($1) }))
        let weights = (0..<count).map { _ in pow(Double(generator.next() % 1000 + 1) / 1000, 3) + 0.02 }
        let sum = weights.reduce(0, +)
        return weights.enumerated().map { index, weight in
            file("\(prefix)-\(index + 1).\(ext)", UInt64(Double(total) * weight / sum), age: age + index % 9)
        }
    }

    private static func nodeModules(_ total: UInt64, age: Int) -> FileTreeNode {
        let packages = ["next", "react-dom", "@swc", "typescript", "esbuild", "@babel", "webpack", "eslint", "prettier",
                        "lodash", "rxjs", "date-fns", "@types", "tailwindcss", "postcss", "framer-motion", "three",
                        "@aws-sdk", "sharp", "puppeteer", "jest", "vite", "rollup", "zod", "axios", "@radix-ui"]
        var generator = SplitMix(seed: total)
        let weights = packages.map { _ in pow(Double(generator.next() % 1000 + 1) / 1000, 2.5) + 0.01 }
        let sum = weights.reduce(0, +)
        return dir("node_modules", age: age, packages.enumerated().map { index, name in
            let size = UInt64(Double(total) * weights[index] / sum)
            return dir(name, age: age, spread("index", count: 6, total: size, ext: "js", age: age))
        })
    }

    static func makeTree() -> FileTreeNode {
        let projects = dir("Projects", age: 1, [
            dir("storefront", age: 2, [
                file("package.json", 3_100, age: 2), file("pnpm-lock.yaml", 412_000, age: 2),
                nodeModules(1_420 * MB, age: 2),
                dir(".next", age: 2, spread("chunk", count: 18, total: 386 * MB, ext: "js", age: 2)),
                dir("src", age: 1, spread("component", count: 40, total: 6 * MB, ext: "tsx", age: 1)),
                dir("public", age: 20, spread("hero", count: 12, total: 84 * MB, ext: "webp", age: 20)),
            ]),
            dir("render-engine", age: 64, [
                file("Cargo.toml", 1_800, age: 64), file("Cargo.lock", 98_000, age: 64),
                dir("target", age: 64, [
                    dir("debug", age: 64, spread("deps", count: 30, total: 5_200 * MB, ext: "rlib", age: 64)),
                    dir("release", age: 70, spread("deps", count: 22, total: 2_100 * MB, ext: "rlib", age: 70)),
                    file("CACHEDIR.TAG", 177, age: 64),
                ]),
                dir("src", age: 64, spread("module", count: 24, total: 3 * MB, ext: "rs", age: 64)),
            ]),
            dir("vision-lab", age: 9, [
                file("pyproject.toml", 2_400, age: 9), file("uv.lock", 310_000, age: 9),
                dir(".venv", age: 9, [
                    file("pyvenv.cfg", 300, age: 9),
                    dir("lib", age: 9, spread("site-package", count: 40, total: 5_600 * MB, ext: "so", age: 9)),
                ]),
                dir("datasets", age: 40, spread("shard", count: 16, total: 18_400 * MB, ext: "parquet", age: 40)),
                dir("checkpoints", age: 12, spread("epoch", count: 6, total: 9_800 * MB, ext: "safetensors", age: 12)),
            ]),
            dir("Atlas iOS", age: 15, [
                file("Package.swift", 2_900, age: 15),
                dir(".build", age: 15, spread("object", count: 30, total: 1_340 * MB, ext: "o", age: 15)),
                dir("Sources", age: 15, spread("View", count: 60, total: 4 * MB, ext: "swift", age: 15)),
            ]),
            dir("landing-page", age: 140, [
                file("package.json", 1_400, age: 140), file("package-lock.json", 288_000, age: 140),
                nodeModules(612 * MB, age: 140),
                dir("dist", age: 140, spread("bundle", count: 10, total: 48 * MB, ext: "js", age: 140)),
            ]),
        ])

        let library = dir("Library", age: 0, [
            dir("Developer", age: 3, [
                dir("Xcode", age: 3, [
                    dir("DerivedData", age: 3, [
                        dir("Atlas-bxqkfyzoplmn", age: 3, spread("index", count: 20, total: 6_400 * MB, ext: "o", age: 3)),
                        dir("Widgets-cxlrmtvwqyab", age: 48, spread("index", count: 20, total: 3_900 * MB, ext: "o", age: 48)),
                        dir("Prototype-dhqzrnpwke", age: 120, spread("index", count: 20, total: 2_700 * MB, ext: "o", age: 120)),
                    ]),
                    dir("Archives", age: 60, spread("Atlas", count: 5, total: 3_100 * MB, ext: "xcarchive", age: 60)),
                    dir("iOS DeviceSupport", age: 90, spread("iPhone17,1 26", count: 3, total: 9_600 * MB, ext: "dmg", age: 90)),
                ]),
                dir("CoreSimulator", age: 5, [
                    dir("Devices", age: 5, spread("device", count: 8, total: 14_200 * MB, ext: "img", age: 5)),
                ]),
            ]),
            dir("Caches", age: 0, [
                dir("Homebrew", age: 4, spread("bottle", count: 24, total: 3_300 * MB, ext: "tar.gz", age: 4)),
                dir("pip", age: 9, spread("wheel", count: 30, total: 2_100 * MB, ext: "whl", age: 9)),
                dir("com.spotify.client", age: 0, spread("data", count: 20, total: 4_800 * MB, ext: "file", age: 0)),
                dir("Google", age: 0, spread("cache", count: 20, total: 1_300 * MB, ext: "bin", age: 0)),
                dir("Yarn", age: 30, spread("pkg", count: 20, total: 900 * MB, ext: "tgz", age: 30)),
            ]),
            dir("Application Support", age: 0, [
                dir("Slack", age: 0, spread("db", count: 12, total: 2_400 * MB, ext: "ldb", age: 0)),
                dir("Code", age: 0, spread("state", count: 12, total: 1_600 * MB, ext: "vscdb", age: 0)),
                dir("Figma", age: 2, spread("cache", count: 12, total: 1_100 * MB, ext: "bin", age: 2)),
            ]),
            dir("Containers", age: 0, []),
            dir("Mail", age: 0, []),
            dir("Messages", age: 0, []),
        ])

        let downloads = dir("Downloads", age: 1, [
            file("Xcode_26.1.xip", 11_800 * MB, age: 96),
            file("ubuntu-26.04-desktop-arm64.iso", 6_200 * MB, age: 71),
            file("Docker.dmg", 742 * MB, age: 54),
            file("Figma.dmg", 288 * MB, age: 40),
            file("dataset-export.zip", 2_400 * MB, age: 33),
            file("conference-talk.mov", 3_900 * MB, age: 12),
        ] + spread("receipt", count: 14, total: 60 * MB, ext: "pdf", age: 20))

        let ai = [
            dir(".ollama", age: 6, [
                dir("models", age: 6, [
                    dir("blobs", age: 6, [
                        file("sha256-6a0746a1ec1aef3e7ec53868f220ff6e389f6f8ef87a01d77c96807de94ca2aa", 4_700 * MB, age: 6),
                        file("sha256-e8a35b5937a5e6d5c35d1f2a15f161e07eefe5e5bb0a3cdd42998ee79b057730", 8_100 * MB, age: 30),
                        file("sha256-970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6", 2_000 * MB, age: 80),
                    ]),
                    dir("manifests", age: 6, spread("tag", count: 3, total: 10_000, ext: "json", age: 6)),
                ]),
            ]),
            dir(".cache", age: 4, [
                dir("huggingface", age: 4, [
                    dir("hub", age: 4, [
                        dir("models--meta-llama--Llama-3.1-8B-Instruct", age: 20, spread("model", count: 4, total: 16_100 * MB, ext: "safetensors", age: 20)),
                        dir("models--stabilityai--stable-diffusion-xl-base-1.0", age: 75, spread("model", count: 5, total: 6_900 * MB, ext: "safetensors", age: 75)),
                        dir("models--openai--whisper-large-v3", age: 30, spread("model", count: 2, total: 3_100 * MB, ext: "safetensors", age: 30)),
                    ]),
                ]),
            ]),
            dir(".npm", age: 2, [dir("_cacache", age: 2, spread("content", count: 30, total: 1_900 * MB, ext: "bin", age: 2))]),
            dir(".cargo", age: 10, [dir("registry", age: 10, spread("crate", count: 30, total: 2_600 * MB, ext: "crate", age: 10))]),
        ]

        let media = [
            dir("Movies", age: 12, [
                dir("Keynote Edit.fcpbundle", age: 12, spread("render", count: 10, total: 21_000 * MB, ext: "mov", age: 12)),
                file("drone-coastline-4k.mov", 7_400 * MB, age: 200),
                file("product-demo.mp4", 1_200 * MB, age: 30),
            ]),
            dir("Pictures", age: 3, [
                dir("Photos Library.photoslibrary", age: 3, []),
                dir("Screenshots", age: 1, spread("Screenshot", count: 40, total: 640 * MB, ext: "png", age: 1)),
            ]),
            dir("Music", age: 400, spread("track", count: 30, total: 4_800 * MB, ext: "m4a", age: 400)),
            dir("Documents", age: 2, spread("doc", count: 40, total: 5_200 * MB, ext: "pdf", age: 2)
                + spread("deck", count: 8, total: 2_100 * MB, ext: "key", age: 25)),
            dir("Desktop", age: 0, spread("capture", count: 20, total: 1_100 * MB, ext: "png", age: 0)),
        ]

        let root = dir(home, age: 0, [projects, library, downloads] + ai + media)
        // Protected folders arrive from the scanner flagged and empty.
        for path in ["Library/Containers", "Library/Mail", "Library/Messages", "Pictures/Photos Library.photoslibrary"] {
            root.descendant(atPath: home + "/" + path)?.flags.insert([.protectedLocation, .excluded])
        }
        root.recomputeAggregates()
        return root
    }

    static func volume() -> VolumeSpaceReport {
        VolumeSpaceReport(
            volumePath: "/", volumeName: "Macintosh HD", fileSystemType: "apfs", deviceIdentifier: "disk3s1",
            totalCapacity: 494_380_000_000, availableCapacity: 196_400_000_000,
            availableForImportantUsage: 228_900_000_000, availableForOpportunisticUsage: 190_000_000_000,
            containerReference: "disk3", localSnapshotNames: [], supportsCloneMapping: true, supportsPrivateSize: true
        )
    }
}

/// Tiny deterministic PRNG for stable demo layouts.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
