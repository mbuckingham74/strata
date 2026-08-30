import Foundation

// MARK: - StemName

/// Closed set of six stems. Raw values match Python VALID_STEMS.
enum StemName: String, CaseIterable, Codable, Sendable, Hashable {
    case vocals
    case drums
    case bass
    case guitar
    case piano
    case other

    /// All six required stems as a set.
    static let requiredSet: Set<StemName> = Set(StemName.allCases)
}

// MARK: - InferenceError

/// Typed, Sendable, concise user-visible inference errors. Full tracebacks are never exposed.
enum InferenceError: Error, Sendable, Equatable, LocalizedError {
    case launchConfiguration(String)
    case missingWorkerExecutable(String)
    case outputDirectoryCreation(String)
    case alreadyRunningJob
    case startupTimeout
    case startupFailure(String, stderrTail: String? = nil)
    case workerReportedJobError(code: String, message: String)
    case malformedProtocol(String)
    case unsupportedProtocol(Int)
    case unknownEvent(String)
    case illegalTransition(String)
    case duplicateStem(StemName)
    case duplicateEvent(String)
    case unknownStem(String)
    case mismatchedJob(expected: String, received: String)
    case stdinWriteFailure(String)
    case unexpectedEOF(String)
    case prematureProcessExit(Int32?, stderrTail: String?)
    case manifestValidationFailure(String)
    case cancellation
    case shutdownTimeout
    case invalidCommand(String)
    case workerBusy(String)

    var errorDescription: String? {
        switch self {
        case .launchConfiguration(let msg): return "Launch configuration: \(msg)"
        case .missingWorkerExecutable(let msg): return "Missing worker executable: \(msg)"
        case .outputDirectoryCreation(let msg): return "Output directory: \(msg)"
        case .alreadyRunningJob: return "A separation is already running"
        case .startupTimeout: return "Worker failed to become ready in time"
        case .startupFailure(let msg, _): return "Worker startup failed: \(msg)"
        case .workerReportedJobError(let code, let message): return "Worker error [\(code)]: \(message)"
        case .malformedProtocol(let msg): return "Malformed protocol: \(msg)"
        case .unsupportedProtocol(let v): return "Unsupported protocol \(v)"
        case .unknownEvent(let t): return "Unknown event type: \(t)"
        case .illegalTransition(let msg): return "Illegal transition: \(msg)"
        case .duplicateStem(let s): return "Duplicate stem: \(s.rawValue)"
        case .duplicateEvent(let msg): return "Duplicate event: \(msg)"
        case .unknownStem(let s): return "Unknown stem: \(s)"
        case .mismatchedJob(let expected, let received): return "Mismatched job_id: expected \(expected), got \(received)"
        case .stdinWriteFailure(let msg): return "Stdin write failed: \(msg)"
        case .unexpectedEOF(let msg): return "Unexpected EOF: \(msg)"
        case .prematureProcessExit(let code, _): return "Worker exited prematurely\(code.map { " (\($0))" } ?? "")"
        case .manifestValidationFailure(let msg): return "Result validation failed: \(msg)"
        case .cancellation: return "Cancelled"
        case .shutdownTimeout: return "Worker shutdown timed out"
        case .invalidCommand(let msg): return "Invalid command: \(msg)"
        case .workerBusy(let msg): return "Worker busy: \(msg)"
        }
    }

    /// Bounded stderr tail for diagnostics, if present.
    var stderrTail: String? {
        switch self {
        case .startupFailure(_, let tail): return tail
        case .prematureProcessExit(_, let tail): return tail
        default: return nil
        }
    }
}

// MARK: - Commands

