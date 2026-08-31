import Foundation

// MARK: - Errors

enum StrataProjectError: Error, Sendable, Equatable, LocalizedError {
    case schemaVersionMismatch(found: Int)
    case invalidProjectID(String)
    case invalidRelativePath(String)
    case pathEscapesProject(String)
    case symlinkEscapesProject(String)
    case invalidGainCount(found: Int)
    case invalidGainNotFinite(stem: String)
    case invalidGainOutOfRange(stem: String, value: Double)
    case missingGains
    case unsupportedPath(String)
    case invalidDisplayTitle(String)
    case invalidSourceLocator(String)

    var errorDescription: String? {
        switch self {
        case .schemaVersionMismatch(let found):
            return "schemaVersion mismatch: expected 1 found \(found)"
        case .invalidProjectID(let id):
            return "invalid project id: \(id)"
        case .invalidRelativePath(let p):
            return "invalid relative path: \(p)"
        case .pathEscapesProject(let p):
            return "path escapes project: \(p)"
        case .symlinkEscapesProject(let p):
            return "symlink escapes project: \(p)"
        case .invalidGainCount(let found):
            return "invalid gain count: expected 6 found \(found)"
        case .invalidGainNotFinite(let stem):
            return "gain not finite for \(stem)"
        case .invalidGainOutOfRange(let stem, let v):
            return "gain out of range for \(stem): \(v)"
        case .missingGains:
            return "missing gains"
        case .unsupportedPath(let p):
            return "unsupported path: \(p)"
        case .invalidDisplayTitle(let t):
            return "invalid displayTitle: \(t)"
        case .invalidSourceLocator(let s):
            return "invalid sourceLocator: \(s)"
        }
    }
}

enum StrataProjectPersistenceError: Error, Sendable, Equatable, LocalizedError {
    case fileNotFound(String)
    case readFailed(String)
    case writeFailed(String)
    case decodeFailed(String)
    case validationFailed(StrataProjectError)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "file not found: \(p)"
        case .readFailed(let m): return "read failed: \(m)"
        case .writeFailed(let m): return "write failed: \(m)"
        case .decodeFailed(let m): return "decode failed: \(m)"
        case .validationFailed(let e): return e.localizedDescription
        }
    }
}

// MARK: - Source Kind

enum StrataProjectSourceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case localFile = "localFile"
    case youTube = "youTube"
}

// MARK: - Source

struct StrataProjectSource: Codable, Sendable, Equatable {
    var kind: StrataProjectSourceKind
    var locator: String
    var metadata: YouTubeTrackMetadata?

    enum CodingKeys: String, CodingKey {
        case kind
        case locator
        case metadata
    }
}

// MARK: - StrataProject

struct StrataProject: Sendable, Equatable {
    var schemaVersion: Int = 1
    var id: String
    var createdAt: Date
    var lastOpenedAt: Date
    var displayTitle: String
    var source: StrataProjectSource
    var canonicalInputPath: String
    var artworkPath: String?
    var inferenceManifestPath: String
    var gains: [StemName: Double]

    // Derived fixed stem paths (not persisted)
    var stemPaths: [StemName: String] {
        StemName.allCases.reduce(into: [:]) { $0[$1] = Self.stemRelativePath(for: $1) }
    }

    // MARK: - Paths constants

    static let mixtureRelativePath = "source/mixture.wav"
    static let manifestRelativePath = "separation/manifest.json"

    static func stemRelativePath(for stem: StemName) -> String {
        "separation/\(stem.rawValue).wav"
    }

    static var allowedExactPaths: Set<String> {
        var s: Set<String> = [mixtureRelativePath, manifestRelativePath]
        for stem in StemName.allCases { s.insert(stemRelativePath(for: stem)) }
        return s
    }

    // MARK: - Projects root helpers

