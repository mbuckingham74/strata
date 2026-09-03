import AppKit
import Foundation

// MARK: - StorageLocationPreferences (single small helper, not a generalized framework)
//
// Persists Library / Scratch / Export roots as plain path strings in UserDefaults.
// Security-scoped bookmarks are NOT required for Library/Scratch because the app
// is not sandboxed (com.apple.security.app-sandbox is absent; only
// ENABLE_USER_SCRIPT_SANDBOXING=YES). Export keeps legacy bookmark support for
// backward compat but also stores a plain string for future; resolution prefers the
// bookmark when present and valid, otherwise the string, otherwise the default.
// Missing / non-directory stored paths are discarded gracefully and fall back to
// defaults (no crash).

final class StorageLocationPreferences: @unchecked Sendable {

    // Keys – strings intentionally match task spec.
    static let libraryPathKey = "libraryDirectoryPath"
    static let scratchPathKey = "scratchDirectoryPath"
    static let exportPathKey = "exportDirectoryPath"
    static let bookmarkKey = "defaultExportDirectoryBookmark"

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    // MARK: - Defaults (fall back to homeDirectory if FileManager.urls returns nil)

    var defaultLibraryURL: URL {
        let base = musicBase
        return base.appendingPathComponent("Strata/Library", isDirectory: true).standardizedFileURL
    }

    var defaultExportURL: URL {
        let base = musicBase
        return base.appendingPathComponent("Strata/Exports", isDirectory: true).standardizedFileURL
    }

    var defaultScratchRootURL: URL {
        let base = cachesBase
        return base.appendingPathComponent("Strata", isDirectory: true).standardizedFileURL
    }

    // Derived scratch subpaths (do not create directories here)
    func separationOutputBaseURL() -> URL {
        resolvedScratchRootURL().appendingPathComponent("M3Separations", isDirectory: true).standardizedFileURL
    }

    func youtubeIngestCacheBaseURL() -> URL {
        resolvedScratchRootURL().appendingPathComponent("M4Ingest", isDirectory: true).standardizedFileURL
    }

    func localIngestCacheBaseURL() -> URL {
        resolvedScratchRootURL().appendingPathComponent("LocalIngest", isDirectory: true).standardizedFileURL
    }

    // MARK: - Resolution

    func resolvedLibraryURL() -> URL {
        resolveStringKey(Self.libraryPathKey, fallback: defaultLibraryURL)
    }

    func resolvedScratchRootURL() -> URL {
        resolveStringKey(Self.scratchPathKey, fallback: defaultScratchRootURL)
    }

    func resolvedExportURL() -> URL {
        // Prefer legacy bookmark when present and valid.
        if let access = resolvedExportDirectoryAccess() {
            return access.url.standardizedFileURL
        }
        return resolveStringKey(Self.exportPathKey, fallback: defaultExportURL)
    }

    /// Returns a security-scoped wrapper only when the legacy bookmark is present and valid.
    /// For non-sandboxed builds this is nil when only the string preference is used.
    func resolvedExportDirectoryAccess() -> SecurityScopedExportDirectory? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        do {
            var isStale = false
            let directoryURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let access = SecurityScopedExportDirectory(url: directoryURL)
            let values = try directoryURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
            guard values.isDirectory == true else {
                throw StorageLocationPreferencesError.notDirectory
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
                throw StorageLocationPreferencesError.notDirectory
            }
            if isStale {
                // Refresh bookmark and string together for backward compat.
                try? setExportDirectory(directoryURL)
            }
            return access
        } catch {
            defaults.removeObject(forKey: Self.bookmarkKey)
            return nil
        }
    }

    // MARK: - Mutation

    func setLibraryDirectory(_ url: URL) throws {
        try validateIsDirectory(url)
        defaults.set(url.standardizedFileURL.path, forKey: Self.libraryPathKey)
    }

    func setScratchDirectory(_ url: URL) throws {
        try validateIsDirectory(url)
        defaults.set(url.standardizedFileURL.path, forKey: Self.scratchPathKey)
    }

    /// Stores both the security-scoped bookmark (for legacy / sandboxed fallback) and the
    /// plain string path. Validates that the URL is a directory.
    func setExportDirectory(_ url: URL) throws {
        try validateIsDirectory(url)
        // Store plain string first so string fallback is always present.
        defaults.set(url.standardizedFileURL.path, forKey: Self.exportPathKey)
        // Store bookmark for backward compat; if bookmark creation fails on non-sandboxed
        // or unusual FS, do not fail the overall set – the string is authoritative.
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            // Non-fatal: plain string is sufficient when not sandboxed.
            // Keep behavior consistent with ExportFolderPreference which would throw;
            // here we swallow bookmark errors only if string succeeded, to avoid breaking
            // non-sandboxed flows. If strict behavior is desired, rethrow.
            // We choose to not throw, but leave bookmark absent.
        }
    }

    func resetLibraryDirectory() {
        defaults.removeObject(forKey: Self.libraryPathKey)
    }

    func resetScratchDirectory() {
        defaults.removeObject(forKey: Self.scratchPathKey)
    }

    func resetExportDirectory() {
        defaults.removeObject(forKey: Self.exportPathKey)
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    // MARK: - Save panel helper

    /// Sets the panel's directoryURL to the resolved Export directory.
    /// Returns a retained SecurityScopedExportDirectory when the legacy bookmark
    /// is in use (caller should hold withExtendedLifetime); otherwise nil.
    @MainActor
    func applyExportDefaultDirectory(to panel: NSSavePanel) -> SecurityScopedExportDirectory? {
        let access = resolvedExportDirectoryAccess()
        let url = access?.url.standardizedFileURL ?? resolvedExportURL()
        // NSSavePanel ignores a non-existent directoryURL (falls back to ~/Documents),
        // so ensure the resolved Export dir exists before assigning it.
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return access
        }
        panel.directoryURL = url
        return access
    }

    // MARK: - Private helpers

    private var musicBase: URL {
        if let url = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first {
            return url
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
    }

    private var cachesBase: URL {
        if let url = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return url
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    private func resolveStringKey(_ key: String, fallback: URL) -> URL {
        guard let stored = defaults.string(forKey: key), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback.standardizedFileURL
        }
        let url = URL(fileURLWithPath: stored, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            defaults.removeObject(forKey: key)
            return fallback.standardizedFileURL
        }
        // Extra resourceValues validation to ensure it's actually a directory (handles symlink/file edge).
        if let values = try? url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]), values.isDirectory == false {
            defaults.removeObject(forKey: key)
            return fallback.standardizedFileURL
        }
        return url
    }

    private func validateIsDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
        guard values.isDirectory == true else {
            throw StorageLocationPreferencesError.notDirectory
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw StorageLocationPreferencesError.notDirectory
        }
    }
}

enum StorageLocationPreferencesError: Error, LocalizedError {
    case notDirectory

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            return "Choose an existing folder for exports."
        }
    }
}
