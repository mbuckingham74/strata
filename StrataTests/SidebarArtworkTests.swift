import XCTest
@testable import Strata

/// Focused tests for Library sidebar artwork resolution.
/// Verifies SessionStore.artworkURL(for:) uses the persisted artworkPath only.
@MainActor
final class SidebarArtworkTests: XCTestCase {

    private func makeGains() -> [StemName: Double] {
        var g: [StemName: Double] = [:]
        for s in StemName.allCases { g[s] = 1.0 }
        return g
    }

    private func makeProject(artworkPath: String?) throws -> StrataProject {
        let source = StrataProjectSource(kind: .localFile, locator: "/tmp/input.wav", metadata: nil)
        return try StrataProject(
            schemaVersion: 1,
            id: UUID().uuidString.lowercased(),
            createdAt: Date(),
            lastOpenedAt: Date(),
            displayTitle: "Artwork Test",
            source: source,
            artworkPath: artworkPath,
            gains: makeGains()
        )
    }

    func testNilArtworkPathResolvesNil() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataArtworkNil-\(UUID().uuidString)", isDirectory: true)
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        let project = try makeProject(artworkPath: nil)
        XCTAssertNil(store.artworkURL(for: project))
    }

    func testMissingArtworkFileResolvesNil() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataArtworkMissing-\(UUID().uuidString)", isDirectory: true)
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        let project = try makeProject(artworkPath: "source/artwork.jpg")
        XCTAssertNil(store.artworkURL(for: project))
    }

    func testExistingArtworkFileResolvesURLAndSurvivesRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StrataArtworkHit-\(UUID().uuidString)", isDirectory: true)
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let store = SessionStore(persistence: persistence)
        let project = try makeProject(artworkPath: "source/artwork.jpg")
        let dir = persistence.projectDirectory(for: project.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("source", isDirectory: true), withIntermediateDirectories: true)
        let artURL = dir.appendingPathComponent("source/artwork.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: artURL)
        try persistence.save(project)

        XCTAssertEqual(store.artworkURL(for: project), artURL)

        // Relaunch: fresh store over the same root resolves from persisted path only.
        let relaunchedPersistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: root)
        let relaunchedStore = SessionStore(persistence: relaunchedPersistence)
        let reloaded = try relaunchedPersistence.load(projectID: project.id)
        XCTAssertEqual(relaunchedStore.artworkURL(for: reloaded), artURL)
    }
}
