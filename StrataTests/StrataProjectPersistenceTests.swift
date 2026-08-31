import XCTest
@testable import Strata
import Foundation

final class StrataProjectPersistenceTests: XCTestCase {

    private func makeValidProject(id: String? = nil) throws -> StrataProject {
        let pid = id ?? UUID().uuidString.lowercased()
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 0.5 }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        return try StrataProject(
            schemaVersion: 1,
            id: pid,
            createdAt: now,
            lastOpenedAt: now,
            displayTitle: "Test Title",
            source: StrataProjectSource(kind: .localFile, locator: "/tmp/input.wav", metadata: nil),
            canonicalInputPath: "source/mixture.wav",
            artworkPath: nil,
            inferenceManifestPath: "separation/manifest.json",
            gains: gains
        )
    }

    private func temporaryProjectsRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StrataTestProjects-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Project root

    func testProjectsRootUsesApplicationSupport() {
        let fm = FileManager.default
        let root = StrataProject.projectsRoot(fileManager: fm)
        XCTAssertTrue(root.path.contains("Strata"))
        XCTAssertTrue(root.path.contains("Projects"))
        XCTAssertTrue(root.lastPathComponent == "Projects")
        // Verify via persistence default
        let persistence = StrataProjectPersistence()
        XCTAssertTrue(persistence.projectsRootURL().path.contains("Strata"))
        XCTAssertTrue(persistence.projectsRootURL().path.contains("Projects"))
    }

    func testProjectRootOverrideInjection() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        XCTAssertEqual(persistence.projectsRootURL(), tmp)
        let pid = UUID().uuidString.lowercased()
        XCTAssertEqual(persistence.projectDirectory(for: pid), tmp.appendingPathComponent(pid, isDirectory: true))
        XCTAssertEqual(persistence.projectFileURL(for: pid), tmp.appendingPathComponent(pid, isDirectory: true).appendingPathComponent("project.json"))
    }

    func testStaticHelpersProjectDirectoryAndFileURL() {
        let pid = UUID().uuidString.lowercased()
        let fm = FileManager.default
        let dir = StrataProject.projectDirectory(for: pid, fileManager: fm)
        let file = StrataProject.projectFileURL(for: pid, fileManager: fm)
        XCTAssertEqual(file, dir.appendingPathComponent("project.json"))
        XCTAssertTrue(dir.path.hasSuffix(pid))
    }

    // MARK: - Save / Load round trip

    func testSaveAndLoadRoundTrip() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)
        let loaded = try persistence.load(projectID: project.id)
        XCTAssertEqual(loaded, project)
        // Also load via URL seam (canonical)
        let url = persistence.projectFileURL(for: project.id)
        let loaded2 = try persistence.loadForTesting(from: url)
        XCTAssertEqual(loaded2, project)
    }

    func testSaveValidatesBeforeWriting() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let iso = ISO8601DateFormatter().string(from: now)
        var gains: [String:Double] = [:]
        for s in StemName.allCases { gains[s.rawValue] = 1.0 }
        let badJSON: [String:Any] = [
            "schema_version": 1,
            "project_id": pid,
            "created_at": iso,
            "last_opened_at": iso,
            "display_title": "Title",
            "source": ["kind": "localFile", "locator": "/tmp/file.wav"] as [String:Any],
            "canonical_input_path": "source/wrong.wav",
            "inference_manifest_path": "separation/manifest.json",
            "gains": gains
        ]
        let data = try JSONSerialization.data(withJSONObject: badJSON)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(StrataProject.self, from: data))
        // Also ensure save with valid project succeeds
        let valid = try makeValidProject()
        XCTAssertNoThrow(try persistence.save(valid))
    }

    func testCreateProjectDirectoryCreatesSubdirs() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        let dir = persistence.projectDirectory(for: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("separation").path))
    }

    // MARK: - Exact layout validation via persistence

    func testWrongPathRejectedOnLoad() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let iso = ISO8601DateFormatter().string(from: now)
        var gains: [String:Double] = [:]
        for s in StemName.allCases { gains[s.rawValue] = 1.0 }
        let json: [String:Any] = [
            "schema_version": 1,
            "project_id": pid,
            "created_at": iso,
            "last_opened_at": iso,
            "display_title": "Title",
            "source": ["kind": "localFile", "locator": "/tmp/file.wav"] as [String:Any],
            "canonical_input_path": "source/wrong.wav",
            "inference_manifest_path": "separation/manifest.json",
            "gains": gains
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let dir = tmp.appendingPathComponent(pid, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("project.json")
        try data.write(to: url, options: .atomic)
        XCTAssertThrowsError(try persistence.load(projectID: pid)) { err in
            XCTAssertTrue(err is StrataProjectError || err is StrataProjectPersistenceError)
        }
    }

    func testAbsolutePathRejectedOnLoad() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let iso = ISO8601DateFormatter().string(from: now)
        var gains: [String:Double] = [:]
        for s in StemName.allCases { gains[s.rawValue] = 1.0 }
        let json: [String:Any] = [
            "schema_version": 1,
            "project_id": pid,
            "created_at": iso,
            "last_opened_at": iso,
            "display_title": "Title",
            "source": ["kind": "localFile", "locator": "/tmp/file.wav"] as [String:Any],
            "canonical_input_path": "/absolute/path.wav",
            "inference_manifest_path": "separation/manifest.json",
            "gains": gains
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let dir = tmp.appendingPathComponent(pid, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("project.json"), options: .atomic)
        XCTAssertThrowsError(try persistence.load(projectID: pid))
    }

    func testDotDotTraversalRejectedOnLoad() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let iso = ISO8601DateFormatter().string(from: now)
        var gains: [String:Double] = [:]
        for s in StemName.allCases { gains[s.rawValue] = 1.0 }
        let json: [String:Any] = [
            "schema_version": 1,
            "project_id": pid,
            "created_at": iso,
            "last_opened_at": iso,
            "display_title": "Title",
            "source": ["kind": "localFile", "locator": "/tmp/file.wav"] as [String:Any],
            "canonical_input_path": "source/../mixture.wav",
            "inference_manifest_path": "separation/manifest.json",
            "gains": gains
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let dir = tmp.appendingPathComponent(pid, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("project.json"), options: .atomic)
        XCTAssertThrowsError(try persistence.load(projectID: pid))
    }

    // MARK: - Load canonical restriction

    func testLoadFromArbitraryPathRejected() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)
        // Try loading from arbitrary path (outside canonical)
        let arbitrary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("project.json")
        try FileManager.default.createDirectory(at: arbitrary.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: arbitrary.deletingLastPathComponent()) }
        let data = try Data(contentsOf: persistence.projectFileURL(for: project.id))
        try data.write(to: arbitrary, options: .atomic)
        XCTAssertThrowsError(try persistence.loadForTesting(from: arbitrary))
    }

    // MARK: - Containment symlink test

    func testSymlinkEscapingRejected() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("StrataOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideFile = outside.appendingPathComponent("evil.wav")
        FileManager.default.createFile(atPath: outsideFile.path, contents: Data("evil".utf8))

        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)

        // Create symlink inside project at separation/vocals.wav pointing outside
        let projectDir = persistence.projectDirectory(for: project.id)
        let separationDir = projectDir.appendingPathComponent("separation", isDirectory: true)
        let vocalsPath = separationDir.appendingPathComponent("vocals.wav")
        try FileManager.default.createDirectory(at: separationDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: vocalsPath.path) {
            try FileManager.default.removeItem(at: vocalsPath)
        }
        try FileManager.default.createSymbolicLink(atPath: vocalsPath.path, withDestinationPath: outsideFile.path)

        XCTAssertThrowsError(try persistence.load(projectID: project.id)) { err in
            guard let e = err as? StrataProjectError else {
                if let pe = err as? StrataProjectPersistenceError, case .validationFailed(let inner) = pe {
                    XCTAssertTrue(inner == .symlinkEscapesProject("separation/vocals.wav") || inner == .pathEscapesProject("separation/vocals.wav"))
                    return
                }
                XCTFail("expected StrataProjectError got \(err)")
                return
            }
            XCTAssertTrue(e == .symlinkEscapesProject("separation/vocals.wav") || e == .pathEscapesProject("separation/vocals.wav"), "got \(e)")
        }
    }

    func testSymlinkInsideProjectAllowed() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)
        let projectDir = persistence.projectDirectory(for: project.id)
        let sourceMixtureInside = projectDir.appendingPathComponent("source/mixture.wav")
        try FileManager.default.createDirectory(at: projectDir.appendingPathComponent("source"), withIntermediateDirectories: true)
        let target = projectDir.appendingPathComponent("source/real.wav")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        if FileManager.default.fileExists(atPath: sourceMixtureInside.path) {
            try FileManager.default.removeItem(at: sourceMixtureInside)
        }
        try FileManager.default.createSymbolicLink(atPath: sourceMixtureInside.path, withDestinationPath: target.path)
        XCTAssertNoThrow(try persistence.load(projectID: project.id))
    }

    func testSymlinkProjectDirectoryEscapesRejectedBeforeRead() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("StrataOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)

        let originalDir = persistence.projectDirectory(for: project.id)
        let originalURL = persistence.projectFileURL(for: project.id)
        let data = try Data(contentsOf: originalURL)

        let outsideTarget = outside.appendingPathComponent("symlinkTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        try data.write(to: outsideTarget.appendingPathComponent("project.json"), options: .atomic)

        try FileManager.default.removeItem(at: originalDir)
        try FileManager.default.createSymbolicLink(atPath: originalDir.path, withDestinationPath: outsideTarget.path)

        XCTAssertThrowsError(try persistence.load(projectID: project.id)) { err in
            if let e = err as? StrataProjectError {
                if case .symlinkEscapesProject = e { return }
                if case .pathEscapesProject = e { return }
                XCTFail("expected symlinkEscapesProject/pathEscapesProject got \(e)")
            } else {
                XCTFail("expected StrataProjectError got \(err)")
            }
        }
        // Also via test seam
        XCTAssertThrowsError(try persistence.loadForTesting(from: originalURL)) { err in
            XCTAssertTrue(err is StrataProjectError, "expected StrataProjectError got \(err)")
        }
    }

    func testSymlinkProjectFileEscapesRejectedBeforeRead() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("StrataOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)

        let originalURL = persistence.projectFileURL(for: project.id)
        let data = try Data(contentsOf: originalURL)

        let outsideFile = outside.appendingPathComponent("evilProject.json")
        try data.write(to: outsideFile, options: .atomic)

        try FileManager.default.removeItem(at: originalURL)
        try FileManager.default.createSymbolicLink(atPath: originalURL.path, withDestinationPath: outsideFile.path)

        XCTAssertThrowsError(try persistence.load(projectID: project.id)) { err in
            if let e = err as? StrataProjectError {
                if case .symlinkEscapesProject = e { return }
                if case .pathEscapesProject = e { return }
                XCTFail("expected symlinkEscapesProject/pathEscapesProject got \(e)")
            } else {
                XCTFail("expected StrataProjectError got \(err)")
            }
        }
        XCTAssertThrowsError(try persistence.loadForTesting(from: originalURL)) { err in
            XCTAssertTrue(err is StrataProjectError, "expected StrataProjectError got \(err)")
        }
    }

    // MARK: - Non-canonical shape rejected before read

    func testNonCanonicalNestedPathRejectedBeforeRead() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)
        let validData = try Data(contentsOf: persistence.projectFileURL(for: project.id))
        let nestedURL = tmp.appendingPathComponent(project.id, isDirectory: true).appendingPathComponent("nested", isDirectory: true).appendingPathComponent("project.json")
        try FileManager.default.createDirectory(at: nestedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try validData.write(to: nestedURL, options: .atomic)
        XCTAssertThrowsError(try persistence.loadForTesting(from: nestedURL)) { err in
            XCTAssertTrue(err is StrataProjectError, "expected StrataProjectError for nested non-canonical path, got \(err)")
        }
    }

    func testNonCanonicalWrongFileNameRejectedBeforeRead() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)
        let validData = try Data(contentsOf: persistence.projectFileURL(for: project.id))
        let wrongURL = tmp.appendingPathComponent(project.id, isDirectory: true).appendingPathComponent("wrong.json")
        try validData.write(to: wrongURL, options: .atomic)
        XCTAssertThrowsError(try persistence.loadForTesting(from: wrongURL)) { err in
            XCTAssertTrue(err is StrataProjectError, "expected StrataProjectError for wrong file name, got \(err)")
        }
    }

    func testNonCanonicalRootFileRejectedBeforeRead() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        try persistence.save(project)
        let validData = try Data(contentsOf: persistence.projectFileURL(for: project.id))
        let rootFileURL = tmp.appendingPathComponent("project.json")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try validData.write(to: rootFileURL, options: .atomic)
        XCTAssertThrowsError(try persistence.loadForTesting(from: rootFileURL)) { err in
            XCTAssertTrue(err is StrataProjectError, "expected StrataProjectError for root-level non-canonical path, got \(err)")
        }
    }

    // MARK: - Gains via persistence

    func testGainsValidationViaPersistence() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        var gains5: [StemName: Double] = [:]
        for s in StemName.allCases.prefix(5) { gains5[s] = 1.0 }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let pid = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try StrataProject(schemaVersion: 1, id: pid, createdAt: now, lastOpenedAt: now, displayTitle: "Title", source: StrataProjectSource(kind: .localFile, locator: "/tmp/file.wav", metadata: nil), gains: gains5))

        var gains6: [StemName: Double] = [:]
        for s in StemName.allCases { gains6[s] = 0.3 }
        XCTAssertNoThrow(try StrataProject(schemaVersion: 1, id: pid, createdAt: now, lastOpenedAt: now, displayTitle: "Title", source: StrataProjectSource(kind: .localFile, locator: "/tmp/file.wav", metadata: nil), gains: gains6))

        let valid = try StrataProject(schemaVersion: 1, id: pid, createdAt: now, lastOpenedAt: now, displayTitle: "Title", source: StrataProjectSource(kind: .localFile, locator: "/tmp/file.wav", metadata: nil), gains: gains6)
        XCTAssertNoThrow(try persistence.save(valid))
        let loaded = try persistence.load(projectID: pid)
        XCTAssertEqual(loaded.gains, gains6)
    }

    // MARK: - Relative normalized paths only via persistence

    func testRelativeNormalizedPathEnforced() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let iso = ISO8601DateFormatter().string(from: now)
        var gains: [String:Double] = [:]
        for s in StemName.allCases { gains[s.rawValue] = 1.0 }
        let json: [String:Any] = [
            "schema_version": 1,
            "project_id": pid,
            "created_at": iso,
            "last_opened_at": iso,
            "display_title": "Title",
            "source": ["kind": "localFile", "locator": "/tmp/file.wav"] as [String:Any],
            "canonical_input_path": "source/mixture.wav/",
            "inference_manifest_path": "separation/manifest.json",
            "gains": gains
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let dir = tmp.appendingPathComponent(pid, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("project.json"), options: .atomic)
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        XCTAssertThrowsError(try persistence.load(projectID: pid))
    }

    // MARK: - Artwork optional handling

    func testArtworkOptionalSaveLoad() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let withArt = try StrataProject(
            schemaVersion: 1,
            id: UUID().uuidString.lowercased(),
            createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            lastOpenedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            displayTitle: "Title",
            source: StrataProjectSource(kind: .localFile, locator: "/tmp/file.wav", metadata: nil),
            artworkPath: "source/artwork.jpg",
            gains: {
                var g: [StemName:Double] = [:]
                for s in StemName.allCases { g[s] = 1.0 }
                return g
            }()
        )
        try persistence.createProjectDirectory(for: withArt)
        try persistence.save(withArt)
        let loaded = try persistence.load(projectID: withArt.id)
        XCTAssertEqual(loaded.artworkPath, "source/artwork.jpg")
    }

    // MARK: - Canonical JSON keys check

    func testPersistenceWritesCanonicalKeys() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.save(project)
        let url = persistence.projectFileURL(for: project.id)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["schema_version"])
        XCTAssertNotNil(json["project_id"])
        XCTAssertNotNil(json["created_at"])
        XCTAssertNotNil(json["last_opened_at"])
        XCTAssertNotNil(json["display_title"])
        XCTAssertNotNil(json["source"])
        XCTAssertNotNil(json["canonical_input_path"])
        XCTAssertNotNil(json["inference_manifest_path"])
        XCTAssertNil(json["stemPaths"])
        XCTAssertNil(json["sourceMixturePath"])
    }
}
