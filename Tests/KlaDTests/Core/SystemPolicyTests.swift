// SystemPolicyTests.swift — the "never touch protected or system data" guarantees.

import Foundation
import Testing
@testable import KlaDModels
@testable import KlaDScanner

@Suite("System policy")
struct SystemPolicyTests {
    let home = "/Users/tester"

    @Test func trashIsOnlyEverPossibleInsideHome() {
        #expect(SystemPolicy.mayModify("/Users/tester/code/app/node_modules", home: home))
        #expect(!SystemPolicy.mayModify("/Applications/Foo.app", home: home))
        #expect(!SystemPolicy.mayModify("/System/Library/Caches", home: home))
        #expect(!SystemPolicy.mayModify("/Library/Developer/CommandLineTools", home: home))
        #expect(!SystemPolicy.mayModify("/Users/other/project", home: home))
        #expect(!SystemPolicy.mayModify("/", home: home))
    }

    @Test func standardFoldersAndProtectedDataAreNeverModifiable() {
        for folder in ["Desktop", "Documents", "Downloads", "Library", "Pictures"] {
            #expect(!SystemPolicy.mayModify(home + "/" + folder, home: home))
        }
        #expect(!SystemPolicy.mayModify(home + "/Library/Caches", home: home))
        #expect(!SystemPolicy.mayModify(home + "/Library/Mail/V10/x.emlx", home: home))
        #expect(!SystemPolicy.mayModify(home + "/Library/Containers/com.docker.docker/Data", home: home))
        #expect(!SystemPolicy.mayModify(home + "/Pictures/Photos Library.photoslibrary/originals", home: home))
        #expect(!SystemPolicy.mayModify(home + "/code/../Library/Mail", home: home))
        #expect(SystemPolicy.mayModify(home + "/Library/Caches/Homebrew", home: home))
    }

    @Test func scannerRefusesProtectedAndSystemRoots() {
        let realHome = NSHomeDirectory()
        #expect(throws: ScannerError.self) { try ScanSession.checkPolicy(realHome + "/Library/Mail") }
        #expect(throws: ScannerError.self) { try ScanSession.checkPolicy("/System/Library") }
        #expect(throws: ScannerError.self) { try ScanSession.checkPolicy("/private/var/db") }
        #expect(throws: ScannerError.self) { try ScanSession.checkPolicy(realHome + "/Pictures/Photos Library.photoslibrary") }
        #expect(throws: Never.self) { try ScanSession.checkPolicy(realHome) }
        #expect(throws: Never.self) { try ScanSession.checkPolicy("/Applications") }
        #expect(throws: Never.self) { try ScanSession.checkPolicy("/Library/Developer") }
    }

    @Test func protectedFoldersAreNeverDescended() async throws {
        // A fixture folder named like a protected package is recorded but never opened.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("klad-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Fake.photoslibrary/originals")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1 << 20).write(to: library.appendingPathComponent("photo.heic"))
        let result = try await BulkAPFSScanner().scan(ScanOptions(rootPath: root.path)) { _ in }
        let node = try #require(result.root.child(named: "Fake.photoslibrary"))
        #expect(node.isProtectedLocation)
        #expect(node.children.isEmpty)
        #expect(result.root.metrics.fileCount == 0)
    }
}