    static func projectsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Strata", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
    }

    static func projectDirectory(for id: String, fileManager: FileManager = .default) -> URL {
        projectsRoot(fileManager: fileManager).appendingPathComponent(id, isDirectory: true)
    }

    static func projectFileURL(for id: String, fileManager: FileManager = .default) -> URL {
        projectDirectory(for: id, fileManager: fileManager).appendingPathComponent("project.json", isDirectory: false)
    }

    static func projectDirectory(for id: String, projectsRootOverride: URL?) -> URL {
        let root = projectsRootOverride ?? projectsRoot()
        return root.appendingPathComponent(id, isDirectory: true)
    }

    static func projectFileURL(for id: String, projectsRootOverride: URL?) -> URL {
        projectDirectory(for: id, projectsRootOverride: projectsRootOverride).appendingPathComponent("project.json", isDirectory: false)
    }

    // MARK: - Init

    init(
        schemaVersion: Int = 1,
        id: String,
        createdAt: Date,
        lastOpenedAt: Date,
        displayTitle: String,
        source: StrataProjectSource,
        canonicalInputPath: String = StrataProject.mixtureRelativePath,
        artworkPath: String? = nil,
        inferenceManifestPath: String = StrataProject.manifestRelativePath,
        gains: [StemName: Double]
    ) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.displayTitle = displayTitle
        self.source = source
        self.canonicalInputPath = canonicalInputPath
        self.artworkPath = artworkPath
        self.inferenceManifestPath = inferenceManifestPath
        self.gains = gains
        try validate()
    }

    // MARK: - Validation

    func validate() throws {
        if schemaVersion != 1 {
            throw StrataProjectError.schemaVersionMismatch(found: schemaVersion)
        }
        try Self.validateProjectID(id)
        try Self.validateRelativePath(canonicalInputPath)
        if canonicalInputPath != Self.mixtureRelativePath {
            throw StrataProjectError.unsupportedPath(canonicalInputPath)
        }
        if let art = artworkPath {
            try Self.validateRelativePath(art)
            try Self.validateArtworkPath(art)
        }
        try Self.validateRelativePath(inferenceManifestPath)
        if inferenceManifestPath != Self.manifestRelativePath {
            throw StrataProjectError.unsupportedPath(inferenceManifestPath)
        }

        if gains.isEmpty {
            throw StrataProjectError.missingGains
        }
        if gains.count != 6 {
            throw StrataProjectError.invalidGainCount(found: gains.count)
        }
        let gainKeySet = Set(gains.keys)
        if gainKeySet != StemName.requiredSet {
            throw StrataProjectError.invalidGainCount(found: gains.count)
        }
        for stem in StemName.allCases {
            guard let v = gains[stem] else {
                throw StrataProjectError.missingGains
            }
            if !v.isFinite {
                throw StrataProjectError.invalidGainNotFinite(stem: stem.rawValue)
            }
            if v < 0.0 || v > 1.0 {
                throw StrataProjectError.invalidGainOutOfRange(stem: stem.rawValue, value: v)
            }
        }

        // Required resume identity: displayTitle non-empty after trimming
        let trimmed = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw StrataProjectError.invalidDisplayTitle(displayTitle)
        }
        // source.locator non-empty no \0
        if source.locator.isEmpty || source.locator.contains("\0") {
            throw StrataProjectError.invalidSourceLocator(source.locator)
        }
        // source.kind validated via enum
    }

    // Validate containment against a resolved project directory
    func validateContainment(projectDirectory: URL, fileManager: FileManager = .default) throws {
        let projectDirResolved = projectDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix: String
        if projectDirResolved.hasSuffix("/") {
            prefix = projectDirResolved
        } else {
            prefix = projectDirResolved + "/"
        }

        func check(_ relative: String) throws {
            if relative.contains("..") {
                let comps = relative.split(separator: "/")
                if comps.contains(where: { $0 == ".." }) {
                    throw StrataProjectError.pathEscapesProject(relative)
                }
                throw StrataProjectError.pathEscapesProject(relative)
            }
            let unresolved = projectDirectory.appendingPathComponent(relative).standardizedFileURL.path
            let resolved = projectDirectory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath().path
            let wasInside = (unresolved == projectDirResolved) || unresolved.hasPrefix(prefix)
            let isInside = (resolved == projectDirResolved) || resolved.hasPrefix(prefix)
            if !isInside {
                if wasInside {
                    throw StrataProjectError.symlinkEscapesProject(relative)
                } else {
                    throw StrataProjectError.pathEscapesProject(relative)
                }
            }
        }

        try check(canonicalInputPath)
        if let art = artworkPath { try check(art) }
        try check(inferenceManifestPath)
        for stem in StemName.allCases {
            try check(Self.stemRelativePath(for: stem))
        }
    }

    // MARK: - Helpers

    static func validateProjectID(_ id: String) throws {
        if id.isEmpty { throw StrataProjectError.invalidProjectID(id) }
        if id.contains("/") || id.contains("\\") || id.contains("\0") {
            throw StrataProjectError.invalidProjectID(id)
        }
        if id != id.lowercased() {
            throw StrataProjectError.invalidProjectID(id)
        }
        guard let uuid = UUID(uuidString: id) else {
            throw StrataProjectError.invalidProjectID(id)
        }
        if uuid.uuidString.lowercased() != id {
            throw StrataProjectError.invalidProjectID(id)
        }
    }

    static func validateRelativePath(_ path: String) throws {
        if path.isEmpty { throw StrataProjectError.invalidRelativePath(path) }
        if path.hasPrefix("/") { throw StrataProjectError.invalidRelativePath(path) }
        if path.contains("\\") { throw StrataProjectError.invalidRelativePath(path) }
        if path.contains("\0") { throw StrataProjectError.invalidRelativePath(path) }
        let comps = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if comps.contains(where: { $0.isEmpty }) {
            throw StrataProjectError.invalidRelativePath(path)
        }
        if comps.contains(where: { $0 == "." || $0 == ".." }) {
            throw StrataProjectError.invalidRelativePath(path)
        }
        let standardized = (path as NSString).standardizingPath
        if standardized != path {
            throw StrataProjectError.invalidRelativePath(path)
        }
        let url = URL(fileURLWithPath: path)
        if url.path != url.standardized.path {
            throw StrataProjectError.invalidRelativePath(path)
        }
        if !isAllowedProjectPath(path) {
            // allow caller to decide unsupported vs invalid; don't throw here for generic
        }
    }

    static func isAllowedProjectPath(_ path: String) -> Bool {
        if path == mixtureRelativePath { return true }
        if path == manifestRelativePath { return true }
        if StemName.allCases.contains(where: { stemRelativePath(for: $0) == path }) { return true }
        if path.hasPrefix("source/artwork.") {
            let ext = String(path.dropFirst("source/artwork.".count))
            if ext.isEmpty { return false }
            if ext.contains("/") || ext.contains("\\") { return false }
            let parts = path.split(separator: "/")
            if parts.count != 2 { return false }
            return true
        }
        return false
    }

    static func validateArtworkPath(_ path: String) throws {
        guard path.hasPrefix("source/artwork.") else {
            throw StrataProjectError.unsupportedPath(path)
        }
        let ext = String(path.dropFirst("source/artwork.".count))
        if ext.isEmpty { throw StrataProjectError.unsupportedPath(path) }
        if ext.contains("/") || ext.contains("\\") { throw StrataProjectError.unsupportedPath(path) }
        if path.split(separator: "/").count != 2 { throw StrataProjectError.unsupportedPath(path) }
    }
}

