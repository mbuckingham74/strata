import AppKit
import XCTest
@testable import Strata

final class StorageLocationPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tempDirs: [URL] = []

    override func setUpWithError() throws {
        suiteName = "StorageLocationPreferencesTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        for url in tempDirs {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirs.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func testDefaultsResolveToExpectedSubpaths() {
        let pref = StorageLocationPreferences(defaults: defaults)
        let musicBase = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)

        XCTAssertEqual(normalized(pref.defaultLibraryURL), normalized(musicBase.appendingPathComponent("Strata/Library", isDirectory: true)))
        XCTAssertEqual(normalized(pref.defaultExportURL), normalized(musicBase.appendingPathComponent("Strata/Exports", isDirectory: true)))
        XCTAssertEqual(normalized(pref.defaultScratchRootURL), normalized(cachesBase.appendingPathComponent("Strata", isDirectory: true)))
    }

    func testLibraryPersistenceAndResolution() throws {
        let dir = try makeTempDir()
        let pref = StorageLocationPreferences(defaults: defaults)
        try pref.setLibraryDirectory(dir)
        XCTAssertEqual(defaults.string(forKey: StorageLocationPreferences.libraryPathKey), dir.standardizedFileURL.path)
        let resolved = pref.resolvedLibraryURL()
        XCTAssertEqual(normalized(resolved), normalized(dir))
        // New instance sees same
        let pref2 = StorageLocationPreferences(defaults: defaults)
        XCTAssertEqual(normalized(pref2.resolvedLibraryURL()), normalized(dir))
    }

    func testScratchPersistenceAndReset() throws {
        let dir = try makeTempDir()
        let pref = StorageLocationPreferences(defaults: defaults)
        try pref.setScratchDirectory(dir)
        XCTAssertEqual(normalized(pref.resolvedScratchRootURL()), normalized(dir))
        pref.resetScratchDirectory()
        XCTAssertNil(defaults.string(forKey: StorageLocationPreferences.scratchPathKey))
        XCTAssertEqual(normalized(pref.resolvedScratchRootURL()), normalized(pref.defaultScratchRootURL))
    }

    func testExportStringPersistence() throws {
        let dir = try makeTempDir()
        let pref = StorageLocationPreferences(defaults: defaults)
        try pref.setExportDirectory(dir)
        XCTAssertEqual(defaults.string(forKey: StorageLocationPreferences.exportPathKey), dir.standardizedFileURL.path)
        // Bookmark also stored for backward compat
        XCTAssertNotNil(defaults.data(forKey: StorageLocationPreferences.bookmarkKey))
        XCTAssertEqual(normalized(pref.resolvedExportURL()), normalized(dir))
    }

    func testFallbackWhenStoredFolderMissing() throws {
        let dir = try makeTempDir()
        let pref = StorageLocationPreferences(defaults: defaults)
        try pref.setLibraryDirectory(dir)
        try FileManager.default.removeItem(at: dir)
        // Resolution should fallback and remove key
        let resolved = pref.resolvedLibraryURL()
        XCTAssertEqual(normalized(resolved), normalized(pref.defaultLibraryURL))
        XCTAssertNil(defaults.string(forKey: StorageLocationPreferences.libraryPathKey))
        // Same for scratch
        let scratchDir = try makeTempDir()
        try pref.setScratchDirectory(scratchDir)
        try FileManager.default.removeItem(at: scratchDir)
        XCTAssertEqual(normalized(pref.resolvedScratchRootURL()), normalized(pref.defaultScratchRootURL))
        XCTAssertNil(defaults.string(forKey: StorageLocationPreferences.scratchPathKey))
        // Export string fallback
        let exportDir = try makeTempDir()
        try pref.setExportDirectory(exportDir)
        // Remove bookmark to force string path resolution
        defaults.removeObject(forKey: StorageLocationPreferences.bookmarkKey)
        try FileManager.default.removeItem(at: exportDir)
        let exportResolved = pref.resolvedExportURL()
        XCTAssertEqual(normalized(exportResolved), normalized(pref.defaultExportURL))
        XCTAssertNil(defaults.string(forKey: StorageLocationPreferences.exportPathKey))
    }

    func testScratchSubpathDerivation() throws {
        let dir = try makeTempDir()
        let pref = StorageLocationPreferences(defaults: defaults)
        try pref.setScratchDirectory(dir)
        XCTAssertEqual(normalized(pref.separationOutputBaseURL()).path, normalized(dir.appendingPathComponent("M3Separations", isDirectory: true)).path)
        XCTAssertEqual(normalized(pref.youtubeIngestCacheBaseURL()).path, normalized(dir.appendingPathComponent("M4Ingest", isDirectory: true)).path)
        XCTAssertEqual(normalized(pref.localIngestCacheBaseURL()).path, normalized(dir.appendingPathComponent("LocalIngest", isDirectory: true)).path)
        // Also when using defaults (no override), subpaths are under defaultScratchRoot
        let pref2 = StorageLocationPreferences(defaults: UserDefaults(suiteName: "other-\(UUID().uuidString)")!)
        let defaultRoot = pref2.defaultScratchRootURL
        XCTAssertEqual(normalized(pref2.separationOutputBaseURL()).path, normalized(defaultRoot.appendingPathComponent("M3Separations", isDirectory: true)).path)
    }

    @MainActor
    func testExportLegacyBookmarkFallbackPreferredOverString() throws {
        let bookmarkDir = try makeTempDir()
        let stringDir = try makeTempDir()
        // Create legacy bookmark via ExportFolderPreference
        let exportPref = ExportFolderPreference(defaults: defaults)
        try exportPref.setDefaultDirectory(bookmarkDir)
        // Also store a different string path
        defaults.set(stringDir.standardizedFileURL.path, forKey: StorageLocationPreferences.exportPathKey)

        let pref = StorageLocationPreferences(defaults: defaults)
        // Should prefer bookmark
        XCTAssertEqual(normalized(pref.resolvedExportURL()), normalized(bookmarkDir))
        XCTAssertNotNil(pref.resolvedExportDirectoryAccess())
        // Apply should set panel to bookmark url and return access
        let panel = NSSavePanel()
        let access = pref.applyExportDefaultDirectory(to: panel)
        XCTAssertNotNil(access)
        XCTAssertEqual(normalized(try XCTUnwrap(panel.directoryURL)), normalized(bookmarkDir))

        // Corrupt bookmark should discard and fallback to string
        defaults.set(Data("not a bookmark".utf8), forKey: StorageLocationPreferences.bookmarkKey)
        let pref2 = StorageLocationPreferences(defaults: defaults)
        XCTAssertNil(pref2.resolvedExportDirectoryAccess())
        XCTAssertEqual(normalized(pref2.resolvedExportURL()), normalized(stringDir))
        XCTAssertNil(defaults.data(forKey: StorageLocationPreferences.bookmarkKey))
    }

    @MainActor
    func testExportStringFallbackWhenNoBookmark() throws {
        let dir = try makeTempDir()
        defaults.removeObject(forKey: StorageLocationPreferences.bookmarkKey)
        defaults.set(dir.standardizedFileURL.path, forKey: StorageLocationPreferences.exportPathKey)
        let pref = StorageLocationPreferences(defaults: defaults)
        XCTAssertNil(pref.resolvedExportDirectoryAccess())
        XCTAssertEqual(normalized(pref.resolvedExportURL()), normalized(dir))
        let panel = NSSavePanel()
        let access = pref.applyExportDefaultDirectory(to: panel)
        XCTAssertNil(access)
        XCTAssertEqual(normalized(try XCTUnwrap(panel.directoryURL)), normalized(dir))
    }

    func testNotDirectoryThrows() throws {
        let pref = StorageLocationPreferences(defaults: defaults)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        XCTAssertThrowsError(try pref.setLibraryDirectory(fileURL))
        XCTAssertThrowsError(try pref.setScratchDirectory(fileURL))
        XCTAssertThrowsError(try pref.setExportDirectory(fileURL))
    }

    @MainActor
    func testApplyExportDefaultDirectorySetsPanelAndDoesNotPersistNavigation() throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        let pref = StorageLocationPreferences(defaults: defaults)
        try pref.setExportDirectory(dir)
        let panel = NSSavePanel()
        let access = pref.applyExportDefaultDirectory(to: panel)
        XCTAssertEqual(normalized(try XCTUnwrap(panel.directoryURL)), normalized(dir))
        // Simulate user navigating elsewhere – should not persist
        panel.directoryURL = other
        XCTAssertEqual(normalized(StorageLocationPreferences(defaults: defaults).resolvedExportURL()), normalized(dir))
        withExtendedLifetime(access) {}
    }

    @MainActor
    func testApplyCreatesMissingDefaultExportDirectory() throws {
        let musicBase = try makeTempDir()
        let fileManager = MusicBaseFileManager(musicBase: musicBase)
        let pref = StorageLocationPreferences(defaults: defaults, fileManager: fileManager)
        let expected = musicBase.appendingPathComponent("Strata/Exports", isDirectory: true).standardizedFileURL
        XCTAssertFalse(fileManager.fileExists(atPath: expected.path))
        let panel = NSSavePanel()
        panel.directoryURL = nil
        let access = pref.applyExportDefaultDirectory(to: panel)
        XCTAssertNil(access)
        XCTAssertEqual(normalized(try XCTUnwrap(panel.directoryURL)), normalized(expected))
        var isDir: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: expected.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertNil(defaults.string(forKey: StorageLocationPreferences.exportPathKey))
        XCTAssertNil(defaults.data(forKey: StorageLocationPreferences.bookmarkKey))
    }

    @MainActor
    func testApplyLeavesPanelUnsetWhenDirectoryCannotBeCreated() {
        let musicBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = FailingCreateFileManager(musicBase: musicBase)
        let pref = StorageLocationPreferences(defaults: defaults, fileManager: fileManager)
        let panel = NSSavePanel()
        panel.directoryURL = nil
        let before = panel.directoryURL
        let access = pref.applyExportDefaultDirectory(to: panel)
        XCTAssertNil(access)
        XCTAssertEqual(panel.directoryURL, before)
    }
}

private final class MusicBaseFileManager: FileManager {
    private let musicBase: URL

    init(musicBase: URL) {
        self.musicBase = musicBase
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        if directory == .musicDirectory {
            return [musicBase]
        }
        return super.urls(for: directory, in: domainMask)
    }
}

private final class FailingCreateFileManager: FileManager {
    private let musicBase: URL

    init(musicBase: URL) {
        self.musicBase = musicBase
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        if directory == .musicDirectory {
            return [musicBase]
        }
        return super.urls(for: directory, in: domainMask)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
    }
}
