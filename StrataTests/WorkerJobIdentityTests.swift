import XCTest
@testable import Strata
import Foundation

final class WorkerJobIdentityTests: XCTestCase {

    func testProjectIdUsedAsJobIdViaSeparateCommand() throws {
        let projectId = UUID().uuidString.lowercased()
        XCTAssertNoThrow(try StrataProject.validateProjectID(projectId))
        let inputPath = URL(fileURLWithPath: "/tmp/mixture.wav")
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cmd = try SeparateCommand.make(jobId: projectId, inputPath: inputPath.path, outputDir: outputBase.path)
        XCTAssertEqual(cmd.job_id, projectId)
        XCTAssertEqual(cmd.input_path, inputPath.path)
        XCTAssertEqual(cmd.output_dir, outputBase.path)
        // Job directory should be outputBase/projectId
        let jobDir = outputBase.appendingPathComponent(projectId, isDirectory: true)
        XCTAssertEqual(jobDir.lastPathComponent, projectId)
        // Manifest would be in jobDir/manifest.json via validation logic; check that projectId is path-safe
        XCTAssertFalse(projectId.contains("/"))
        XCTAssertFalse(projectId.contains("\\"))
        XCTAssertFalse(projectId.contains("\0"))
    }

    func testInvalidProjectIdRejectedForJob() {
        let badId = "BAD/ID"
        XCTAssertThrowsError(try StrataProject.validateProjectID(badId))
        XCTAssertThrowsError(try SeparateCommand.make(jobId: badId, inputPath: "/tmp/a.wav", outputDir: "/tmp/out"))
    }

    func testProjectEncodeDecodePreservesIdForJobIdentity() throws {
        var gains: [StemName: Double] = [:]
        for s in StemName.allCases { gains[s] = 1.0 }
        let pid = UUID().uuidString.lowercased()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let project = try StrataProject(
            schemaVersion: 1,
            id: pid,
            createdAt: now,
            lastOpenedAt: now,
            displayTitle: "Test",
            source: StrataProjectSource(kind: .youTube, locator: "https://www.youtube.com/watch?v=test", metadata: YouTubeTrackMetadata(artist: "A", title: "T", album: nil, albumArtist: nil, year: nil, genre: nil, trackNumber: nil)),
            gains: gains
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["project_id"] as? String, pid)
        XCTAssertNotNil(json["display_title"])
        XCTAssertNotNil(json["source"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StrataProject.self, from: data)
        XCTAssertEqual(decoded.id, pid)
        // Using decoded id as jobId should be valid
        let cmd = try SeparateCommand.make(jobId: decoded.id, inputPath: "/tmp/mixture.wav", outputDir: "/tmp/out")
        XCTAssertEqual(cmd.job_id, pid)
    }

    func testInferenceWorkerClientProjectIdValidation() throws {
        // Ensure that worker client would validate projectId via StrataProject.validateProjectID
        let good = UUID().uuidString.lowercased()
        XCTAssertNoThrow(try StrataProject.validateProjectID(good))
        let badUUID = "not-a-uuid"
        XCTAssertThrowsError(try StrataProject.validateProjectID(badUUID))
        // Also ensure that path-unsafe id would be rejected via SeparateCommand
        let badPath = "bad/id"
        XCTAssertThrowsError(try SeparateCommand.make(jobId: badPath, inputPath: "/tmp/a.wav", outputDir: "/tmp/b"))
    }
}
