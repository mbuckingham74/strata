import XCTest
@testable import Strata
import Foundation

final class StrataProjectTests: XCTestCase {

    // MARK: - Helpers

    private func makeValidProject(id: String? = nil, overrideGains: [StemName: Double]? = nil, overrideMixturePath: String? = nil, overrideManifestPath: String? = nil, overrideArtwork: String? = nil, overrideDisplayTitle: String? = nil, overrideSource: StrataProjectSource? = nil) throws -> StrataProject {
        let pid = id ?? UUID().uuidString.lowercased()
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        if let og = overrideGains { gains = og }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let displayTitle = overrideDisplayTitle ?? "Test Title"
        let source = overrideSource ?? StrataProjectSource(kind: .localFile, locator: "/tmp/input.wav", metadata: nil)
        return try StrataProject(
            schemaVersion: 1,
            id: pid,
            createdAt: now,
            lastOpenedAt: now,
            displayTitle: displayTitle,
            source: source,
            canonicalInputPath: overrideMixturePath ?? StrataProject.mixtureRelativePath,
            artworkPath: overrideArtwork,
            inferenceManifestPath: overrideManifestPath ?? StrataProject.manifestRelativePath,
            gains: gains
        )
    }

    // MARK: - SchemaVersion

    func testSchemaVersionRoundTrip() throws {
        let project = try makeValidProject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        // Check JSON contains canonical keys
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertNotNil(json["project_id"])
        XCTAssertNotNil(json["created_at"])
        XCTAssertNotNil(json["last_opened_at"])
        XCTAssertNotNil(json["display_title"])
        XCTAssertNotNil(json["source"])
        XCTAssertNotNil(json["canonical_input_path"])
        XCTAssertNotNil(json["inference_manifest_path"])
        XCTAssertNotNil(json["gains"])
        XCTAssertNil(json["schemaVersion"])
        XCTAssertNil(json["stemPaths"])
        XCTAssertNil(json["sourceMixturePath"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StrataProject.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded, project)
    }

    func testSchemaVersionMismatchRejected() throws {
        let project = try makeValidProject()
        // Encode then mutate JSON to schema_version 2
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(project)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["schema_version"] = 2
        data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(StrataProject.self, from: data)) { error in
            XCTAssertTrue(error is StrataProjectError)
            if let e = error as? StrataProjectError {
                XCTAssertEqual(e, StrataProjectError.schemaVersionMismatch(found: 2))
            }
        }
    }

    func testProjectIDValidation() {
        XCTAssertThrowsError(try makeValidProject(id: "not-a-uuid")) { err in
            guard let e = err as? StrataProjectError, case .invalidProjectID = e else { XCTFail("expected invalidProjectID"); return }
        }
        XCTAssertThrowsError(try makeValidProject(id: UUID().uuidString)) { err in // uppercase
            guard let e = err as? StrataProjectError, case .invalidProjectID = e else { XCTFail("expected invalidProjectID"); return }
        }
        XCTAssertNoThrow(try makeValidProject(id: UUID().uuidString.lowercased()))
    }

    // MARK: - Exact layout validation

    func testValidLayoutPasses() throws {
        let p = try makeValidProject()
        XCTAssertNoThrow(try p.validate())
    }

    func testWrongMixturePathRejected() {
        XCTAssertThrowsError(try makeValidProject(overrideMixturePath: "source/wrong.wav")) { err in
            XCTAssertTrue(err is StrataProjectError)
            if let e = err as? StrataProjectError { XCTAssertEqual(e, StrataProjectError.unsupportedPath("source/wrong.wav")) }
        }
    }

    func testAbsolutePathRejected() {
        XCTAssertThrowsError(try makeValidProject(overrideMixturePath: "/source/mixture.wav")) { err in
            guard let e = err as? StrataProjectError, case .invalidRelativePath = e else { XCTFail("expected invalidRelativePath"); return }
        }
    }

    func testDotDotTraversalRejected() {
        XCTAssertThrowsError(try makeValidProject(overrideMixturePath: "source/../mixture.wav")) { err in
            guard let e = err as? StrataProjectError, case .invalidRelativePath = e else { XCTFail("expected invalidRelativePath got \(err)"); return }
        }
        XCTAssertThrowsError(try makeValidProject(overrideMixturePath: "../source/mixture.wav")) { err in
            guard let e = err as? StrataProjectError else { XCTFail(); return }
            switch e { case .invalidRelativePath, .pathEscapesProject: break; default: XCTFail("wrong \(e)") }
        }
    }

