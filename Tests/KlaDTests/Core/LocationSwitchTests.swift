// LocationSwitchTests.swift — switching locations must not rescan.

import Foundation
import Testing
@testable import KlaD
@testable import KlaDModels

@MainActor
@Suite("Location switching")
struct LocationSwitchTests {
    private func makeFolder(_ name: String, files: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("klad-switch-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for index in 0..<files {
            try Data(repeating: UInt8(index), count: 4096).write(to: url.appendingPathComponent("f\(index).bin"))
        }
        return url.path
    }

    private func waitUntilReady(_ app: AppState) async throws {
        for _ in 0..<400 where app.phase != .ready {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(app.phase == .ready)
    }

    @Test func switchingBackRestoresInstantlyWithoutRescanning() async throws {
        let a = try makeFolder("a", files: 3)
        let b = try makeFolder("b", files: 5)
        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
        }
        let app = AppState(history: nil)
        app.liveUpdates = false
        let locationA = app.addLocation(path: a)
        let locationB = app.addLocation(path: b)
        defer { app.removeLocation(locationA); app.removeLocation(locationB) }

        app.open(locationA)
        try await waitUntilReady(app)
        let treeA = try #require(app.root)
        #expect(treeA.metrics.fileCount == 3)

        app.open(locationB)
        try await waitUntilReady(app)
        #expect(app.root?.metrics.fileCount == 5)

        // Back to A: same tree object, ready immediately, no scan phase at all.
        app.open(locationA)
        #expect(app.phase == .ready)
        #expect(app.root === treeA)

        // Re-selecting the location that's already shown does nothing.
        app.open(locationA)
        #expect(app.root === treeA)

        // An explicit Rescan does scan again.
        app.rescan()
        #expect(app.phase == .scanning)
        try await waitUntilReady(app)
        #expect(app.root !== treeA)
    }
}
