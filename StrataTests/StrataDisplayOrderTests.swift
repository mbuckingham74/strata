import XCTest
@testable import Strata
import AVFoundation

final class StrataDisplayOrderTests: XCTestCase {

    func testStrataDisplayOrderConstant() {
        let expected: [StemName] = [.vocals, .drums, .bass, .guitar, .piano, .other]
        XCTAssertEqual(strataDisplayOrder, expected)
    }

    func testStrataDisplayOrderNotAlphabetical() {
        let alphabetical = StemName.allCases.sorted { $0.rawValue < $1.rawValue }
        let alphabeticalRaw = alphabetical.map(\.rawValue)
        XCTAssertEqual(alphabeticalRaw, ["bass", "drums", "guitar", "other", "piano", "vocals"])
        XCTAssertNotEqual(strataDisplayOrder, alphabetical)
    }

    func testOrderedStemsMatchesDisplayOrderWithDummyResult() {
        let result = makeDummyResult(frameCount: 44100)
        let ordered = strataDisplayOrder.compactMap { result.stems[$0] }
        XCTAssertEqual(ordered.count, 6)
        XCTAssertEqual(ordered.map(\.name), [.vocals, .drums, .bass, .guitar, .piano, .other])

        let alphabeticalNames = result.sortedStems.map(\.name.rawValue)
        XCTAssertEqual(alphabeticalNames, ["bass", "drums", "guitar", "other", "piano", "vocals"])
        XCTAssertNotEqual(ordered.map(\.name), result.sortedStems.map(\.name))
    }

    func testOrderedStemsCountAndTimelineAlignment() {
        let frames: UInt64 = 88200
        let result = makeDummyResult(frameCount: frames)
        XCTAssertEqual(result.stems.count, 6)
        XCTAssertTrue(result.isComplete)
        let ordered = strataDisplayOrder.compactMap { result.stems[$0] }
        XCTAssertEqual(ordered.count, 6)
        // Identical timeline assumption: every stem shares same duration/frameCount
        let counts = Set(ordered.map(\.frameCount))
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first, frames)
        XCTAssertEqual(Set(ordered.map(\.sampleRate)), [44100])
        XCTAssertEqual(Set(ordered.map(\.channels)), [2])
    }

    // MARK: - Helper

    private func makeDummyResult(frameCount: UInt64) -> SeparationResult {
        var stems: [StemName: StemArtifact] = [:]
        for name in StemName.allCases {
            let url = URL(fileURLWithPath: "/tmp/\(name.rawValue).wav")
            stems[name] = StemArtifact(
                name: name,
                url: url,
                sha256: String(repeating: "a", count: 64),
                fileSize: 1024,
                frameCount: frameCount,
                channels: 2,
                sampleRate: 44100
            )
        }
        return SeparationResult(
            jobId: "test-job",
            inputURL: URL(fileURLWithPath: "/tmp/input.wav"),
            jobDirectoryURL: URL(fileURLWithPath: "/tmp/job"),
            manifestURL: URL(fileURLWithPath: "/tmp/job/manifest.json"),
            stems: stems,
            backend: "mlx",
            device: "mps",
            checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256,
            model: TrustedInferenceIdentity.model
        )
    }
}
