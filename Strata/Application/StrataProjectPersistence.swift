import Foundation

final class StrataProjectPersistence: @unchecked Sendable {
    let fileManager: FileManager
    let projectsRootOverride: URL?

    init(fileManager: FileManager = .default, projectsRootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.projectsRootOverride = projectsRootOverride
    }

    // MARK: - Roots

    func projectsRootURL() -> URL {
        if let override = projectsRootOverride { return override }
        return StrataProject.projectsRoot(fileManager: fileManager)
    }

    func projectDirectory(for id: String) -> URL {
        projectsRootURL().appendingPathComponent(id, isDirectory: true)
    }

    func projectFileURL(for id: String) -> URL {
        projectDirectory(for: id).appendingPathComponent("project.json", isDirectory: false)
    }

    // MARK: - Directory creation

    func createProjectDirectory(for project: StrataProject) throws {
        // Validate id first
        try StrataProject.validateProjectID(project.id)
        let dir = projectDirectory(for: project.id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let sourceDir = dir.appendingPathComponent("source", isDirectory: true)
        let separationDir = dir.appendingPathComponent("separation", isDirectory: true)
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: separationDir, withIntermediateDirectories: true)
    }

    // MARK: - Save

    func save(_ project: StrataProject) throws {
        // Validate pure aspects
        try project.validate()
        // Containment validation
        let dir = projectDirectory(for: project.id)
        try project.validateContainment(projectDirectory: dir, fileManager: fileManager)

        // Encode with sortedKeys and ISO8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(project)
        } catch {
            throw StrataProjectPersistenceError.writeFailed(error.localizedDescription)
        }
        // Ensure directory exists
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = projectFileURL(for: project.id)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StrataProjectPersistenceError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Load (public canonical path only)

    func load(projectID: String) throws -> StrataProject {
        try StrataProject.validateProjectID(projectID)
        let url = projectFileURL(for: projectID)
        return try loadValidated(from: url)
    }

    // MARK: - Private canonical loader

    private func loadValidated(from url: URL) throws -> StrataProject {
        // Pre-read canonical validation with symlink resolution
        func isInside(_ path: String, root: String) -> Bool {
            return path == root || path.hasPrefix(root + "/")
        }
        let resolvedRootPath = projectsRootURL().standardizedFileURL.resolvingSymlinksInPath().path
        let unresolvedRootPath = projectsRootURL().standardizedFileURL.path
        let resolvedFilePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let unresolvedFilePath = url.standardizedFileURL.path
        let resolvedDirPath = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let unresolvedDirPath = url.deletingLastPathComponent().standardizedFileURL.path

        if !isInside(resolvedDirPath, root: resolvedRootPath) {
            let wasInside = isInside(unresolvedDirPath, root: unresolvedRootPath)
            if wasInside {
                throw StrataProjectError.symlinkEscapesProject(resolvedDirPath)
            } else {
                throw StrataProjectError.pathEscapesProject(resolvedDirPath)
            }
        }
        if !isInside(resolvedFilePath, root: resolvedRootPath) {
            let wasInside = isInside(unresolvedFilePath, root: unresolvedRootPath)
            if wasInside {
                throw StrataProjectError.symlinkEscapesProject(resolvedFilePath)
            } else {
                throw StrataProjectError.pathEscapesProject(resolvedFilePath)
            }
        }

        // Strict canonical-shape validation on resolved URLs (BEFORE I/O)
        let resolvedRootURL = projectsRootURL().standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDirURL = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFileURL = url.standardizedFileURL.resolvingSymlinksInPath()

        func rejectCanonicalShape(_ offending: String) throws -> Never {
            let wasInsideFile = isInside(unresolvedFilePath, root: unresolvedRootPath)
            let wasInsideDir = isInside(unresolvedDirPath, root: unresolvedRootPath)
            let wasInside = wasInsideFile || wasInsideDir
            if wasInside {
                throw StrataProjectError.symlinkEscapesProject(offending)
            } else {
                throw StrataProjectError.pathEscapesProject(offending)
            }
        }

        // Require immediate child: resolvedDir's parent == resolvedRoot
        if resolvedDirURL.deletingLastPathComponent().path != resolvedRootURL.path {
            try rejectCanonicalShape(resolvedFileURL.path)
        }
        // Require dir != root and single component after root (no "/")
        if resolvedDirURL.path == resolvedRootURL.path {
            try rejectCanonicalShape(resolvedFileURL.path)
        } else {
            let prefix = resolvedRootURL.path.hasSuffix("/") ? resolvedRootURL.path : resolvedRootURL.path + "/"
            if !resolvedDirURL.path.hasPrefix(prefix) {
                try rejectCanonicalShape(resolvedFileURL.path)
            } else {
                let relative = String(resolvedDirURL.path.dropFirst(prefix.count))
                if relative.isEmpty || relative.contains("/") {
                    try rejectCanonicalShape(resolvedFileURL.path)
                }
            }
        }
        // Require file name == project.json
        if resolvedFileURL.lastPathComponent != "project.json" {
            try rejectCanonicalShape(resolvedFileURL.path)
        }
        // Require file's parent == dir
        if resolvedFileURL.deletingLastPathComponent().path != resolvedDirURL.path {
            try rejectCanonicalShape(resolvedFileURL.path)
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw StrataProjectPersistenceError.fileNotFound(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StrataProjectPersistenceError.readFailed(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project: StrataProject
        do {
            project = try decoder.decode(StrataProject.self, from: data)
        } catch let e as StrataProjectError {
            throw e
        } catch let e as StrataProjectPersistenceError {
            throw e
        } catch {
            let ns = error as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? StrataProjectError {
                throw underlying
            }
            throw StrataProjectPersistenceError.decodeFailed(error.localizedDescription)
        }
        // Validate again (decode already validated pure aspects, but ensure)
        do {
            try project.validate()
        } catch let e as StrataProjectError {
            throw e
        }
        // Canonical location validation: url must exactly equal projectFileURL(for: project.id) derived from projectsRootURL() — symlink-aware
        let expectedURL = projectFileURL(for: project.id).standardizedFileURL.resolvingSymlinksInPath()
        let actualURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if actualURL.path != expectedURL.path {
            throw StrataProjectError.invalidProjectID(project.id)
        }
        // Also verify that url is within projectsRootURL (symlink-aware)
        let rootPath = resolvedRootPath
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let urlPath = actualURL.path
        let isInsideRoot = (urlPath == rootPath) || urlPath.hasPrefix(rootPrefix)
        if !isInsideRoot {
            throw StrataProjectError.pathEscapesProject(urlPath)
        }
        // Containment: project directory is parent of file URL (symlink-aware)
        let projectDir = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        try project.validateContainment(projectDirectory: projectDir, fileManager: fileManager)
        if projectDir.lastPathComponent != project.id {
            throw StrataProjectError.invalidProjectID(project.id)
        }
        return project
    }

    // MARK: - Test seam (validated)

    /// Test seam — validates canonical location. Only canonical `projectsRoot/<projectID>/project.json` is accepted.
    internal func loadForTesting(from url: URL) throws -> StrataProject {
        try loadValidated(from: url)
    }
}