    func testDotComponentRejected() {
        XCTAssertThrowsError(try makeValidProject(overrideMixturePath: "source/./mixture.wav")) { err in
            guard let e = err as? StrataProjectError, case .invalidRelativePath = e else { XCTFail(); return }
        }
    }

    func testBackslashRejected() {
        XCTAssertThrowsError(try makeValidProject(overrideMixturePath: "source\\mixture.wav")) { err in
            guard let e = err as? StrataProjectError, case .invalidRelativePath = e else { XCTFail(); return }
        }
    }

    func testEmptyPathRejected() {
        XCTAssertThrowsError(try makeValidProject(overrideMixturePath: "")) { err in
            guard let e = err as? StrataProjectError, case .invalidRelativePath = e else { XCTFail(); return }
        }
    }

    func testDoubleSlashRejected() {
        XCTAssertThrowsError(try makeValidProject(overrideMixturePath: "source//mixture.wav")) { err in
            guard let e = err as? StrataProjectError, case .invalidRelativePath = e else { XCTFail(); return }
        }
    }

    func testManifestWrongPathRejected() {
        XCTAssertThrowsError(try makeValidProject(overrideManifestPath: "separation/wrong.json")) { err in
            guard let e = err as? StrataProjectError, case .unsupportedPath = e else { XCTFail(); return }
        }
    }

    func testStemPathsComputedCorrectly() throws {
        let p = try makeValidProject()
        for s in StemName.allCases {
            XCTAssertEqual(p.stemPaths[s], "separation/\(s.rawValue).wav")
        }
        XCTAssertEqual(p.stemPaths.count, 6)
    }

    func testArtworkValidPaths() throws {
        XCTAssertNoThrow(try makeValidProject(overrideArtwork: "source/artwork.jpg"))
        XCTAssertNoThrow(try makeValidProject(overrideArtwork: "source/artwork.png"))
        XCTAssertNoThrow(try makeValidProject(overrideArtwork: "source/artwork.jpeg"))
        XCTAssertThrowsError(try makeValidProject(overrideArtwork: "source/artwork.")) { err in
            guard let e = err as? StrataProjectError, case .unsupportedPath = e else { XCTFail(); return }
        }
        XCTAssertThrowsError(try makeValidProject(overrideArtwork: "source/artwork")) { err in
            guard let e = err as? StrataProjectError else { XCTFail(); return }
            switch e { case .unsupportedPath, .invalidRelativePath: break; default: XCTFail() }
        }
        XCTAssertThrowsError(try makeValidProject(overrideArtwork: "source/artwork.jpg/extra")) { err in
            XCTAssertTrue(err is StrataProjectError)
        }
    }

    // MARK: - Gains