/// Exact wire shape for `separate` command.
struct SeparateCommand: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String
    let job_id: String
    let input_path: String
    let output_dir: String

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case type
        case job_id
        case input_path
        case output_dir
    }

    /// Create a separate command, generating a lowercase UUID job_id if not provided.
    /// Validates that job_id contains no path separators.
    static func make(jobId: String? = nil, inputPath: String, outputDir: String) throws -> SeparateCommand {
        let jid = (jobId ?? UUID().uuidString.lowercased())
        guard !jid.isEmpty else { throw InferenceError.invalidCommand("job_id empty") }
        if jid.contains("/") || jid.contains("\\") || jid.contains("\0") {
            throw InferenceError.invalidCommand("job_id must not contain path separators")
        }
        // Enforce lowercase UUID form when generated; when caller supplies, require non-empty and no separators.
        // Additionally require that supplied jid is lowercase if it looks like UUID.
        return SeparateCommand(protocol: 1, type: "separate", job_id: jid.lowercased(), input_path: inputPath, output_dir: outputDir)
    }

    /// Convenience for URL inputs.
    static func make(jobId: String? = nil, inputPathURL: URL, outputDirURL: URL) throws -> SeparateCommand {
        try make(jobId: jobId, inputPath: inputPathURL.path, outputDir: outputDirURL.path)
    }

    func encodeNDJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var data = try enc.encode(self)
        data.append(0x0A) // newline
        return data
    }
}

/// Exact wire shape for `shutdown` command. No shutdown-ack event exists.
struct ShutdownCommand: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String

    init() {
        self.protocol = 1
        self.type = "shutdown"
    }

    func encodeNDJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var data = try enc.encode(self)
        data.append(0x0A)
        return data
    }
}

// MARK: - Event Header

struct EventHeader: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String
}

// MARK: - Typed Events

struct LoadingModelEvent: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String
    let model: String

    enum CodingKeys: String, CodingKey { case `protocol`, type, model }
}

struct ReadyEvent: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String
    let backend: String
    let device: String
    let checkpoint_sha256: String

    enum CodingKeys: String, CodingKey { case `protocol`, type, backend, device, checkpoint_sha256 }
}

struct StartedEvent: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String
    let job_id: String

    enum CodingKeys: String, CodingKey { case `protocol`, type, job_id }
}

struct StemEvent: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String
    let job_id: String
    let name: StemName
    let path: String

    enum CodingKeys: String, CodingKey { case `protocol`, type, job_id, name, path }
}

struct DoneEvent: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String
    let job_id: String
    let output_manifest: String

    enum CodingKeys: String, CodingKey { case `protocol`, type, job_id, output_manifest }
}

struct WorkerErrorEvent: Codable, Sendable, Equatable {
    let `protocol`: Int
    let type: String
    let job_id: String
    let code: String
    let message: String

    enum CodingKeys: String, CodingKey { case `protocol`, type, job_id, code, message }
}

// MARK: - InferenceEvent Enum

enum InferenceEvent: Sendable, Equatable {
    case loadingModel(LoadingModelEvent)
    case ready(ReadyEvent)
    case started(StartedEvent)
    case stem(StemEvent)
    case done(DoneEvent)
    case error(WorkerErrorEvent)
}

// MARK: - Decoding

/// Maximum NDJSON stdout line size: 64 KiB (spec section 10).
let maxNDJSONLineBytes = 64 * 1024

enum InferenceProtocolError: Error {
    case blankLine
    case lineTooLarge(Int)
    case malformedJSON(String)
    case nonObject
    case blank
    case unsupportedProtocol(Int)
    case unknownEvent(String)
    case missingField(String)
}

