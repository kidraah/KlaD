// AppUninstallerTests.swift — leftover matching and uninstall policy (fake home).

import Foundation
import Testing
@testable import KlaD
@testable import KlaDModels

@Suite("App uninstaller")
struct AppUninstallerTests {
    @Test func uninstallPolicyAllowsOnlyUserAppsInApplicationFolders() {
        let home = "/Users/tester"
        #expect(SystemPolicy.mayUninstall(appPath: "/Applications/Foo.app", bundleID: "com.example.foo", home: home))
        #expect(SystemPolicy.mayUninstall(appPath: home + "/Applications/Foo.app", bundleID: "com.example.foo", home: home))
        #expect(!SystemPolicy.mayUninstall(appPath: "/Applications/Safari.app", bundleID: "com.apple.Safari", home: home))
        #expect(!SystemPolicy.mayUninstall(appPath: "/System/Applications/Notes.app", bundleID: "com.example.x", home: home))
        #expect(!SystemPolicy.mayUninstall(appPath: "/Applications/Utilities/Foo.app", bundleID: "com.example.foo", home: home))
        #expect(!SystemPolicy.mayUninstall(appPath: "/Applications/Foo", bundleID: "com.example.foo", home: home))
        // The generic trash policy still never allows /Applications.
        #expect(!SystemPolicy.mayModify("/Applications/Foo.app", home: home))
    }

    @MainActor
    @Test func findsExactLeftoversAndMarksContainersProtected() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("klad-uninstall-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        let lib = home + "/Library"
        let make: (String) throws -> Void = { try fm.createDirectory(atPath: $0, withIntermediateDirectories: true) }
        let touch: (String) -> Void = { _ = fm.createFile(atPath: $0, contents: Data("x".utf8)) }

        try make(home + "/Applications/Foo.app/Contents")
        for folder in ["Application Support/Foo", "Application Support/com.example.foo", "Caches/com.example.foo",
                       "Caches/com.example.foo.ShipIt", "Logs/Foo", "WebKit/com.example.foo",
                       "Saved Application State/com.example.foo.savedState", "Containers/com.example.foo",
                       // Must NOT match:
                       "Application Support/FooBar", "Caches/com.example.foobar", "Caches/com.example.fo"] {
            try make(lib + "/" + folder)
        }
        try make(lib + "/Preferences/ByHost")
        try make(lib + "/LaunchAgents")
        touch(lib + "/Preferences/com.example.foo.plist")
        touch(lib + "/Preferences/ByHost/com.example.foo.0123-ABCD.plist")
        touch(lib + "/LaunchAgents/com.example.foo.helper.plist")
        touch(lib + "/Preferences/com.example.foobar.plist")

        let app = InstalledApp(path: home + "/Applications/Foo.app", name: "Foo", bundleID: "com.example.foo", version: "1.0")
        let items = AppUninstaller.findItems(for: app, home: home)
        let paths = Set(items.map(\.path))

        #expect(items.first?.kind == .application)
        for expected in ["Application Support/Foo", "Application Support/com.example.foo", "Caches/com.example.foo",
                         "Caches/com.example.foo.ShipIt", "Logs/Foo", "WebKit/com.example.foo",
                         "Saved Application State/com.example.foo.savedState", "Preferences/com.example.foo.plist",
                         "Preferences/ByHost/com.example.foo.0123-ABCD.plist", "LaunchAgents/com.example.foo.helper.plist"] {
            #expect(paths.contains(lib + "/" + expected), "missing \(expected)")
        }
        for unexpected in ["Application Support/FooBar", "Caches/com.example.foobar", "Caches/com.example.fo",
                           "Preferences/com.example.foobar.plist"] {
            #expect(!paths.contains(lib + "/" + unexpected), "should not match \(unexpected)")
        }
        let container = try #require(items.first { $0.kind == .container })
        #expect(container.isProtected, "sandbox containers are never removed")
        #expect(items.filter { !$0.isProtected && $0.kind != .application }.allSatisfy { SystemPolicy.mayModify($0.path, home: home) })
    }
}
