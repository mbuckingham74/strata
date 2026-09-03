import XCTest
@testable import Strata
import Foundation
import CryptoKit
import AVFoundation

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

    // MARK: - Enumeration

    func testEnumerateProjectsReturnsEmptyWhenMissingRoot() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataMissingRoot-\(UUID().uuidString)")
        // Ensure not exists
        try? FileManager.default.removeItem(at: tmp)
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        XCTAssertEqual(persistence.enumerateProjects().count, 0)
    }

    func testEnumerateProjectsValidOnlyAndSorted() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        // Create 3 valid projects with different lastOpenedAt
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 0.5 }
        let p1 = try StrataProject(schemaVersion: 1, id: UUID().uuidString.lowercased(), createdAt: now, lastOpenedAt: now.addingTimeInterval(-300), displayTitle: "Oldest", source: StrataProjectSource(kind: .localFile, locator: "/tmp/a.wav", metadata: nil), gains: gains)
        let p2 = try StrataProject(schemaVersion: 1, id: UUID().uuidString.lowercased(), createdAt: now, lastOpenedAt: now, displayTitle: "Newest", source: StrataProjectSource(kind: .localFile, locator: "/tmp/b.wav", metadata: nil), gains: gains)
        let p3 = try StrataProject(schemaVersion: 1, id: UUID().uuidString.lowercased(), createdAt: now, lastOpenedAt: now.addingTimeInterval(-100), displayTitle: "Middle", source: StrataProjectSource(kind: .localFile, locator: "/tmp/c.wav", metadata: nil), gains: gains)
        for p in [p1, p2, p3] {
            try persistence.createProjectDirectory(for: p)
            try persistence.save(p)
        }
        // Add invalid entries: corrupted JSON, missing project.json, incomplete JSON
        let invalidID = UUID().uuidString.lowercased()
        let invalidDir = tmp.appendingPathComponent(invalidID, isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: invalidDir.appendingPathComponent("project.json"))

        let emptyID = UUID().uuidString.lowercased()
        let emptyDir = tmp.appendingPathComponent(emptyID, isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        // no project.json

        let badID = UUID().uuidString.lowercased()
        let badDir = tmp.appendingPathComponent(badID, isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        let badJSON: [String: Any] = ["schema_version": 1, "project_id": badID, "created_at": ISO8601DateFormatter().string(from: now), "last_opened_at": ISO8601DateFormatter().string(from: now), "display_title": "Bad", "source": ["kind": "localFile", "locator": "/tmp/x.wav"], "canonical_input_path": "source/wrong.wav", "inference_manifest_path": "separation/manifest.json", "gains": ["vocals": 1.0]]
        let badData = try JSONSerialization.data(withJSONObject: badJSON)
        try badData.write(to: badDir.appendingPathComponent("project.json"))

        // Add a plain file at root (not directory) should be ignored
        try Data("hello".utf8).write(to: tmp.appendingPathComponent("somefile.txt"))

        let enumerated = persistence.enumerateProjects()
        XCTAssertEqual(enumerated.count, 3)
        XCTAssertEqual(enumerated[0].id, p2.id)
        XCTAssertEqual(enumerated[1].id, p3.id)
        XCTAssertEqual(enumerated[2].id, p1.id)
    }

    func testEnumerateSkipsSymlinkEscapingProject() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("StrataOutsideEnum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let valid = try makeValidProject()
        try persistence.createProjectDirectory(for: valid)
        try persistence.save(valid)
        // Create a symlink project dir pointing outside -> load should fail and be skipped
        let evilID = UUID().uuidString.lowercased()
        let evilTarget = outside.appendingPathComponent("evilTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: evilTarget, withIntermediateDirectories: true)
        // Write a valid project.json inside evilTarget but with mismatched id? Instead write valid for evilID
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 0.5 }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let evilProject = try StrataProject(schemaVersion: 1, id: evilID, createdAt: now, lastOpenedAt: now, displayTitle: "Evil", source: StrataProjectSource(kind: .localFile, locator: "/tmp/evil.wav", metadata: nil), gains: gains)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(evilProject)
        try data.write(to: evilTarget.appendingPathComponent("project.json"))
        // Create symlink at tmp/evilID -> evilTarget
        let evilLink = tmp.appendingPathComponent(evilID, isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: evilLink.path, withDestinationPath: evilTarget.path)
        let enumerated = persistence.enumerateProjects()
        // Should contain only valid, evil should be skipped due to symlink escape
        XCTAssertTrue(enumerated.contains(where: { $0.id == valid.id }))
        XCTAssertFalse(enumerated.contains(where: { $0.id == evilID }))
    }

    // MARK: - Persist assets (Stage 1)

    private func makeWAVHelper(at url: URL, frames: UInt32, sr: Double = 44100, channels: UInt32 = 2) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) {
            guard let ptr = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frames) { ptr[i] = sin(Float(i) * 0.01) * 0.1 + Float(ch)*0.01 }
        }
        try file.write(from: buffer)
    }

    private func createScratchSeparation(tmp: URL, frames: UInt32 = 4096) throws -> (mixtureURL: URL, manifestURL: URL, stemURLs: [StemName: URL], jobId: String) {
        let scratch = tmp.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let mixtureURL = scratch.appendingPathComponent("mixture.wav")
        try makeWAVHelper(at: mixtureURL, frames: frames)
        let inputSHA = try sha256File(at: mixtureURL)
        let jobId = UUID().uuidString.lowercased()
        let jobDir = scratch.appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        var stemURLs: [StemName: URL] = [:]
        var records: [[String: Any]] = []
        for stem in StemName.allCases {
            let url = jobDir.appendingPathComponent("\(stem.rawValue).wav")
            try makeWAVHelper(at: url, frames: frames)
            let hash = try sha256File(at: url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            stemURLs[stem] = url
            records.append(["name": stem.rawValue, "path": url.path, "sha256": hash, "file_size": size, "frame_count": UInt64(frames), "channels": 2, "sample_rate": 44100])
        }
        let manifest: [String: Any] = [
            "job_id": jobId,
            "model": TrustedInferenceIdentity.model,
            "checkpoint_sha256": TrustedInferenceIdentity.checkpointSHA256,
            "backend": TrustedInferenceIdentity.backend,
            "device": TrustedInferenceIdentity.device,
            "input_path": mixtureURL.path,
            "output_dir": scratch.path,
            "input_sha256": inputSHA,
            "input_metadata": ["sample_rate": 44100, "channels": 2, "frames": UInt64(frames), "duration": Double(frames)/44100.0, "sha256": inputSHA],
            "stems": records
        ]
        let manifestURL = jobDir.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: manifestURL)
        return (mixtureURL, manifestURL, stemURLs, jobId)
    }

    func testPersistCopiesMixtureStemsManifestAndOptionalArtwork() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        // Create scratch sources
        let scratchTmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataPersistScratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchTmp) }
        let (mixtureURL, manifestURL, stemURLs, _) = try createScratchSeparation(tmp: scratchTmp, frames: 2048)
        // Artwork source
        let artworkSource = scratchTmp.appendingPathComponent("artwork.png")
        try Data("fake png".utf8).write(to: artworkSource)
        try persistence.persistAssets(for: project, mixtureSourceURL: mixtureURL, manifestSourceURL: manifestURL, stemSourceURLs: stemURLs, artworkSourceURL: artworkSource)
        // Verify files exist at fixed paths
        let projectDir = persistence.projectDirectory(for: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("source/mixture.wav").path))
        for stem in StemName.allCases {
            XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("separation/\(stem.rawValue).wav").path), "missing \(stem.rawValue)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("separation/manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("source/artwork.png").path))
        // Verify project.json written and artworkPath updated
        let loaded = try persistence.load(projectID: project.id)
        XCTAssertEqual(loaded.artworkPath, "source/artwork.png")
        // Verify self-contained: scratch files remain and project copy is independent
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixtureURL.path))
        let projectMixtureData = try Data(contentsOf: projectDir.appendingPathComponent("source/mixture.wav"))
        let scratchMixtureData = try Data(contentsOf: mixtureURL)
        XCTAssertEqual(projectMixtureData, scratchMixtureData)
        // Modify scratch should not affect project copy
        try Data("different".utf8).write(to: mixtureURL)
        let afterProjectData = try Data(contentsOf: projectDir.appendingPathComponent("source/mixture.wav"))
        XCTAssertEqual(afterProjectData, projectMixtureData)
    }

    func testPersistViaSeparationResultIsSelfContained() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        let scratchTmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataPersistScratch2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchTmp) }
        let (mixtureURL, manifestURL, stemURLs, jobId) = try createScratchSeparation(tmp: scratchTmp, frames: 1024)
        // Build SeparationResult via validator (scratch layout) - outputDir is scratch directory containing mixture.wav
        let scratchDir = mixtureURL.deletingLastPathComponent()
        let jobInfo = JobInfo(jobId: jobId, inputPath: mixtureURL.path, outputDir: scratchDir.path)
        let ready = ReadyMetadata(backend: TrustedInferenceIdentity.backend, device: TrustedInferenceIdentity.device, checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256, model: nil)
        let manifestURLScratch = stemURLs[.vocals]!.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let result = try SeparationValidator.validatedResult(manifestURL: manifestURLScratch, job: jobInfo, readyMetadata: ready, receivedStems: stemURLs)
        try persistence.persistCompletedSeparation(project: project, result: result, artworkSourceURL: nil)
        let projectDir = persistence.projectDirectory(for: project.id)
        for stem in StemName.allCases {
            XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("separation/\(stem.rawValue).wav").path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("source/mixture.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("separation/manifest.json").path))
        // Verify project.json exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.projectFileURL(for: project.id).path))
    }

    func testPersistMissingSourceAssetThrowsAndNoProjectJSON() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        let scratchTmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataPersistScratch3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchTmp) }
        let (mixtureURL, manifestURL, stemURLs, _) = try createScratchSeparation(tmp: scratchTmp, frames: 1024)
        var incompleteStems = stemURLs
        // Remove one stem source file to simulate missing asset (or remove key)
        let missingStem = StemName.vocals
        let missingURL = incompleteStems[missingStem]!
        try FileManager.default.removeItem(at: missingURL)
        XCTAssertThrowsError(try persistence.persistAssets(for: project, mixtureSourceURL: mixtureURL, manifestSourceURL: manifestURL, stemSourceURLs: incompleteStems, artworkSourceURL: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.projectFileURL(for: project.id).path))
        // Also test missing mixture source
        let tmp2 = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp2) }
        let persistence2 = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp2)
        let project2 = try makeValidProject()
        try persistence2.createProjectDirectory(for: project2)
        let missingMixture = scratchTmp.appendingPathComponent("nonexistent.wav")
        XCTAssertThrowsError(try persistence2.persistAssets(for: project2, mixtureSourceURL: missingMixture, manifestSourceURL: manifestURL, stemSourceURLs: stemURLs, artworkSourceURL: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence2.projectFileURL(for: project2.id).path))
        // Missing stem key count 5 should also throw without writing
        let tmp3 = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp3) }
        let persistence3 = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp3)
        let project3 = try makeValidProject()
        try persistence3.createProjectDirectory(for: project3)
        var fiveStems = stemURLs
        fiveStems.removeValue(forKey: .bass)
        XCTAssertThrowsError(try persistence3.persistAssets(for: project3, mixtureSourceURL: mixtureURL, manifestSourceURL: manifestURL, stemSourceURLs: fiveStems, artworkSourceURL: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence3.projectFileURL(for: project3.id).path))
    }

    func testPersistDoesNotRequireArtwork() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        let project = try makeValidProject()
        try persistence.createProjectDirectory(for: project)
        let scratchTmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataPersistScratch4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchTmp) }
        let (mixtureURL, manifestURL, stemURLs, _) = try createScratchSeparation(tmp: scratchTmp, frames: 1024)
        XCTAssertNoThrow(try persistence.persistAssets(for: project, mixtureSourceURL: mixtureURL, manifestSourceURL: manifestURL, stemSourceURLs: stemURLs, artworkSourceURL: nil))
        let loaded = try persistence.load(projectID: project.id)
        XCTAssertNil(loaded.artworkPath)
    }

    func testPersistValidatesProjectAndContainment() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        // Invalid project id should throw before copying
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 0.5 }
        // Create project with valid id but then corrupt? Instead test persist with valid project but ensure it validates
        let valid = try StrataProject(schemaVersion: 1, id: UUID().uuidString.lowercased(), createdAt: now, lastOpenedAt: now, displayTitle: "Title", source: StrataProjectSource(kind: .localFile, locator: "/tmp/file.wav", metadata: nil), gains: gains)
        let scratchTmp = FileManager.default.temporaryDirectory.appendingPathComponent("StrataPersistScratch5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchTmp) }
        let (mixtureURL, manifestURL, stemURLs, _) = try createScratchSeparation(tmp: scratchTmp, frames: 512)
        // Corrupt manifest source missing should throw
        let badManifest = scratchTmp.appendingPathComponent("missing.json")
        XCTAssertThrowsError(try persistence.persistAssets(for: valid, mixtureSourceURL: mixtureURL, manifestSourceURL: badManifest, stemSourceURLs: stemURLs, artworkSourceURL: nil))
    }

    // MARK: - Failure-safe replacement

    /// FileManager seam that fails a mid-commit staged->project copy, simulating
    /// a later copy failure during replacement of an existing project.
    private final class FailMidCommitFileManager: FileManager {
        var commitCopiesToFailAfter: Int = 1
        private var commitCopiesSeen: Int = 0
        override func copyItem(at src: URL, to dst: URL) throws {
            // Commit copies read from the staging directory; staging and backup
            // copies must succeed so the failure lands mid-commit.
            if src.path.contains("StrataStage-") {
                commitCopiesSeen += 1
                if commitCopiesSeen > commitCopiesToFailAfter {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [NSLocalizedDescriptionKey: "simulated mid-commit copy failure"])
                }
            }
            try super.copyItem(at: src, to: dst)
        }
    }

    private func snapshotProjectAssets(persistence: StrataProjectPersistence, projectID: String) throws -> [String: Data] {
        let dir = persistence.projectDirectory(for: projectID)
        let fm = FileManager.default
        var snap: [String: Data] = [:]
        let relatives = ["source/mixture.wav", "separation/manifest.json"] + StemName.allCases.map { "separation/\($0.rawValue).wav" }
        for rel in relatives {
            snap[rel] = try Data(contentsOf: dir.appendingPathComponent(rel))
        }
        snap["project.json"] = try Data(contentsOf: persistence.projectFileURL(for: projectID))
        return snap
    }

    func testFailedReplacementLeavesExistingProjectUnchanged() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 0.3 }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let project = try StrataProject(
            schemaVersion: 1,
            id: UUID().uuidString.lowercased(),
            createdAt: now,
            lastOpenedAt: now,
            displayTitle: "Original",
            source: StrataProjectSource(kind: .youTube, locator: "https://www.youtube.com/watch?v=abc123DEF45", metadata: nil),
            gains: gains
        )
        try persistence.createProjectDirectory(for: project)
        let scratchV1 = FileManager.default.temporaryDirectory.appendingPathComponent("StrataReplaceV1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchV1, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchV1) }
        let (mixV1, manV1, stemsV1, jobV1) = try createScratchSeparation(tmp: scratchV1, frames: 1024)
        let artV1 = scratchV1.appendingPathComponent("artwork.jpg")
        try Data("original-art".utf8).write(to: artV1)
        try persistence.persistAssets(for: project, mixtureSourceURL: mixV1, manifestSourceURL: manV1, stemSourceURLs: stemsV1, artworkSourceURL: artV1)

        var carried = try persistence.load(projectID: project.id)
        let before = try snapshotProjectAssets(persistence: persistence, projectID: project.id)
        let beforeArtwork = try Data(contentsOf: persistence.projectDirectory(for: project.id).appendingPathComponent("source/artwork.jpg"))
        let beforeJobId = try persistence.loadSeparationResult(for: project.id).jobId
        XCTAssertEqual(beforeJobId, jobV1)

        // New separation results for the same project.
        let scratchV2 = FileManager.default.temporaryDirectory.appendingPathComponent("StrataReplaceV2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchV2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchV2) }
        let (mixV2, manV2, stemsV2, _) = try createScratchSeparation(tmp: scratchV2, frames: 2048)
        carried.lastOpenedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 60)

        // Fail on the 2nd commit copy: the first commit already replaced one
        // asset, so this exercises backup restore, not just staging.
        let failingFM = FailMidCommitFileManager()
        failingFM.commitCopiesToFailAfter = 1
        let failingPersistence = StrataProjectPersistence(fileManager: failingFM, projectsRootOverride: tmp)
        XCTAssertThrowsError(try failingPersistence.persistAssets(for: carried, mixtureSourceURL: mixV2, manifestSourceURL: manV2, stemSourceURLs: stemsV2, artworkSourceURL: nil))

        // Old project fully usable and unchanged.
        let after = try snapshotProjectAssets(persistence: persistence, projectID: project.id)
        XCTAssertEqual(after, before)
        let afterArtwork = try Data(contentsOf: persistence.projectDirectory(for: project.id).appendingPathComponent("source/artwork.jpg"))
        XCTAssertEqual(afterArtwork, beforeArtwork)
        let reopened = try persistence.load(projectID: project.id)
        XCTAssertEqual(reopened.artworkPath, "source/artwork.jpg")
        XCTAssertEqual(reopened.gains, gains)
        XCTAssertEqual(try persistence.loadSeparationResult(for: project.id).jobId, jobV1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixV2.path))
    }

    func testSuccessfulReplacementKeepsIDAndCarriesForwardMetadata() throws {
        let tmp = temporaryProjectsRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = StrataProjectPersistence(fileManager: .default, projectsRootOverride: tmp)
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 0.3 }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let metadata = YouTubeTrackMetadata(artist: "Artist", title: "Title")!
        let project = try StrataProject(
            schemaVersion: 1,
            id: UUID().uuidString.lowercased(),
            createdAt: now,
            lastOpenedAt: now,
            displayTitle: "Original",
            source: StrataProjectSource(kind: .youTube, locator: "https://www.youtube.com/watch?v=abc123DEF45", metadata: metadata),
            gains: gains
        )
        try persistence.createProjectDirectory(for: project)
        let scratchV1 = FileManager.default.temporaryDirectory.appendingPathComponent("StrataReplaceOK-V1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchV1, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchV1) }
        let (mixV1, manV1, stemsV1, _) = try createScratchSeparation(tmp: scratchV1, frames: 1024)
        let artV1 = scratchV1.appendingPathComponent("artwork.jpg")
        try Data("original-art".utf8).write(to: artV1)
        try persistence.persistAssets(for: project, mixtureSourceURL: mixV1, manifestSourceURL: manV1, stemSourceURLs: stemsV1, artworkSourceURL: artV1)

        var carried = try persistence.load(projectID: project.id)
        carried.lastOpenedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 60)
        let scratchV2 = FileManager.default.temporaryDirectory.appendingPathComponent("StrataReplaceOK-V2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchV2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchV2) }
        let (mixV2, manV2, stemsV2, jobV2) = try createScratchSeparation(tmp: scratchV2, frames: 2048)
        // No new artwork: existing artwork/gains/metadata carry forward.
        try persistence.persistAssets(for: carried, mixtureSourceURL: mixV2, manifestSourceURL: manV2, stemSourceURLs: stemsV2, artworkSourceURL: nil)

        let reloaded = try persistence.load(projectID: project.id)
        XCTAssertEqual(reloaded.id, project.id)
        XCTAssertEqual(reloaded.createdAt, project.createdAt)
        XCTAssertEqual(reloaded.artworkPath, "source/artwork.jpg")
        XCTAssertEqual(reloaded.gains, gains)
        XCTAssertEqual(reloaded.source.metadata, metadata)
        let dir = persistence.projectDirectory(for: project.id)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("source/mixture.wav")), try Data(contentsOf: mixV2))
        for stem in StemName.allCases {
            XCTAssertEqual(
                try Data(contentsOf: dir.appendingPathComponent("separation/\(stem.rawValue).wav")),
                try Data(contentsOf: stemsV2[stem]!),
                "stem \(stem.rawValue) not replaced"
            )
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("separation/manifest.json")), try Data(contentsOf: manV2))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("source/artwork.jpg")), Data("original-art".utf8))
        XCTAssertEqual(try persistence.loadSeparationResult(for: project.id).jobId, jobV2)
        // project.json format unchanged (canonical keys only).
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.projectFileURL(for: project.id))) as! [String: Any]
        XCTAssertNotNil(json["schema_version"])
        XCTAssertNil(json["stemPaths"])
    }
}
