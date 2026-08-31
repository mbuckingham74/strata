import XCTest
@testable import Strata

final class StemExporterTests: XCTestCase {
    private func makeArtifact(name: StemName, url: URL, data: Data) throws -> StemArtifact {
        try data.write(to: url)
        return StemArtifact(
            name: name,
            url: url,
            sha256: sha256Hex(of: data),
            fileSize: UInt64(data.count),
            frameCount: 1,
            channels: 2,
            sampleRate: 44_100
        )
    }

    func testDefaultFilenameUsesEachStemNameAndWAVExtension() {
        for stem in StemName.allCases {
            XCTAssertEqual(StemExporter.defaultFilename(for: stem), "\(stem.rawValue).wav")
        }
    }

    func testExportCopiesArtifactBytesWithoutChangingSource() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("vocals.wav")
        let destinationURL = directoryURL.appendingPathComponent("exported-vocals.wav")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF, 0x10, 0x80])
        let artifact = try makeArtifact(name: .vocals, url: sourceURL, data: sourceData)

        try StemExporter.export(artifact, to: destinationURL)

        XCTAssertEqual(try Data(contentsOf: destinationURL), sourceData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testExportReplacesApprovedDestinationWithArtifactBytes() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("drums.wav")
        let destinationURL = directoryURL.appendingPathComponent("chosen.wav")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03, 0x04])
        let artifact = try makeArtifact(name: .drums, url: sourceURL, data: sourceData)
        try Data([0xAA, 0xBB]).write(to: destinationURL)

        try StemExporter.export(artifact, to: destinationURL)

        XCTAssertEqual(try Data(contentsOf: destinationURL), sourceData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testExportRejectsOriginalArtifactAsDestination() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("bass.wav")
        let sourceData = Data([0x52, 0x49, 0x46, 0x46, 0x10, 0x20])
        let artifact = try makeArtifact(name: .bass, url: sourceURL, data: sourceData)

        XCTAssertThrowsError(try StemExporter.export(artifact, to: sourceURL)) { error in
            XCTAssertEqual(error as? StemExportError, .sourceAndDestinationMatch)
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }
}
