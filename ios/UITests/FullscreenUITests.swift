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

        // 4. Exit Fullscreen
        exitButton.tap()

        // 5. Control bar with Fullscreen button is restored
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
}
