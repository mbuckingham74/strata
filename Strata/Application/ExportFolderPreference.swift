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

    private let storage: StorageLocationPreferences

    init(defaults: UserDefaults = .standard) {
        self.storage = StorageLocationPreferences(defaults: defaults)
    }

    func setDefaultDirectory(_ directoryURL: URL) throws {
        do {
            try storage.setExportDirectory(directoryURL)
        } catch let e as StorageLocationPreferencesError {
            switch e {
            case .notDirectory:
                throw ExportFolderPreferenceError.notDirectory
            }
        } catch let e as ExportFolderPreferenceError {
            throw e
        } catch {
            // Map any other validation failure to notDirectory for compat.
            throw ExportFolderPreferenceError.notDirectory
        }
    }

    func resolvedDefaultDirectory() -> SecurityScopedExportDirectory? {
        storage.resolvedExportDirectoryAccess()
    }

    @MainActor
    func applyDefaultDirectory(to panel: NSSavePanel) -> SecurityScopedExportDirectory? {
        // Delegate to StorageLocationPreferences which handles both bookmark and string
        // resolution and sets panel.directoryURL to the resolved export URL.
        storage.applyExportDefaultDirectory(to: panel)
    }
}
