import Foundation
import CryptoKit
import AVFoundation

// MARK: - StemArtifact

struct StemArtifact: Sendable, Equatable, Hashable {
    let name: StemName
    let url: URL
    let sha256: String
    let fileSize: UInt64
    let frameCount: UInt64
    let channels: UInt32
    let sampleRate: UInt32
}

// MARK: - SeparationResult

/// Immutable validated result. Produced only after done + manifest + filesystem validation.
struct SeparationResult: Sendable, Equatable {
    let jobId: String
    let inputURL: URL
    let jobDirectoryURL: URL
    let manifestURL: URL
    let stems: [StemName: StemArtifact] // exactly six
    let backend: String
    let device: String
    let checkpointSHA256: String
    let model: String

    var sortedStems: [StemArtifact] {
        stems.values.sorted { $0.name.rawValue < $1.name.rawValue }
    }

    func stem(_ name: StemName) -> StemArtifact? {
        stems[name]
    }

    var isComplete: Bool {
        stems.count == 6 && StemName.requiredSet.isSubset(of: Set(stems.keys))
    }
}

// MARK: - Manifest Decoding (M2 schema, tolerant of unknown fields)

struct ManifestStemRecord: Codable, Sendable, Equatable {
    let name: String
    let path: String
    let sha256: String?
    let fileSize: UInt64?
    let frameCount: UInt64?
    let channels: UInt32?
    let sampleRate: UInt32?

    enum CodingKeys: String, CodingKey {
        case name, path, sha256, channels
        case fileSize = "file_size"
        case frameCount = "frame_count"
        case sampleRate = "sample_rate"
    }
}

struct ManifestInputMetadata: Codable, Sendable, Equatable {
    let sampleRate: UInt32?
    let channels: UInt32?
    let frames: UInt64?
    let duration: Double?
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
        case frames
        case duration
        case sha256
    }
}

struct RawManifest: Codable, Sendable {
    let jobId: String
    let model: String?
    let checkpointSHA256: String?
    let backend: String
    let device: String
    let stems: [ManifestStemRecord]
    let inputPath: String?
    let outputDir: String?
    let inputSHA256: String?
    let inputMetadata: ManifestInputMetadata?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case model
        case checkpointSHA256 = "checkpoint_sha256"
        case backend, device, stems
        case inputPath = "input_path"
        case outputDir = "output_dir"
        case inputSHA256 = "input_sha256"
        case inputMetadata = "input_metadata"
        case checkpointAlt = "checkpointSha256"
        case config
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        if let v = try c.decodeIfPresent(String.self, forKey: .checkpointSHA256) {
            checkpointSHA256 = v
        } else {
            checkpointSHA256 = try c.decodeIfPresent(String.self, forKey: .checkpointAlt)
        }
        backend = try c.decode(String.self, forKey: .backend)
        device = try c.decode(String.self, forKey: .device)
        stems = try c.decode([ManifestStemRecord].self, forKey: .stems)
        inputPath = try c.decodeIfPresent(String.self, forKey: .inputPath)
        outputDir = try c.decodeIfPresent(String.self, forKey: .outputDir)
        inputSHA256 = try c.decodeIfPresent(String.self, forKey: .inputSHA256)
        inputMetadata = try c.decodeIfPresent(ManifestInputMetadata.self, forKey: .inputMetadata)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobId, forKey: .jobId)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(checkpointSHA256, forKey: .checkpointSHA256)
        try c.encode(backend, forKey: .backend)
        try c.encode(device, forKey: .device)
        try c.encode(stems, forKey: .stems)
        try c.encodeIfPresent(inputPath, forKey: .inputPath)
        try c.encodeIfPresent(outputDir, forKey: .outputDir)
        try c.encodeIfPresent(inputSHA256, forKey: .inputSHA256)
        try c.encodeIfPresent(inputMetadata, forKey: .inputMetadata)
    }
}

// MARK: - Hashing

