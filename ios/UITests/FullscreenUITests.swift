import XCTest

final class FullscreenUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFullscreenEnterAndExitFlow() throws {
        let app = XCUIApplication()
        app.launch()

        // 1. Fullscreen button exists on control bar via stable accessibility identifier
        let fullscreenButton = app.buttons["fullscreen-button"]
        XCTAssertTrue(fullscreenButton.waitForExistence(timeout: 8), "Fullscreen button should exist on control bar")

        // 2. Enter Fullscreen
        fullscreenButton.tap()

        // 3. Exit button appears in fullscreen mode via stable accessibility identifier
        let exitButton = app.buttons["exit-fullscreen-button"]
        XCTAssertTrue(exitButton.waitForExistence(timeout: 4), "Exit Fullscreen button should appear in fullscreen mode")

        // 4. Verify no top language titles/chips exist in fullscreen mode
        let languageChipPredicate = NSPredicate(format: "label CONTAINS '→'")
        XCTAssertFalse(
            app.staticTexts.containing(languageChipPredicate).element.exists,
            "Top language titles / chip should not be present in fullscreen mode"
        )
        // 5. Exit Fullscreen
        exitButton.tap()

        // 6. Control bar with Fullscreen button is restored
        XCTAssertTrue(fullscreenButton.waitForExistence(timeout: 4), "Control bar should be restored after exiting fullscreen")
    }

    @MainActor
    func testFullscreenTapToRevealChromeFlow() throws {
        let app = XCUIApplication()
        app.launch()

        let fullscreenButton = app.buttons["fullscreen-button"]
        XCTAssertTrue(fullscreenButton.waitForExistence(timeout: 8), "Fullscreen button should exist on control bar")

        // Enter Fullscreen
        fullscreenButton.tap()

        let exitButton = app.buttons["exit-fullscreen-button"]
        XCTAssertTrue(exitButton.waitForExistence(timeout: 4), "Exit Fullscreen button should appear initially in fullscreen mode")

        // Wait for auto-hide (3.5s timer + buffer)
        XCTAssertTrue(exitButton.waitForNonExistence(timeout: 6), "Exit Fullscreen button should auto-hide after inactivity timeout")

        // Tap the screen to reveal transient chrome
        app.windows.firstMatch.tap()
        XCTAssertTrue(exitButton.waitForExistence(timeout: 4), "Exit Fullscreen button should reappear on tap-to-reveal")

        // Clean exit
        exitButton.tap()
        XCTAssertTrue(fullscreenButton.waitForExistence(timeout: 4), "Control bar should be restored after exiting fullscreen")
    }

    @MainActor
    func testLiveCaptionPromotionKeepsCurrentTextAnchors() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-live-caption-promotion")
        app.launch()

        let source = app.staticTexts["live-caption-source"]
        let translation = app.staticTexts["live-caption-translation"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertTrue(translation.waitForExistence(timeout: 8))

        expectation(
            for: NSPredicate(format: "value == %@", "tentative"),
            evaluatedWith: source
        )
        expectation(
            for: NSPredicate(format: "value == %@", "tentative"),
            evaluatedWith: translation
        )
        waitForExpectations(timeout: 4)
        XCTAssertEqual(source.label, "Stable live caption")
        XCTAssertEqual(translation.label, "穩定即時字幕")

        let tentativeSourceFrame = source.frame
        let tentativeTranslationFrame = translation.frame
        XCTAssertFalse(tentativeSourceFrame.isEmpty)
        XCTAssertFalse(tentativeTranslationFrame.isEmpty)

        app.buttons["commit-live-caption"].tap()

        expectation(
            for: NSPredicate(format: "value == %@", "committed"),
            evaluatedWith: source
        )
        expectation(
            for: NSPredicate(format: "value == %@", "committed"),
            evaluatedWith: translation
        )
        waitForExpectations(timeout: 4)

        XCTAssertEqual(source.label, "Stable live caption.")
        XCTAssertEqual(translation.label, "穩定即時字幕。")
        assertAnchor(source.frame, equals: tentativeSourceFrame)
        assertAnchor(translation.frame, equals: tentativeTranslationFrame)
    }

    private func assertAnchor(
        _ actual: CGRect,
        equals expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
    }
}
