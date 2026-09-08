import XCTest

final class MarkersAndRoutesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmptyLibrary() {
        let app = launchedApp(empty: true)
        let open = app.buttons["Open Timeline.json"]
        XCTAssertTrue(
            open.waitForExistence(timeout: 10) || app.id("open-timeline-empty").waitForExistence(timeout: 2),
            "Empty library should offer to open a Timeline.json export"
        )
    }

    func testMarkersAndRoutesUseEiffelTowerCoordinates() {
        let app = launchedApp(empty: false)

        XCTAssertTrue(app.staticTexts["eiffel-tower-day.json"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.id("day-row").waitForExistence(timeout: 10))

        #if os(iOS)
        app.id("day-row").tap()
        #endif

        XCTAssertTrue(app.id("timeline-map").waitForExistence(timeout: 10))
        XCTAssertTrue(app.id("map-marker-48.858370,2.294481").waitForExistence(timeout: 10))
        XCTAssertTrue(app.id("map-marker-48.860611,2.337633").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 routes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.id("selected-day-title").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Work"].waitForExistence(timeout: 5))

        #if os(iOS)
        app.id("back-to-list").clickOrTap()
        #endif
        tapPlaces(in: app)
        XCTAssertTrue(
            app.id("place-search").waitForExistence(timeout: 8)
                || app.id("place-eiffel-tower").waitForExistence(timeout: 2),
            "Places tab should show the place list"
        )
        let homePlace = app.id("place-eiffel-tower")
        if homePlace.waitForExistence(timeout: 5) {
            homePlace.clickOrTap()
        } else {
            app.staticTexts["Home"].clickOrTap()
        }
        XCTAssertTrue(app.id("map-marker-48.858370,2.294481").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 5))
    }

    private func launchedApp(empty: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = empty ? ["emptyLibrary"] : ["loadFixture"]
        app.launchEnvironment["TIMELINE_UI_TESTING"] = "1"
        app.launchEnvironment["TIMELINE_EMPTY_LIBRARY"] = empty ? "1" : "0"
        app.launchEnvironment["TIMELINE_LOAD_FIXTURE"] = empty ? "0" : "1"
        app.launch()
        app.activate()
        return app
    }

    private func tapPlaces(in app: XCUIApplication) {
        let tab = app.buttons["tab-places"]
        XCTAssertTrue(tab.waitForExistence(timeout: 8), "Places tab button should exist")
        tab.clickOrTap()
    }
}

private extension XCUIApplication {
    func id(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

private extension XCUIElement {
    func clickOrTap() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }
}