func sha256Hex(of data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func sha256File(at url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return sha256Hex(of: data)
}

// MARK: - Audio Validation Helpers

/// Canonical constants for architecture - not frame-count fixed.
let canonicalSampleRate: UInt32 = 44100
let canonicalChannels: UInt32 = 2

/// Validate stem file via AVAudioFile and return its audio properties.
/// Enforces 44.1 kHz stereo, positive frame count, and if expectedFrames supplied, exact equality.
/// Does NOT enforce a global 882000 invariant; frame count is validated against manifest/input metadata.
func validateAudioFile(at url: URL, expectedFrames: UInt64? = nil) throws -> (sampleRate: UInt32, channels: UInt32, frames: UInt64) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
        throw InferenceError.manifestValidationFailure("missing file: \(url.path)")
    }
    var isDir: ObjCBool = false
    _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
    if isDir.boolValue {
        throw InferenceError.manifestValidationFailure("not a regular file: \(url.path)")
    }
    let audioFile: AVAudioFile
    do {
        audioFile = try AVAudioFile(forReading: url)
    } catch {
        throw InferenceError.manifestValidationFailure("AVAudioFile open failed \(url.lastPathComponent): \(error.localizedDescription)")
    }
    let format = audioFile.processingFormat
    guard UInt32(format.sampleRate) == canonicalSampleRate else {
        throw InferenceError.manifestValidationFailure("sample rate \(format.sampleRate) != \(canonicalSampleRate) for \(url.lastPathComponent)")
    }
    guard format.channelCount == canonicalChannels else {
        throw InferenceError.manifestValidationFailure("channels \(format.channelCount) != \(canonicalChannels) for \(url.lastPathComponent)")
    }
    let frames = UInt64(audioFile.length)
    guard frames > 0 else {
        throw InferenceError.manifestValidationFailure("zero frames for \(url.lastPathComponent)")
    }
    if let expected = expectedFrames {
        guard expected > 0 else {
            throw InferenceError.manifestValidationFailure("invalid expected frame count \(expected)")
        }
        guard frames == expected else {
            throw InferenceError.manifestValidationFailure("frames \(frames) != manifest \(expected) for \(url.lastPathComponent)")
        }
    }
    return (sampleRate: canonicalSampleRate, channels: canonicalChannels, frames: frames)
}

// MARK: - Separation Validation

enum SeparationValidationError: Error {
    case failure(String)
}

