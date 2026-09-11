import XCTest

/// The Tracking sheet reads the store, and a sheet gets its own environment on
/// iOS — so tapping this button once crashed the app. This is the regression.
final class TrackingSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    func testTrackingSettingsOpensWithoutCrashing() {
        let app = XCUIApplication()
        app.launchArguments = ["loadFixture"]
        app.launchEnvironment["TIMELINE_UI_TESTING"] = "1"
        app.launchEnvironment["TIMELINE_LOAD_FIXTURE"] = "1"
        app.launch()

        let button = app.descendants(matching: .any).matching(identifier: "tracking-settings").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Tracking button should be in the toolbar")
        button.tap()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "tracking-mode-balanced").firstMatch
                .waitForExistence(timeout: 10),
            "Tracking settings should present its mode list"
        )
        XCTAssertEqual(app.state, .runningForeground, "the app must still be alive")
    }
    #endif
}