// MARK: - Codable (v1 canonical keys only)

extension StrataProject: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id = "project_id"
        case createdAt = "created_at"
        case lastOpenedAt = "last_opened_at"
        case displayTitle = "display_title"
        case source = "source"
        case canonicalInputPath = "canonical_input_path"
        case artworkPath = "artwork_path"
        case inferenceManifestPath = "inference_manifest_path"
        case gains = "gains"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sv = try container.decode(Int.self, forKey: .schemaVersion)
        let decodedId = try container.decode(String.self, forKey: .id)
        let ca = try container.decode(Date.self, forKey: .createdAt)
        let la = try container.decode(Date.self, forKey: .lastOpenedAt)
        let dt = try container.decode(String.self, forKey: .displayTitle)
        let src = try container.decode(StrataProjectSource.self, forKey: .source)
        let cInput = try container.decode(String.self, forKey: .canonicalInputPath)
        let art = try container.decodeIfPresent(String.self, forKey: .artworkPath)
        let manifest = try container.decode(String.self, forKey: .inferenceManifestPath)
        let g = try container.decode([StemName: Double].self, forKey: .gains)
        self.schemaVersion = sv
        self.id = decodedId
        self.createdAt = ca
        self.lastOpenedAt = la
        self.displayTitle = dt
        self.source = src
        self.canonicalInputPath = cInput
        self.artworkPath = art
        self.inferenceManifestPath = manifest
        self.gains = g
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encode(displayTitle, forKey: .displayTitle)
        try container.encode(source, forKey: .source)
        try container.encode(canonicalInputPath, forKey: .canonicalInputPath)
        try container.encodeIfPresent(artworkPath, forKey: .artworkPath)
        try container.encode(inferenceManifestPath, forKey: .inferenceManifestPath)
        try container.encode(gains, forKey: .gains)
    }
}
