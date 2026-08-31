import AppKit
import Foundation

enum ExportFolderPreferenceError: Error, LocalizedError {
    case notDirectory

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            return "Choose an existing folder for exports."
        }
    }
}

final class SecurityScopedExportDirectory: @unchecked Sendable {
    let url: URL

    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

final class ExportFolderPreference: @unchecked Sendable {
    static let bookmarkKey = "defaultExportDirectoryBookmark"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func setDefaultDirectory(_ directoryURL: URL) throws {
        let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw ExportFolderPreferenceError.notDirectory
        }

        let bookmark = try directoryURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
    }

    func resolvedDefaultDirectory() -> SecurityScopedExportDirectory? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            return nil
        }

        do {
            var isStale = false
            let directoryURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let access = SecurityScopedExportDirectory(url: directoryURL)
            let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw ExportFolderPreferenceError.notDirectory
            }

            if isStale {
                try setDefaultDirectory(directoryURL)
            }
            return access
        } catch {
            defaults.removeObject(forKey: Self.bookmarkKey)
            return nil
        }
    }

    @MainActor
    func applyDefaultDirectory(to panel: NSSavePanel) -> SecurityScopedExportDirectory? {
        let access = resolvedDefaultDirectory()
        panel.directoryURL = access?.url
        return access
    }
}
