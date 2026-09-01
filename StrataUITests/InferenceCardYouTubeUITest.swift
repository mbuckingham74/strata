import XCTest

final class InferenceCardYouTubeUITest: XCTestCase {
    func testInvalidYouTubeHostSurfacesFailure() {
        let app = XCUIApplication()
        app.launch()

        // Robust field query: primary TextField, fallback to any descendant with identifier
        let field = app.textFields["YouTubeURLField"]
        let anyField = app.descendants(matching: .any)["YouTubeURLField"]
        let fieldExists = field.waitForExistence(timeout: 5) || anyField.waitForExistence(timeout: 5)
        XCTAssertTrue(fieldExists, "YouTube URL field should exist")
        let targetField = field.exists ? field : anyField
        XCTAssertTrue(targetField.waitForExistence(timeout: 2), "Target field should exist")
        targetField.click()
        targetField.typeText("https://example.com/watch?v=123")

        let button = app.buttons["LoadYouTubeSourceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Load source button should exist")

        // Respect runtime-readiness gating: button is disabled when yt-dlp/ffmpeg missing.
        // If enabled, validate invalid-host failure; otherwise verify readiness hint.
        if button.isEnabled {
            button.click()

            // Production validation surfaces as failed state text "Invalid YouTube URL: ..."
            let predicate = NSPredicate(format: "label CONTAINS 'Invalid YouTube URL'")
            let failureLabel = app.staticTexts.matching(predicate).firstMatch
            let fallbackExact = app.staticTexts["Invalid YouTube URL: https://example.com/watch?v=123"]

            let found = failureLabel.waitForExistence(timeout: 10) || fallbackExact.waitForExistence(timeout: 1)
            XCTAssertTrue(found, "Expected 'Invalid YouTube URL' failure to be visible after invoking Load source with invalid host")
        } else {
            // Button correctly gated by readiness — verify hint is visible and do not expect ingestion failure
            let hint = app.staticTexts["YouTubeReadinessHint"]
            let hintAlt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'yt-dlp' OR label CONTAINS 'YouTube disabled' OR label CONTAINS 'Setup needed'")).firstMatch
            let hintFound = hint.waitForExistence(timeout: 5) || hintAlt.waitForExistence(timeout: 5)
            XCTAssertTrue(hintFound, "Load button should be disabled when YouTube acquisition not ready and hint should be visible")
            XCTAssertFalse(button.isEnabled, "Load source button should be disabled when readiness gating is active")
        }
    }
}