func decodeEvent(from data: Data) throws -> InferenceEvent {
    // Bounded line framing
    if data.count > maxNDJSONLineBytes {
        throw InferenceError.malformedProtocol("NDJSON line exceeds \(maxNDJSONLineBytes) bytes")
    }
    // Reject blank lines
    if let str = String(data: data, encoding: .utf8) {
        if str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw InferenceError.malformedProtocol("blank stdout line")
        }
    }
    // Ensure valid JSON
    let decoder = JSONDecoder()
    // First decode header
    let header: EventHeader
    do {
        header = try decoder.decode(EventHeader.self, from: data)
    } catch {
        // Distinguish malformed JSON vs missing fields: treat any decode failure as malformed
        // But check if top-level is not object
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if !(obj is [String: Any]) {
                throw InferenceError.malformedProtocol("non-object JSON")
            }
        } catch let e as InferenceError {
            throw e
        } catch {
            throw InferenceError.malformedProtocol("malformed JSON: \(error.localizedDescription)")
        }
        throw InferenceError.malformedProtocol("malformed header: \(error.localizedDescription)")
    }

    guard header.protocol == 1 else {
        throw InferenceError.unsupportedProtocol(header.protocol)
    }

    switch header.type {
    case "loading_model":
        do {
            let ev = try decoder.decode(LoadingModelEvent.self, from: data)
            guard ev.protocol == 1 else { throw InferenceError.unsupportedProtocol(ev.protocol) }
            guard ev.type == "loading_model" else { throw InferenceError.unknownEvent(ev.type) }
            return .loadingModel(ev)
        } catch let e as InferenceError { throw e }
        catch { throw InferenceError.malformedProtocol("loading_model: \(error.localizedDescription)") }
    case "ready":
        do {
            let ev = try decoder.decode(ReadyEvent.self, from: data)
            guard ev.protocol == 1 else { throw InferenceError.unsupportedProtocol(ev.protocol) }
            return .ready(ev)
        } catch let e as InferenceError { throw e }
        catch { throw InferenceError.malformedProtocol("ready: \(error.localizedDescription)") }
    case "started":
        do {
            let ev = try decoder.decode(StartedEvent.self, from: data)
            guard ev.protocol == 1 else { throw InferenceError.unsupportedProtocol(ev.protocol) }
            return .started(ev)
        } catch let e as InferenceError { throw e }
        catch { throw InferenceError.malformedProtocol("started: \(error.localizedDescription)") }
    case "stem":
        do {
            let ev = try decoder.decode(StemEvent.self, from: data)
            guard ev.protocol == 1 else { throw InferenceError.unsupportedProtocol(ev.protocol) }
            // StemName validation is via Codable; unknown stem will throw
            return .stem(ev)
        } catch let e as InferenceError { throw e }
        catch {
            // Check if unknown stem
            let msg = error.localizedDescription.lowercased()
            if msg.contains("stemname") || msg.contains("unknown") {
                throw InferenceError.unknownStem(msg)
            }
            throw InferenceError.malformedProtocol("stem: \(error.localizedDescription)")
        }
    case "done":
        do {
            let ev = try decoder.decode(DoneEvent.self, from: data)
            guard ev.protocol == 1 else { throw InferenceError.unsupportedProtocol(ev.protocol) }
            return .done(ev)
        } catch let e as InferenceError { throw e }
        catch { throw InferenceError.malformedProtocol("done: \(error.localizedDescription)") }
    case "error":
        do {
            let ev = try decoder.decode(WorkerErrorEvent.self, from: data)
            guard ev.protocol == 1 else { throw InferenceError.unsupportedProtocol(ev.protocol) }
            return .error(ev)
        } catch let e as InferenceError { throw e }
        catch { throw InferenceError.malformedProtocol("error: \(error.localizedDescription)") }
    default:
        throw InferenceError.unknownEvent(header.type)
    }
}

func decodeEvent(from line: String) throws -> InferenceEvent {
    guard let data = line.data(using: .utf8) else {
        throw InferenceError.malformedProtocol("invalid UTF-8")
    }
    return try decodeEvent(from: data)
}

// MARK: - Helpers for testing: encode events to JSON

extension InferenceEvent {
    func encode() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        switch self {
        case .loadingModel(let e): return try enc.encode(e)
        case .ready(let e): return try enc.encode(e)
        case .started(let e): return try enc.encode(e)
        case .stem(let e): return try enc.encode(e)
        case .done(let e): return try enc.encode(e)
        case .error(let e): return try enc.encode(e)
        }
    }
}