    func testValidGainsPass() throws {
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = Double.random(in: 0...1) }
        XCTAssertNoThrow(try makeValidProject(overrideGains: gains))
    }

    func testGainCountFiveFails() {
        var gains: [StemName: Double] = [:]
        let stems = Array(StemName.allCases.prefix(5))
        for s in stems { gains[s] = 1.0 }
        XCTAssertThrowsError(try makeValidProject(overrideGains: gains)) { err in
            guard let e = err as? StrataProjectError, case .invalidGainCount(let found) = e else { XCTFail(); return }
            XCTAssertEqual(found, 5)
        }
    }

    func testGainCountSevenFails() {
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let iso = ISO8601DateFormatter().string(from: now)
        var gainsDict: [String:Double] = [:]
        for s in StemName.allCases { gainsDict[s.rawValue] = 1.0 }
        gainsDict["extra"] = 0.5
        let json: [String:Any] = [
            "schema_version": 1,
            "project_id": pid,
            "created_at": iso,
            "last_opened_at": iso,
            "display_title": "Test Title",
            "source": ["kind": "localFile", "locator": "/tmp/file.wav"] as [String:Any],
            "canonical_input_path": "source/mixture.wav",
            "inference_manifest_path": "separation/manifest.json",
            "gains": gainsDict
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(StrataProject.self, from: data))
    }

    func testGainNaNFails() {
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        gains[.vocals] = Double.nan
        XCTAssertThrowsError(try makeValidProject(overrideGains: gains)) { err in
            guard let e = err as? StrataProjectError, case .invalidGainNotFinite(let stem) = e else { XCTFail("\(err)"); return }
            XCTAssertEqual(stem, StemName.vocals.rawValue)
        }
    }

    func testGainInfFails() {
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        gains[.drums] = Double.infinity
        XCTAssertThrowsError(try makeValidProject(overrideGains: gains)) { err in
            guard let e = err as? StrataProjectError, case .invalidGainNotFinite(let stem) = e else { XCTFail(); return }
            XCTAssertEqual(stem, StemName.drums.rawValue)
        }
    }

    func testGainNegativeFails() {
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        gains[.bass] = -0.1
        XCTAssertThrowsError(try makeValidProject(overrideGains: gains)) { err in
            guard let e = err as? StrataProjectError, case .invalidGainOutOfRange = e else { XCTFail(); return }
        }
    }

    func testGainAboveOneFails() {
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        gains[.guitar] = 1.1
        XCTAssertThrowsError(try makeValidProject(overrideGains: gains)) { err in
            guard let e = err as? StrataProjectError, case .invalidGainOutOfRange = e else { XCTFail(); return }
        }
    }

    // MARK: - Relative normalized paths only

    func testNormalizedPathWithDotSlashRejected() {
        // Directly test validateRelativePath
        XCTAssertThrowsError(try StrataProject.validateRelativePath("source/./mixture.wav"))
        XCTAssertThrowsError(try StrataProject.validateRelativePath("separation/../separation/vocals.wav"))
    }

    // MARK: - Projects root

    func testProjectsRootContainsStrataAndProjects() {
        let root = StrataProject.projectsRoot(fileManager: FileManager.default)
        XCTAssertTrue(root.path.contains("Strata"))
        XCTAssertTrue(root.path.contains("Projects"))
        XCTAssertTrue(root.path.hasSuffix("Strata/Projects") || root.path.hasSuffix("Strata/Projects/"))
    }

    func testProjectsRootViaFileManagerOverride() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        let root = StrataProject.projectsRoot(fileManager: fm)
        XCTAssertTrue(root.path.contains("Strata"))
        // When using persistence with override, root is override
        let persistence = StrataProjectPersistence(fileManager: fm, projectsRootOverride: tmp)
        XCTAssertEqual(persistence.projectsRootURL(), tmp)
        XCTAssertEqual(persistence.projectDirectory(for: "abc").path, tmp.appendingPathComponent("abc").path)
        XCTAssertEqual(persistence.projectFileURL(for: "abc").path, tmp.appendingPathComponent("abc").appendingPathComponent("project.json").path)
    }

    // MARK: - Display title and source required

    func testDisplayTitleRequiredValidation() {
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        let source = StrataProjectSource(kind: .localFile, locator: "/tmp/file.wav", metadata: nil)
        XCTAssertThrowsError(try StrataProject(schemaVersion: 1, id: pid, createdAt: now, lastOpenedAt: now, displayTitle: "   ", source: source, gains: gains))
        XCTAssertThrowsError(try StrataProject(schemaVersion: 1, id: pid, createdAt: now, lastOpenedAt: now, displayTitle: "", source: source, gains: gains))
    }

    func testSourceLocatorRequiredValidation() {
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        XCTAssertThrowsError(try StrataProject(schemaVersion: 1, id: pid, createdAt: now, lastOpenedAt: now, displayTitle: "Title", source: StrataProjectSource(kind: .youTube, locator: "", metadata: nil), gains: gains))
        XCTAssertThrowsError(try StrataProject(schemaVersion: 1, id: pid, createdAt: now, lastOpenedAt: now, displayTitle: "Title", source: StrataProjectSource(kind: .youTube, locator: "a\0b", metadata: nil), gains: gains))
    }

    func testCanonicalJSONKeysNoFallback() throws {
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let iso = ISO8601DateFormatter().string(from: now)
        var gains: [String:Double] = [:]
        for s in StemName.allCases { gains[s.rawValue] = 1.0 }
        // Legacy keys should throw
        let legacyJSON: [String:Any] = [
            "schemaVersion": 1,
            "project_id": pid,
            "createdAt": iso,
            "updatedAt": iso,
            "sourceMixturePath": "source/mixture.wav",
            "separationManifestPath": "separation/manifest.json",
            "stemPaths": [:],
            "gains": gains,
            "displayTitle": "Title",
            "sourceKind": "localFile",
            "sourceLocator": "/tmp/file.wav"
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(StrataProject.self, from: legacyData))
        // Canonical should succeed
        let canonicalJSON: [String:Any] = [
            "schema_version": 1,
            "project_id": pid,
            "created_at": iso,
            "last_opened_at": iso,
            "display_title": "Title",
            "source": ["kind": "localFile", "locator": "/tmp/file.wav"] as [String:Any],
            "canonical_input_path": "source/mixture.wav",
            "inference_manifest_path": "separation/manifest.json",
            "gains": gains
        ]
        let canonicalData = try JSONSerialization.data(withJSONObject: canonicalJSON)
        XCTAssertNoThrow(try decoder.decode(StrataProject.self, from: canonicalData))
    }
}
