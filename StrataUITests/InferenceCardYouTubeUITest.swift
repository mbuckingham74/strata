import XCTest

final class InferenceCardYouTubeUITest: XCTestCase {
    func testInvalidYouTubeHostSurfacesFailure() {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["YouTubeURLField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "YouTube URL field should exist")

        field.click()
        field.typeText("https://example.com/watch?v=123")

        let button = app.buttons["SeparateFromYouTubeButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Separate from YouTube button should exist")
        XCTAssertTrue(button.isEnabled, "Button should be enabled for non-empty URL")

        button.click()

        // Production validation surfaces as failed state text "Invalid YouTube URL: ..."
        let predicate = NSPredicate(format: "label CONTAINS 'Invalid YouTube URL'")
        let failureLabel = app.staticTexts.matching(predicate).firstMatch
        let fallbackExact = app.staticTexts["Invalid YouTube URL: https://example.com/watch?v=123"]

        let found = failureLabel.waitForExistence(timeout: 10) || fallbackExact.waitForExistence(timeout: 1)
        XCTAssertTrue(found, "Expected 'Invalid YouTube URL' failure to be visible after invoking Separate from YouTube with invalid host")
    }
}
