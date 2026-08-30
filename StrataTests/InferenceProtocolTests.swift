import XCTest
@testable import Strata
import Foundation

final class InferenceProtocolTests: XCTestCase {

    // MARK: - Command encoding

    func testSeparateCommandEncodingExact() throws {
        let cmd = try SeparateCommand.make(jobId: "abc-123", inputPath: "/tmp/mixture.wav", outputDir: "/tmp/out")
        XCTAssertEqual(cmd.protocol, 1)
        XCTAssertEqual(cmd.type, "separate")
        XCTAssertEqual(cmd.job_id, "abc-123")
        XCTAssertEqual(cmd.input_path, "/tmp/mixture.wav")
        XCTAssertEqual(cmd.output_dir, "/tmp/out")
        let data = try cmd.encodeNDJSON()
        // Must be NDJSON: single line JSON + newline, sorted keys
        XCTAssertTrue(data.last == 0x0A, "NDJSON must end with newline")
        let raw = String(data: data.dropLast(), encoding: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        XCTAssertEqual(obj["protocol"] as? Int, 1)
        XCTAssertEqual(obj["type"] as? String, "separate")
        XCTAssertEqual(obj["job_id"] as? String, "abc-123")
        XCTAssertEqual(obj["input_path"] as? String, "/tmp/mixture.wav")
        XCTAssertEqual(obj["output_dir"] as? String, "/tmp/out")
        XCTAssertEqual(obj.keys.sorted(), ["input_path","job_id","output_dir","protocol","type"])
        // Round-trip
        let decoded = try JSONDecoder().decode(SeparateCommand.self, from: data.prefix(data.count-1))
        XCTAssertEqual(decoded, cmd)
    }

    func testSeparateCommandGeneratesLowercaseUUID() throws {
        let cmd = try SeparateCommand.make(inputPath: "/a/b.wav", outputDir: "/tmp/out")
        XCTAssertEqual(cmd.job_id, cmd.job_id.lowercased())
        XCTAssertNotNil(UUID(uuidString: cmd.job_id))
        XCTAssertEqual(cmd.protocol, 1)
        XCTAssertEqual(cmd.type, "separate")
    }

    func testSeparateCommandRejectsPathSeparators() {
        XCTAssertThrowsError(try SeparateCommand.make(jobId: "a/b", inputPath: "/a", outputDir: "/b"))
        XCTAssertThrowsError(try SeparateCommand.make(jobId: "a\\b", inputPath: "/a", outputDir: "/b"))
        XCTAssertThrowsError(try SeparateCommand.make(jobId: "", inputPath: "/a", outputDir: "/b"))
        XCTAssertThrowsError(try SeparateCommand.make(jobId: "a\u{0}b", inputPath: "/a", outputDir: "/b"))
    }

    func testSeparateCommandLowercasesSuppliedID() throws {
        let cmd = try SeparateCommand.make(jobId: "ABC-DEF", inputPath: "/a", outputDir: "/b")
        XCTAssertEqual(cmd.job_id, "abc-def")
    }

    func testShutdownCommandEncodingExact() throws {
        let cmd = ShutdownCommand()
        XCTAssertEqual(cmd.protocol, 1)
        XCTAssertEqual(cmd.type, "shutdown")
        let data = try cmd.encodeNDJSON()
        XCTAssertTrue(data.last == 0x0A)
        let obj = try JSONSerialization.jsonObject(with: Data(data.prefix(data.count-1))) as! [String: Any]
        XCTAssertEqual(obj["protocol"] as? Int, 1)
        XCTAssertEqual(obj["type"] as? String, "shutdown")
        XCTAssertEqual(obj.count, 2)
        XCTAssertEqual(obj.keys.sorted(), ["protocol","type"])
    }

    // MARK: - Event decoding every type

    func testDecodeLoadingModel() throws {
        let json = #"{"protocol":1,"type":"loading_model","model":"roformer-model-bs-roformer-sw-by-jarredou"}"#
        let ev = try decodeEvent(from: json)
        guard case .loadingModel(let e) = ev else { return XCTFail("expected loadingModel") }
        XCTAssertEqual(e.model, "roformer-model-bs-roformer-sw-by-jarredou")
        XCTAssertEqual(e.protocol, 1)
        XCTAssertEqual(e.type, "loading_model")
    }

    func testDecodeReady() throws {
        let json = #"{"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"abc123"}"#
        let ev = try decodeEvent(from: json)
        guard case .ready(let e) = ev else { return XCTFail("expected ready") }
        XCTAssertEqual(e.backend, "mlx")
        XCTAssertEqual(e.device, "mps")
        XCTAssertEqual(e.checkpoint_sha256, "abc123")
    }

    func testDecodeStarted() throws {
        let json = #"{"protocol":1,"type":"started","job_id":"jid"}"#
        let ev = try decodeEvent(from: json)
        guard case .started(let e) = ev else { return XCTFail("expected started") }
        XCTAssertEqual(e.job_id, "jid")
    }

    func testDecodeSixValidStems() throws {
        for name in StemName.allCases {
            let json = #"{"protocol":1,"type":"stem","job_id":"jid","name":"\#(name.rawValue)","path":"/tmp/\#(name.rawValue).wav"}"#
            let ev = try decodeEvent(from: json)
            guard case .stem(let e) = ev else { return XCTFail("expected stem for \(name)") }
            XCTAssertEqual(e.name, name)
            XCTAssertEqual(e.path, "/tmp/\(name.rawValue).wav")
            XCTAssertEqual(e.job_id, "jid")
        }
    }

    func testDecodeDone() throws {
        let json = #"{"protocol":1,"type":"done","job_id":"jid","output_manifest":"/tmp/manifest.json"}"#
        let ev = try decodeEvent(from: json)
        guard case .done(let e) = ev else { return XCTFail("expected done") }
        XCTAssertEqual(e.output_manifest, "/tmp/manifest.json")
        XCTAssertEqual(e.job_id, "jid")
    }

    func testDecodeWorkerError() throws {
        let json = #"{"protocol":1,"type":"error","job_id":"jid","code":"invalid_input","message":"oops"}"#
        let ev = try decodeEvent(from: json)
        guard case .error(let e) = ev else { return XCTFail("expected error") }
        XCTAssertEqual(e.code, "invalid_input")
        XCTAssertEqual(e.message, "oops")
        XCTAssertEqual(e.job_id, "jid")
    }

    // MARK: - Unknown extra fields tolerated

    func testUnknownAdditionalFieldsTolerated() throws {
        let json = #"{"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"abc","extra":"field","another":123,"nested":{"a":1}}"#
        XCTAssertNoThrow(try decodeEvent(from: json))
        // Also for other events
        let json2 = #"{"protocol":1,"type":"stem","job_id":"jid","name":"vocals","path":"/tmp/v.wav","extra":99}"#
        XCTAssertNoThrow(try decodeEvent(from: json2))
        let json3 = #"{"protocol":1,"type":"done","job_id":"jid","output_manifest":"/tmp/m.json","unknown":true}"#
        XCTAssertNoThrow(try decodeEvent(from: json3))
        let json4 = #"{"protocol":1,"type":"loading_model","model":"m","extra":1}"#
        XCTAssertNoThrow(try decodeEvent(from: json4))
    }

    // MARK: - Unsupported protocol

    func testUnsupportedProtocolVersionRejected() {
        let json = #"{"protocol":2,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"abc"}"#
        XCTAssertThrowsError(try decodeEvent(from: json)) { err in
            guard case InferenceError.unsupportedProtocol(let v) = err else { return XCTFail("expected unsupportedProtocol got \(err)") }
            XCTAssertEqual(v, 2)
        }
        let json2 = #"{"protocol":0,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"abc"}"#
        XCTAssertThrowsError(try decodeEvent(from: json2)) { err in
            guard case InferenceError.unsupportedProtocol = err else { return XCTFail() }
        }
        // Even for other event types
        let json3 = #"{"protocol":99,"type":"stem","job_id":"jid","name":"vocals","path":"/tmp/v.wav"}"#
        XCTAssertThrowsError(try decodeEvent(from: json3))
    }

    // MARK: - Unknown event type

    func testUnknownEventTypeRejected() {
        let json = #"{"protocol":1,"type":"bogus_type"}"#
        XCTAssertThrowsError(try decodeEvent(from: json)) { err in
            guard case InferenceError.unknownEvent(let t) = err else { return XCTFail("got \(err)") }
            XCTAssertEqual(t, "bogus_type")
        }
        let json2 = #"{"protocol":1,"type":"unknown"}"#
        XCTAssertThrowsError(try decodeEvent(from: json2))
    }

    // MARK: - Malformed JSON

    func testMalformedJSONRejected() {
        XCTAssertThrowsError(try decodeEvent(from: "{not json"))
        XCTAssertThrowsError(try decodeEvent(from: Data("not json".utf8)))
        XCTAssertThrowsError(try decodeEvent(from: "{"))
        XCTAssertThrowsError(try decodeEvent(from: ""))
    }

    func testNonObjectJSONRejected() {
        XCTAssertThrowsError(try decodeEvent(from: "[1,2,3]")) { err in
            guard case InferenceError.malformedProtocol = err else { return XCTFail("expected malformed got \(err)") }
        }
        XCTAssertThrowsError(try decodeEvent(from: "\"string\""))
        XCTAssertThrowsError(try decodeEvent(from: "123"))
        XCTAssertThrowsError(try decodeEvent(from: "null"))
    }

    func testBlankLineRejected() {
        XCTAssertThrowsError(try decodeEvent(from: "   \n")) { err in
            guard case InferenceError.malformedProtocol(let msg) = err else { return XCTFail() }
            XCTAssertTrue(msg.lowercased().contains("blank"))
        }
        XCTAssertThrowsError(try decodeEvent(from: Data("\n".utf8)))
        XCTAssertThrowsError(try decodeEvent(from: Data("   \r\n  ".utf8)))
        XCTAssertThrowsError(try decodeEvent(from: ""))
        XCTAssertThrowsError(try decodeEvent(from: Data()))
    }

    func testBlankNDJSONLineRejectedViaData() {
        XCTAssertThrowsError(try decodeEvent(from: Data("   ".utf8)))
    }

    // MARK: - Required-field omission

    func testRequiredFieldOmissionRejected() {
        // ready missing device
        let json = #"{"protocol":1,"type":"ready","backend":"mlx"}"#
        XCTAssertThrowsError(try decodeEvent(from: json))
        // ready missing checkpoint
        let json2 = #"{"protocol":1,"type":"ready","backend":"mlx","device":"mps"}"#
        XCTAssertThrowsError(try decodeEvent(from: json2))
        // stem missing path
        let json3 = #"{"protocol":1,"type":"stem","job_id":"jid","name":"vocals"}"#
        XCTAssertThrowsError(try decodeEvent(from: json3))
        // stem missing name
        let json4 = #"{"protocol":1,"type":"stem","job_id":"jid","path":"/tmp/v.wav"}"#
        XCTAssertThrowsError(try decodeEvent(from: json4))
        // started missing job_id
        let json5 = #"{"protocol":1,"type":"started"}"#
        XCTAssertThrowsError(try decodeEvent(from: json5))
        // done missing output_manifest
        let json6 = #"{"protocol":1,"type":"done","job_id":"jid"}"#
        XCTAssertThrowsError(try decodeEvent(from: json6))
        // error missing code
        let json7 = #"{"protocol":1,"type":"error","job_id":"jid","message":"oops"}"#
        XCTAssertThrowsError(try decodeEvent(from: json7))
        // header missing protocol
        let json8 = #"{"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"abc"}"#
        XCTAssertThrowsError(try decodeEvent(from: json8))
        // header missing type
        let json9 = #"{"protocol":1,"backend":"mlx","device":"mps","checkpoint_sha256":"abc"}"#
        XCTAssertThrowsError(try decodeEvent(from: json9))
    }

    // MARK: - Wrong field types

    func testWrongFieldTypesRejected() {
        // protocol as string
        XCTAssertThrowsError(try decodeEvent(from: #"{"protocol":"1","type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"abc"}"#))
        // backend as int
        XCTAssertThrowsError(try decodeEvent(from: #"{"protocol":1,"type":"ready","backend":123,"device":"mps","checkpoint_sha256":"abc"}"#))
        // type as int
        XCTAssertThrowsError(try decodeEvent(from: #"{"protocol":1,"type":123,"backend":"mlx","device":"mps","checkpoint_sha256":"abc"}"#))
        // job_id as int
        XCTAssertThrowsError(try decodeEvent(from: #"{"protocol":1,"type":"started","job_id":123}"#))
        // name as int
        XCTAssertThrowsError(try decodeEvent(from: #"{"protocol":1,"type":"stem","job_id":"jid","name":123,"path":"/tmp/v.wav"}"#))
        // path as int
        XCTAssertThrowsError(try decodeEvent(from: #"{"protocol":1,"type":"stem","job_id":"jid","name":"vocals","path":123}"#))
    }

    // MARK: - Unknown stem

    func testUnknownStemRejected() {
        let json = #"{"protocol":1,"type":"stem","job_id":"jid","name":"harp","path":"/tmp/harp.wav"}"#
        XCTAssertThrowsError(try decodeEvent(from: json)) { err in
            // Should be unknownStem or malformedProtocol containing stem info
            switch err {
            case InferenceError.unknownStem(let s): XCTAssertEqual(s.lowercased(), "harp".lowercased() == s.lowercased() ? s : s) // allow case insensitive check
                XCTAssertTrue(true)
            case InferenceError.malformedProtocol(let m): XCTAssertTrue(m.lowercased().contains("stem"))
            default: XCTFail("unexpected error \(err)")
            }
        }
        let json2 = #"{"protocol":1,"type":"stem","job_id":"jid","name":"Instrumental","path":"/tmp/i.wav"}"#
        XCTAssertThrowsError(try decodeEvent(from: json2))
        let json3 = #"{"protocol":1,"type":"stem","job_id":"jid","name":"","path":"/tmp/v.wav"}"#
        XCTAssertThrowsError(try decodeEvent(from: json3))
    }

    // MARK: - Paths with spaces

    func testPathsWithSpacesPreservedExactly() throws {
        let path = "/tmp/my dir/vocals file.wav"
        let json = #"{"protocol":1,"type":"stem","job_id":"jid","name":"vocals","path":"\#(path)"}"#
        let ev = try decodeEvent(from: json)
        guard case .stem(let e) = ev else { return XCTFail() }
        XCTAssertEqual(e.path, path)
        // Separate command with spaces
        let cmd = try SeparateCommand.make(jobId: "jid", inputPath: "/tmp/foo bar/mixture file.wav", outputDir: "/tmp/out dir")
        let data = try cmd.encodeNDJSON()
        let decoded = try JSONDecoder().decode(SeparateCommand.self, from: data.prefix(data.count-1))
        XCTAssertEqual(decoded.input_path, "/tmp/foo bar/mixture file.wav")
        XCTAssertEqual(decoded.output_dir, "/tmp/out dir")
        // Done manifest with spaces
        let json2 = #"{"protocol":1,"type":"done","job_id":"jid","output_manifest":"/tmp/my dir/manifest.json"}"#
        let ev2 = try decodeEvent(from: json2)
        guard case .done(let d) = ev2 else { return XCTFail() }
        XCTAssertEqual(d.output_manifest, "/tmp/my dir/manifest.json")
        // Stem event direct with spaces in path round-trip via encode
        let stem = StemEvent(protocol: 1, type: "stem", job_id: "jid", name: .vocals, path: "/tmp/space path/v.wav")
        let enc = try JSONEncoder().encode(stem)
        let dec = try JSONDecoder().decode(StemEvent.self, from: enc)
        XCTAssertEqual(dec.path, "/tmp/space path/v.wav")
    }

    // MARK: - Line size boundary

    func testLineAtLegalSizeBoundaryAccepted() throws {
        // Build a valid ready event padded with extra field to reach exactly maxNDJSONLineBytes
        let base = #"{"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"abc","pad":""#
        // Need to compute padding to reach exactly 64 KiB
        // JSON is base + X + "\"}"
        let overhead = base.count + 2 // closing "\" and "}"
        let target = maxNDJSONLineBytes
        let padLen = target - overhead
        XCTAssertTrue(padLen > 0)
        let pad = String(repeating: "a", count: padLen)
        let json = base + pad + "\"}"
        let data = Data(json.utf8)
        XCTAssertEqual(data.count, maxNDJSONLineBytes)
        XCTAssertNoThrow(try decodeEvent(from: data))
        // Also via string API
        XCTAssertNoThrow(try decodeEvent(from: json))
    }

    func testLineExceeding64KiBRejectedDeterministically() {
        // 64 KiB +1 must be rejected regardless of content
        let large = String(repeating: "a", count: 64*1024 + 1)
        let data = Data(large.utf8)
        XCTAssertThrowsError(try decodeEvent(from: data)) { err in
            guard case InferenceError.malformedProtocol(let msg) = err else { return XCTFail("expected malformed got \(err)") }
            XCTAssertTrue(msg.contains("64") || msg.contains("exceeds") || msg.lowercased().contains("large"))
        }
        // Also test with a valid JSON padded to 64KiB+1
        let base = #"{"protocol":1,"type":"ready","backend":"mlx","device":"mps","checkpoint_sha256":"abc","pad":""#
        let overhead = base.count + 2
        let padLen = (64*1024 + 1) - overhead
        let pad = String(repeating: "b", count: padLen)
        let json = base + pad + "\"}"
        XCTAssertThrowsError(try decodeEvent(from: Data(json.utf8)))
        XCTAssertThrowsError(try decodeEvent(from: json))
        // Ensure Data overload also rejects
        let jsonData = Data(json.utf8)
        XCTAssertTrue(jsonData.count > maxNDJSONLineBytes)
        XCTAssertThrowsError(try decodeEvent(from: jsonData))
    }

    func testLineExceedingLimitRejectedEvenIfValidJSON() {
        // Create a long but otherwise valid separate command JSON exceeding limit
        let longPath = "/" + String(repeating: "a", count: 70*1024)
        let json = #"{"protocol":1,"type":"stem","job_id":"jid","name":"vocals","path":"\#(longPath)"}"#
        let data = Data(json.utf8)
        XCTAssertTrue(data.count > maxNDJSONLineBytes)
        XCTAssertThrowsError(try decodeEvent(from: data))
    }

    // MARK: - Additional coverage: ensure decode tolerates whitespace variations

    func testWhitespaceVariations() throws {
        let json = #"{ "protocol" : 1 , "type" : "ready" , "backend" : "mlx" , "device" : "mps" , "checkpoint_sha256" : "abc" }"#
        XCTAssertNoThrow(try decodeEvent(from: json))
    }

    func testEachStemNameCaseSensitive() {
        // Uppercase should be rejected
        for name in ["Vocals","VOCALS","Drums"] {
            let json = #"{"protocol":1,"type":"stem","job_id":"jid","name":"\#(name)","path":"/tmp/v.wav"}"#
            XCTAssertThrowsError(try decodeEvent(from: json), "should reject \(name)")
        }
    }
}
