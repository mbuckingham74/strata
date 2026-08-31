import AppKit
import XCTest
@testable import Strata

final class ExportFolderPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        suiteName = "ExportFolderPreferenceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        temporaryDirectoryURL = nil
    }

    func testSelectedFolderBookmarkPersistsAndResolvesInNewPreferenceInstance() throws {
        try ExportFolderPreference(defaults: defaults).setDefaultDirectory(temporaryDirectoryURL)

        XCTAssertNotNil(defaults.data(forKey: ExportFolderPreference.bookmarkKey))
        let access = try XCTUnwrap(
            ExportFolderPreference(defaults: defaults).resolvedDefaultDirectory()
        )
        XCTAssertEqual(normalized(access.url), normalized(temporaryDirectoryURL))
    }

    func testCorruptBookmarkFallsBackAndIsDiscarded() {
        defaults.set(Data("not a bookmark".utf8), forKey: ExportFolderPreference.bookmarkKey)

        let access = ExportFolderPreference(defaults: defaults).resolvedDefaultDirectory()

        XCTAssertNil(access)
        XCTAssertNil(defaults.data(forKey: ExportFolderPreference.bookmarkKey))
    }

    func testMissingBookmarkedFolderFallsBackAndIsDiscarded() throws {
        let preference = ExportFolderPreference(defaults: defaults)
        try preference.setDefaultDirectory(temporaryDirectoryURL)
        try FileManager.default.removeItem(at: temporaryDirectoryURL)

        XCTAssertNil(preference.resolvedDefaultDirectory())
        XCTAssertNil(defaults.data(forKey: ExportFolderPreference.bookmarkKey))
    }

    @MainActor
    func testSavePanelStartsInDefaultFolderWithoutPersistingPanelNavigation() throws {
        let overrideDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: overrideDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: overrideDirectoryURL) }

        let preference = ExportFolderPreference(defaults: defaults)
        try preference.setDefaultDirectory(temporaryDirectoryURL)
        let panel = NSSavePanel()
        let access = preference.applyDefaultDirectory(to: panel)

        XCTAssertEqual(
            normalized(try XCTUnwrap(panel.directoryURL)),
            normalized(temporaryDirectoryURL)
        )
        panel.directoryURL = overrideDirectoryURL

        let persistedAccess = try XCTUnwrap(
            ExportFolderPreference(defaults: defaults).resolvedDefaultDirectory()
        )
        XCTAssertEqual(normalized(persistedAccess.url), normalized(temporaryDirectoryURL))
        withExtendedLifetime(access) {}
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
