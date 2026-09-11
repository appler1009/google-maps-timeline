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

/// Launch behaviour: a tracking app should show what it recorded, not a list of
/// months to drill through.
final class LaunchOnTodayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    func testLaunchOpensTheMapRatherThanTheDateList() {
        let app = XCUIApplication()
        app.launchArguments = ["loadFixture", "openOnToday"]
        app.launchEnvironment["TIMELINE_UI_TESTING"] = "1"
        app.launchEnvironment["TIMELINE_LOAD_FIXTURE"] = "1"
        app.launchEnvironment["TIMELINE_OPEN_ON_TODAY"] = "1"
        app.launch()

        let map = app.descendants(matching: .any).matching(identifier: "timeline-map").firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20), "the map should be on screen without tapping a day")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "back-to-list").firstMatch
                .waitForExistence(timeout: 5),
            "and there should be a way back to the list"
        )
    }
    #endif
}

/// The sections that only exist once recording is on.
final class TrackingOptionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    func testTurningRecordingOnRevealsTheRestOfTheScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["loadFixture", "showTracking"]
        app.launchEnvironment["TIMELINE_UI_TESTING"] = "1"
        app.launchEnvironment["TIMELINE_LOAD_FIXTURE"] = "1"
        app.launchEnvironment["TIMELINE_SHOW_TRACKING"] = "1"
        app.launch()

        let balanced = app.descendants(matching: .any).matching(identifier: "tracking-mode-balanced").firstMatch
        XCTAssertTrue(balanced.waitForExistence(timeout: 20), "Tracking should open straight to the mode list")
        balanced.tap()

        let notify = app.switches["tracking-notify-toggle"]
        XCTAssertTrue(notify.waitForExistence(timeout: 10), "recording on means the notification switch appears")

        // The later sections are below the fold. Swiping the app would drag the
        // sheet itself, so scroll the form.
        let model = app.switches["tracking-model-toggle"]
        XCTAssertTrue(scroll(app, to: model), "on-device intelligence should be offered")
        XCTAssertEqual(model.value as? String, "1", "smarter guesses are on by default")

        XCTAssertTrue(
            scroll(app, to: app.switches["cloud-sync-toggle"]),
            "iCloud sync should be offered too"
        )

        // The diagnostics exist to tell "nothing recorded yet" apart from
        // "nothing is working", so they have to be reachable.
        XCTAssertTrue(scroll(app, to: app.staticTexts["Raw counts"]), "raw counts should be shown")
        XCTAssertTrue(app.staticTexts["Stays, all time"].exists)
        XCTAssertTrue(app.staticTexts["Location fixes today"].exists)
        XCTAssertTrue(app.staticTexts["Right now"].exists, "the open stay is the answer to a zero count")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Scrolls the settings form until an element is on screen, or gives up.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement, attempts: Int = 8) -> Bool {
        let form = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.tables.firstMatch
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            form.swipeUp()
        }
        return element.exists
    }
    #endif
}