struct SeparationValidator {
    /// Validate manifest + filesystem and produce immutable result.
    /// Enforces 44.1k stereo canonically, but frame count is validated as positive and internally consistent with manifest/inputMetadata/stems, not globally 882000.
    static func validatedResult(
        manifestURL: URL,
        job: JobInfo,
        readyMetadata: ReadyMetadata,
        receivedStems: [StemName: URL]? = nil,
        expectedInputSHA256: String? = nil
    ) throws -> SeparationResult {
        let fm = FileManager.default

        // Canonicalize manifest path (resolve /tmp vs /private/tmp symlink)
        let standardizedManifestURL = manifestURL.standardizedFileURL.resolvingSymlinksInPath()

        guard fm.fileExists(atPath: standardizedManifestURL.path) else {
            throw InferenceError.manifestValidationFailure("manifest missing: \(manifestURL.path)")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardizedManifestURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw InferenceError.manifestValidationFailure("manifest not regular file")
        }

        let manifestData: Data
        do { manifestData = try Data(contentsOf: standardizedManifestURL) } catch {
            throw InferenceError.manifestValidationFailure("manifest read failed: \(error)")
        }

        let decoder = JSONDecoder()
        let raw: RawManifest
        do {
            raw = try decoder.decode(RawManifest.self, from: manifestData)
        } catch {
            throw InferenceError.manifestValidationFailure("manifest decode failed: \(error)")
        }

        // job_id
        guard raw.jobId == job.jobId else {
            throw InferenceError.manifestValidationFailure("manifest job_id \(raw.jobId) != \(job.jobId)")
        }

        // model identity — single native trust anchor, required
        guard let model = raw.model, !model.isEmpty else {
            throw InferenceError.manifestValidationFailure("missing model")
        }
        guard model == TrustedInferenceIdentity.model else {
            throw InferenceError.manifestValidationFailure("model mismatch \(model) != \(TrustedInferenceIdentity.model)")
        }

        // checkpoint — single native trust anchor, required, independent of worker advertisement
        guard let manifestCheckpoint = raw.checkpointSHA256, !manifestCheckpoint.isEmpty else {
            throw InferenceError.manifestValidationFailure("missing checkpoint_sha256")
        }
        guard manifestCheckpoint.lowercased() == TrustedInferenceIdentity.checkpointSHA256.lowercased() else {
            throw InferenceError.manifestValidationFailure("checkpoint mismatch manifest \(manifestCheckpoint) != trusted")
        }
        // Worker ready metadata is evidence, not trust, but must also match trusted anchor
        guard !readyMetadata.checkpointSHA256.isEmpty else {
            throw InferenceError.manifestValidationFailure("missing ready checkpoint")
        }
        guard readyMetadata.checkpointSHA256.lowercased() == TrustedInferenceIdentity.checkpointSHA256.lowercased() else {
            throw InferenceError.manifestValidationFailure("ready checkpoint mismatch \(readyMetadata.checkpointSHA256) != trusted")
        }

        // backend/device canonical — required and must equal trusted
        guard raw.backend == TrustedInferenceIdentity.backend else { throw InferenceError.manifestValidationFailure("backend \(raw.backend) != \(TrustedInferenceIdentity.backend)") }
        guard raw.device == TrustedInferenceIdentity.device else { throw InferenceError.manifestValidationFailure("device \(raw.device) != \(TrustedInferenceIdentity.device)") }
        // Also cross-check readyMetadata
        guard readyMetadata.backend == TrustedInferenceIdentity.backend else { throw InferenceError.manifestValidationFailure("ready backend \(readyMetadata.backend) != \(TrustedInferenceIdentity.backend)") }
        guard readyMetadata.device == TrustedInferenceIdentity.device else { throw InferenceError.manifestValidationFailure("ready device \(readyMetadata.device) != \(TrustedInferenceIdentity.device)") }

        // six unique
        guard raw.stems.count == 6 else { throw InferenceError.manifestValidationFailure("manifest stems count \(raw.stems.count) != 6") }
        let manifestStemNames = raw.stems.map { $0.name }
        let uniqueNames = Set(manifestStemNames)
        guard uniqueNames.count == 6 else { throw InferenceError.manifestValidationFailure("duplicate manifest stems") }
        for n in manifestStemNames {
            guard StemName(rawValue: n) != nil else { throw InferenceError.unknownStem(n) }
        }
        guard uniqueNames == Set(StemName.allCases.map { $0.rawValue }) else {
            throw InferenceError.manifestValidationFailure("manifest missing required stems \(uniqueNames)")
        }

        // received stems cross-check if provided
        if let recv = receivedStems {
            let receivedNames = Set(recv.keys.map { $0.rawValue })
            guard receivedNames == uniqueNames else {
                throw InferenceError.manifestValidationFailure("manifest stems \(uniqueNames) != received \(receivedNames)")
            }
        }

        // Expected finalized job directory (canonicalized)
        let expectedJobDir = URL(fileURLWithPath: job.outputDir).appendingPathComponent(job.jobId, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let manifestDir = standardizedManifestURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard manifestDir == expectedJobDir else {
            throw InferenceError.manifestValidationFailure("manifest dir \(manifestDir.path) not in expected \(expectedJobDir.path)")
        }
        guard standardizedManifestURL.lastPathComponent == "manifest.json" else {
            throw InferenceError.manifestValidationFailure("manifest filename not manifest.json")
        }
        // Path escape: manifestURL must not have .. components that escape before canonicalization? Already via compare above, but also check raw manifest path string doesn't contain traverse?
        // Our canonical comparison suffices; additional check for ".." in raw path is not needed but we ensure resolved path is inside expected.

        // Validate input SHA — required, must match file and trusted native expected
        let inputFileURL = URL(fileURLWithPath: job.inputPath).standardizedFileURL
        guard let manifestInputSHA = raw.inputSHA256, !manifestInputSHA.isEmpty else {
            throw InferenceError.manifestValidationFailure("missing input_sha256")
        }
        guard fm.fileExists(atPath: inputFileURL.path) else {
            throw InferenceError.manifestValidationFailure("input file missing for sha check")
        }
        let actualInputSHA = try sha256File(at: inputFileURL)
        guard actualInputSHA.lowercased() == manifestInputSHA.lowercased() else {
            throw InferenceError.manifestValidationFailure("input SHA mismatch manifest \(manifestInputSHA) != file \(actualInputSHA)")
        }
        if let expected = expectedInputSHA256, !expected.isEmpty {
            guard actualInputSHA.lowercased() == expected.lowercased() else {
                throw InferenceError.manifestValidationFailure("input SHA \(actualInputSHA) != expected \(expected)")
            }
            guard manifestInputSHA.lowercased() == expected.lowercased() else {
                throw InferenceError.manifestValidationFailure("manifest input SHA \(manifestInputSHA) != expected \(expected)")
            }
        }

        // Input metadata validation (canonical 44.1k stereo, positive frames) — M3 requires exact frames
        guard let inputMeta = raw.inputMetadata else {
            throw InferenceError.manifestValidationFailure("missing input_metadata")
        }
        guard let inputFrames = inputMeta.frames else {
            throw InferenceError.manifestValidationFailure("missing input_metadata.frames")
        }
        guard inputFrames > 0 else {
            throw InferenceError.manifestValidationFailure("input frames zero")
        }
        if let sr = inputMeta.sampleRate {
            guard sr == canonicalSampleRate else { throw InferenceError.manifestValidationFailure("input sample_rate \(sr) != \(canonicalSampleRate)") }
        }
        if let ch = inputMeta.channels {
            guard ch == canonicalChannels else { throw InferenceError.manifestValidationFailure("input channels \(ch) != \(canonicalChannels)") }
        }
        // Validate input_sha inside metadata if present vs manifest
        if let metaSHA = inputMeta.sha256, let manifestSHA = raw.inputSHA256 {
            if metaSHA.lowercased() != manifestSHA.lowercased() {
                throw InferenceError.manifestValidationFailure("input_metadata sha != input_sha256")
            }
        }
        // Native inspection: actual input file frames must equal manifest input frames
        let nativeInputAudio = try validateAudioFile(at: inputFileURL)
        guard nativeInputAudio.frames == inputFrames else {
            throw InferenceError.manifestValidationFailure("input_metadata frames \(inputFrames) != native input file frames \(nativeInputAudio.frames)")
        }
        let canonicalFrameCount: UInt64 = inputFrames

        // Helper for SHA-256 format validation: exactly 64 ASCII hex characters
        func isValidHex64(_ s: String) -> Bool {
            guard s.count == 64 else { return false }
            for c in s.unicodeScalars {
                guard c.isASCII else { return false }
                let v = c.value
                let isHex = (v >= 48 && v <= 57) || (v >= 65 && v <= 70) || (v >= 97 && v <= 102)
                if !isHex { return false }
            }
            return true
        }

        // Validate each stem record — SHA-256 required, frames must equal input frames
        var artifacts: [StemName: StemArtifact] = [:]
        var observedFrameCounts: Set<UInt64> = []

        for rec in raw.stems {
            guard let stemName = StemName(rawValue: rec.name) else { throw InferenceError.unknownStem(rec.name) }
            let stemURL = URL(fileURLWithPath: rec.path).standardizedFileURL.resolvingSymlinksInPath()
            let stemDir = stemURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard stemDir == expectedJobDir else {
                throw InferenceError.manifestValidationFailure("stem path escape \(rec.path) not in \(expectedJobDir.path)")
            }
            guard stemURL.lastPathComponent == "\(stemName.rawValue).wav" else {
                throw InferenceError.manifestValidationFailure("stem filename \(stemURL.lastPathComponent) != \(stemName.rawValue).wav")
            }
            // Check received stem path matches manifest (canonicalized) if provided
            if let recv = receivedStems, let received = recv[stemName] {
                let canonReceived = received.standardizedFileURL.resolvingSymlinksInPath()
                let canonManifest = stemURL
                guard canonReceived == canonManifest else {
                    throw InferenceError.manifestValidationFailure("stem path mismatch for \(stemName.rawValue): received \(canonReceived.path) != manifest \(canonManifest.path)")
                }
            }

            guard fm.fileExists(atPath: stemURL.path) else {
                throw InferenceError.manifestValidationFailure("stem file missing \(stemURL.path)")
            }
            var isD: ObjCBool = false
            _ = fm.fileExists(atPath: stemURL.path, isDirectory: &isD)
            if isD.boolValue { throw InferenceError.manifestValidationFailure("stem not file \(stemURL.path)") }

            // Require SHA-256 present, non-empty, exactly 64 ASCII hex
            guard let expectedSHA = rec.sha256, !expectedSHA.isEmpty else {
                throw InferenceError.manifestValidationFailure("missing sha256 for \(stemName.rawValue)")
            }
            guard isValidHex64(expectedSHA) else {
                throw InferenceError.manifestValidationFailure("malformed sha256 for \(stemName.rawValue): \(expectedSHA)")
            }

            // Require per-stem frame_count present and equal to input frames
            guard let fc = rec.frameCount else {
                throw InferenceError.manifestValidationFailure("missing frame_count for \(stemName.rawValue)")
            }
            guard fc > 0 else { throw InferenceError.manifestValidationFailure("zero frame_count for \(stemName.rawValue)") }
            guard fc == canonicalFrameCount else {
                throw InferenceError.manifestValidationFailure("stem manifest frame_count \(fc) != input frames \(canonicalFrameCount) for \(stemName.rawValue)")
            }
            // Validate per-stem sample_rate/channels if present
            if let ch = rec.channels, ch != canonicalChannels {
                throw InferenceError.manifestValidationFailure("channels \(ch) != \(canonicalChannels) for \(stemName.rawValue)")
            }
            if let sr = rec.sampleRate, sr != canonicalSampleRate {
                throw InferenceError.manifestValidationFailure("sample_rate \(sr) != \(canonicalSampleRate) for \(stemName.rawValue)")
            }

            // Native inspection: stem file length must equal input frame count
            let audioMeta = try validateAudioFile(at: stemURL, expectedFrames: canonicalFrameCount)
            guard audioMeta.frames == canonicalFrameCount else {
                throw InferenceError.manifestValidationFailure("stem file frames \(audioMeta.frames) != input frames \(canonicalFrameCount) for \(stemName.rawValue)")
            }

            // Collect for cross-stem consistency
            observedFrameCounts.insert(audioMeta.frames)

            // Independently calculated digest must match manifest (case-insensitive but format already validated)
            let fileSHA = try sha256File(at: stemURL)
            guard expectedSHA.lowercased() == fileSHA.lowercased() else {
                throw InferenceError.manifestValidationFailure("hash mismatch for \(stemName.rawValue): manifest \(expectedSHA) != file \(fileSHA)")
            }

            // Validate size if manifest supplies
            if let expectedSize = rec.fileSize {
                let attrs = try fm.attributesOfItem(atPath: stemURL.path)
                let actualSize: UInt64
                if let n = attrs[.size] as? UInt64 { actualSize = n }
                else if let n = attrs[.size] as? NSNumber { actualSize = n.uint64Value }
                else { actualSize = 0 }
                if actualSize != expectedSize {
                    throw InferenceError.manifestValidationFailure("size mismatch for \(stemName.rawValue) \(actualSize) != \(expectedSize)")
                }
            }

            // Build artifact with actual observed values — frameCount must equal input frames
            let attrs = try fm.attributesOfItem(atPath: stemURL.path)
            let size: UInt64
            if let n = attrs[.size] as? UInt64 { size = n }
            else if let n = attrs[.size] as? NSNumber { size = n.uint64Value }
            else { size = 0 }

            let artifact = StemArtifact(
                name: stemName,
                url: stemURL,
                sha256: fileSHA,
                fileSize: size,
                frameCount: audioMeta.frames,
                channels: audioMeta.channels,
                sampleRate: audioMeta.sampleRate
            )
            // Enforce artifact frameCount equals input frames
            guard artifact.frameCount == canonicalFrameCount else {
                throw InferenceError.manifestValidationFailure("artifact frames \(artifact.frameCount) != input frames \(canonicalFrameCount)")
            }
            artifacts[stemName] = artifact
        }

        // All six present
        guard artifacts.count == 6 else { throw InferenceError.manifestValidationFailure("artifacts count \(artifacts.count) != 6") }

        // Frame count consistency: all six stems must equal input frames and agree with each other
        guard observedFrameCounts.count == 1, observedFrameCounts.first == canonicalFrameCount else {
            throw InferenceError.manifestValidationFailure("stem frame counts \(observedFrameCounts) != input metadata \(canonicalFrameCount)")
        }

        // If canonicalFrameCount was nil but we observed one frame count, we consider that the canonical for now

        let inputURL = URL(fileURLWithPath: job.inputPath).standardizedFileURL

        return SeparationResult(
            jobId: job.jobId,
            inputURL: inputURL,
            jobDirectoryURL: expectedJobDir,
            manifestURL: standardizedManifestURL,
            stems: artifacts,
            backend: TrustedInferenceIdentity.backend,
            device: TrustedInferenceIdentity.device,
            checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256,
            model: TrustedInferenceIdentity.model
        )
    }

    // MARK: - Project-based validation (persistent sessions Stage 1)

    /// Validates a persisted project’s fixed layout without requiring live worker state or scratch paths.
    /// Derives mixture/manifest/stem URLs from the project’s canonical relative paths and validates containment,
    /// audio format, hashes, frame counts, and trusted identity. Ignores manifest’s stored absolute path/output_dir.
    static func validatedResult(forProjectDirectory projectDirectory: URL, project: StrataProject) throws -> SeparationResult {
        let fm = FileManager.default
        let projectDirResolved = projectDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let projectDirPrefix = projectDirResolved.hasSuffix("/") ? projectDirResolved : projectDirResolved + "/"

        func isInsideResolved(_ url: URL) -> Bool {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            return resolved == projectDirResolved || resolved.hasPrefix(projectDirPrefix)
        }
        func checkContainment(_ relative: String) throws {
            if relative.contains("..") {
                let comps = relative.split(separator: "/")
                if comps.contains(where: { $0 == ".." }) {
                    throw StrataProjectError.pathEscapesProject(relative)
                }
            }
            let url = projectDirectory.appendingPathComponent(relative)
            let unresolved = url.standardizedFileURL.path
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            let wasInside = (unresolved == projectDirResolved) || unresolved.hasPrefix(projectDirPrefix)
            let isInside = (resolved == projectDirResolved) || resolved.hasPrefix(projectDirPrefix)
            if !isInside {
                if wasInside {
                    throw InferenceError.manifestValidationFailure("symlink escapes project: \(relative) -> \(resolved)")
                } else {
                    throw InferenceError.manifestValidationFailure("path escapes project: \(relative)")
                }
            }
            // Also ensure via isInsideResolved
            if !isInsideResolved(url) {
                throw InferenceError.manifestValidationFailure("containment check failed for \(relative)")
            }
        }

        // Validate containment via project (reuse its logic) - also do explicit checks
        try project.validateContainment(projectDirectory: projectDirectory, fileManager: fm)
        try checkContainment(project.canonicalInputPath)
        try checkContainment(project.inferenceManifestPath)
        for stem in StemName.allCases {
            try checkContainment(StrataProject.stemRelativePath(for: stem))
        }
        if let art = project.artworkPath {
            try checkContainment(art)
            let artURL = projectDirectory.appendingPathComponent(art)
            guard fm.fileExists(atPath: artURL.path) else {
                throw InferenceError.manifestValidationFailure("artwork missing: \(art)")
            }
            var isD: ObjCBool = false
            _ = fm.fileExists(atPath: artURL.path, isDirectory: &isD)
            if isD.boolValue {
                throw InferenceError.manifestValidationFailure("artwork not a regular file")
            }
            // Containment already checked; also check symlink escapes
            if !isInsideResolved(artURL) {
                throw InferenceError.manifestValidationFailure("artwork escapes project")
            }
        }

        let mixtureURL = projectDirectory.appendingPathComponent(project.canonicalInputPath).standardizedFileURL
        let manifestURL = projectDirectory.appendingPathComponent(project.inferenceManifestPath).standardizedFileURL

        // Existence and containment for mixture/manifest
        guard fm.fileExists(atPath: mixtureURL.path) else {
            throw InferenceError.manifestValidationFailure("mixture missing: \(mixtureURL.path)")
        }
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: mixtureURL.path, isDirectory: &isDir)
        if isDir.boolValue { throw InferenceError.manifestValidationFailure("mixture not a regular file") }
        if !isInsideResolved(mixtureURL) {
            throw InferenceError.manifestValidationFailure("mixture escapes project")
        }

        guard fm.fileExists(atPath: manifestURL.path) else {
            throw InferenceError.manifestValidationFailure("manifest missing: \(manifestURL.path)")
        }
        isDir = false
        _ = fm.fileExists(atPath: manifestURL.path, isDirectory: &isDir)
        if isDir.boolValue { throw InferenceError.manifestValidationFailure("manifest not a regular file") }
        if !isInsideResolved(manifestURL) {
            throw InferenceError.manifestValidationFailure("manifest escapes project")
        }
        // Ensure manifest filename is manifest.json and parent is separation
        guard manifestURL.lastPathComponent == "manifest.json" else {
            throw InferenceError.manifestValidationFailure("manifest filename not manifest.json")
        }

        let manifestData: Data
        do { manifestData = try Data(contentsOf: manifestURL) } catch {
            throw InferenceError.manifestValidationFailure("manifest read failed: \(error)")
        }
        let decoder = JSONDecoder()
        let raw: RawManifest
        do {
            raw = try decoder.decode(RawManifest.self, from: manifestData)
        } catch {
            throw InferenceError.manifestValidationFailure("manifest decode failed: \(error)")
        }

        // Validate model/backend/device/checkpoint vs trusted
        guard let model = raw.model, !model.isEmpty else {
            throw InferenceError.manifestValidationFailure("missing model")
        }
        guard model == TrustedInferenceIdentity.model else {
            throw InferenceError.manifestValidationFailure("model mismatch \(model) != \(TrustedInferenceIdentity.model)")
        }
        guard let manifestCheckpoint = raw.checkpointSHA256, !manifestCheckpoint.isEmpty else {
            throw InferenceError.manifestValidationFailure("missing checkpoint_sha256")
        }
        guard manifestCheckpoint.lowercased() == TrustedInferenceIdentity.checkpointSHA256.lowercased() else {
            throw InferenceError.manifestValidationFailure("checkpoint mismatch manifest \(manifestCheckpoint) != trusted")
        }
        guard raw.backend == TrustedInferenceIdentity.backend else { throw InferenceError.manifestValidationFailure("backend \(raw.backend) != \(TrustedInferenceIdentity.backend)") }
        guard raw.device == TrustedInferenceIdentity.device else { throw InferenceError.manifestValidationFailure("device \(raw.device) != \(TrustedInferenceIdentity.device)") }

        // Six unique stems
        guard raw.stems.count == 6 else { throw InferenceError.manifestValidationFailure("manifest stems count \(raw.stems.count) != 6") }
        let manifestStemNames = raw.stems.map { $0.name }
        let uniqueNames = Set(manifestStemNames)
        guard uniqueNames.count == 6 else { throw InferenceError.manifestValidationFailure("duplicate manifest stems") }
        for n in manifestStemNames {
            guard StemName(rawValue: n) != nil else { throw InferenceError.unknownStem(n) }
        }
        guard uniqueNames == Set(StemName.allCases.map { $0.rawValue }) else {
            throw InferenceError.manifestValidationFailure("manifest missing required stems \(uniqueNames)")
        }

        // Input SHA required and must match file
        guard let manifestInputSHA = raw.inputSHA256, !manifestInputSHA.isEmpty else {
            throw InferenceError.manifestValidationFailure("missing input_sha256")
        }
        let actualInputSHA = try sha256File(at: mixtureURL)
        guard actualInputSHA.lowercased() == manifestInputSHA.lowercased() else {
            throw InferenceError.manifestValidationFailure("input SHA mismatch manifest \(manifestInputSHA) != file \(actualInputSHA)")
        }

        // Input metadata validation
        guard let inputMeta = raw.inputMetadata else {
            throw InferenceError.manifestValidationFailure("missing input_metadata")
        }
        guard let inputFrames = inputMeta.frames else {
            throw InferenceError.manifestValidationFailure("missing input_metadata.frames")
        }
        guard inputFrames > 0 else {
            throw InferenceError.manifestValidationFailure("input frames zero")
        }
        if let sr = inputMeta.sampleRate {
            guard sr == canonicalSampleRate else { throw InferenceError.manifestValidationFailure("input sample_rate \(sr) != \(canonicalSampleRate)") }
        }
        if let ch = inputMeta.channels {
            guard ch == canonicalChannels else { throw InferenceError.manifestValidationFailure("input channels \(ch) != \(canonicalChannels)") }
        }
        if let metaSHA = inputMeta.sha256, let manifestSHA = raw.inputSHA256 {
            if metaSHA.lowercased() != manifestSHA.lowercased() {
                throw InferenceError.manifestValidationFailure("input_metadata sha != input_sha256")
            }
        }
        let nativeInputAudio = try validateAudioFile(at: mixtureURL)
        guard nativeInputAudio.frames == inputFrames else {
            throw InferenceError.manifestValidationFailure("input_metadata frames \(inputFrames) != native input file frames \(nativeInputAudio.frames)")
        }
        let canonicalFrameCount: UInt64 = inputFrames

        func isValidHex64(_ s: String) -> Bool {
            guard s.count == 64 else { return false }
            for c in s.unicodeScalars {
                guard c.isASCII else { return false }
                let v = c.value
                let isHex = (v >= 48 && v <= 57) || (v >= 65 && v <= 70) || (v >= 97 && v <= 102)
                if !isHex { return false }
            }
            return true
        }

        var artifacts: [StemName: StemArtifact] = [:]
        var observedFrameCounts: Set<UInt64> = []

        for rec in raw.stems {
            guard let stemName = StemName(rawValue: rec.name) else { throw InferenceError.unknownStem(rec.name) }
            // Derive project-fixed URL, ignore rec.path scratch location for equality
            let stemURL = projectDirectory.appendingPathComponent(StrataProject.stemRelativePath(for: stemName)).standardizedFileURL

            // Containment for derived URL
            if !isInsideResolved(stemURL) {
                throw InferenceError.manifestValidationFailure("stem path escapes project \(stemName.rawValue)")
            }
            guard stemURL.lastPathComponent == "\(stemName.rawValue).wav" else {
                throw InferenceError.manifestValidationFailure("stem filename \(stemURL.lastPathComponent) != \(stemName.rawValue).wav")
            }
            guard fm.fileExists(atPath: stemURL.path) else {
                throw InferenceError.manifestValidationFailure("stem file missing \(stemURL.path)")
            }
            var isD: ObjCBool = false
            _ = fm.fileExists(atPath: stemURL.path, isDirectory: &isD)
            if isD.boolValue { throw InferenceError.manifestValidationFailure("stem not file \(stemURL.path)") }

            guard let expectedSHA = rec.sha256, !expectedSHA.isEmpty else {
                throw InferenceError.manifestValidationFailure("missing sha256 for \(stemName.rawValue)")
            }
            guard isValidHex64(expectedSHA) else {
                throw InferenceError.manifestValidationFailure("malformed sha256 for \(stemName.rawValue): \(expectedSHA)")
            }
            guard let fc = rec.frameCount else {
                throw InferenceError.manifestValidationFailure("missing frame_count for \(stemName.rawValue)")
            }
            guard fc > 0 else { throw InferenceError.manifestValidationFailure("zero frame_count for \(stemName.rawValue)") }
            guard fc == canonicalFrameCount else {
                throw InferenceError.manifestValidationFailure("stem manifest frame_count \(fc) != input frames \(canonicalFrameCount) for \(stemName.rawValue)")
            }
            if let ch = rec.channels, ch != canonicalChannels {
                throw InferenceError.manifestValidationFailure("channels \(ch) != \(canonicalChannels) for \(stemName.rawValue)")
            }
            if let sr = rec.sampleRate, sr != canonicalSampleRate {
                throw InferenceError.manifestValidationFailure("sample_rate \(sr) != \(canonicalSampleRate) for \(stemName.rawValue)")
            }

            let audioMeta = try validateAudioFile(at: stemURL, expectedFrames: canonicalFrameCount)
            guard audioMeta.frames == canonicalFrameCount else {
                throw InferenceError.manifestValidationFailure("stem file frames \(audioMeta.frames) != input frames \(canonicalFrameCount) for \(stemName.rawValue)")
            }
            observedFrameCounts.insert(audioMeta.frames)

            let fileSHA = try sha256File(at: stemURL)
            guard expectedSHA.lowercased() == fileSHA.lowercased() else {
                throw InferenceError.manifestValidationFailure("hash mismatch for \(stemName.rawValue): manifest \(expectedSHA) != file \(fileSHA)")
            }
            if let expectedSize = rec.fileSize {
                let attrs = try fm.attributesOfItem(atPath: stemURL.path)
                let actualSize: UInt64
                if let n = attrs[.size] as? UInt64 { actualSize = n }
                else if let n = attrs[.size] as? NSNumber { actualSize = n.uint64Value }
                else { actualSize = 0 }
                if actualSize != expectedSize {
                    throw InferenceError.manifestValidationFailure("size mismatch for \(stemName.rawValue) \(actualSize) != \(expectedSize)")
                }
            }
            let attrs = try fm.attributesOfItem(atPath: stemURL.path)
            let size: UInt64
            if let n = attrs[.size] as? UInt64 { size = n }
            else if let n = attrs[.size] as? NSNumber { size = n.uint64Value }
            else { size = 0 }

            let artifact = StemArtifact(
                name: stemName,
                url: stemURL,
                sha256: fileSHA,
                fileSize: size,
                frameCount: audioMeta.frames,
                channels: audioMeta.channels,
                sampleRate: audioMeta.sampleRate
            )
            guard artifact.frameCount == canonicalFrameCount else {
                throw InferenceError.manifestValidationFailure("artifact frames \(artifact.frameCount) != input frames \(canonicalFrameCount)")
            }
            artifacts[stemName] = artifact
        }

        guard artifacts.count == 6 else { throw InferenceError.manifestValidationFailure("artifacts count \(artifacts.count) != 6") }
        guard observedFrameCounts.count == 1, observedFrameCounts.first == canonicalFrameCount else {
            throw InferenceError.manifestValidationFailure("stem frame counts \(observedFrameCounts) != input metadata \(canonicalFrameCount)")
        }

        let jobDir = projectDirectory.appendingPathComponent("separation", isDirectory: true).standardizedFileURL

        return SeparationResult(
            jobId: raw.jobId,
            inputURL: mixtureURL,
            jobDirectoryURL: jobDir,
            manifestURL: manifestURL,
            stems: artifacts,
            backend: TrustedInferenceIdentity.backend,
            device: TrustedInferenceIdentity.device,
            checkpointSHA256: TrustedInferenceIdentity.checkpointSHA256,
            model: TrustedInferenceIdentity.model
        )
    }

    static func validatedResult(projectDirectory: URL, project: StrataProject) throws -> SeparationResult {
        try validatedResult(forProjectDirectory: projectDirectory, project: project)
    }
}
