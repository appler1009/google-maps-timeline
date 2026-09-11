import XCTest

/// A two-minute school drop-off is never a CLVisit, so the day's list is where
/// you notice one is missing and where you add it.
final class AddVisitUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    func testAddingAStayFromTheDaysList() {
        let app = XCUIApplication()
        app.launchArguments = ["loadFixture", "openOnToday"]
        app.launchEnvironment["TIMELINE_UI_TESTING"] = "1"
        app.launchEnvironment["TIMELINE_LOAD_FIXTURE"] = "1"
        app.launchEnvironment["TIMELINE_OPEN_ON_TODAY"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "timeline-map").firstMatch
                .waitForExistence(timeout: 20),
            "the day should be on the map"
        )

        // The legend opens collapsed, with the add row pinned to its bottom edge.
        // Drag the sheet up so the row is somewhere a finger can reach.
        let map = app.descendants(matching: .any).matching(identifier: "timeline-map").firstMatch
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93))
            .press(
                forDuration: 0.15,
                thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            )

        let add = app.descendants(matching: .any).matching(identifier: "add-stay").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the day's list should offer to add a stay")
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(
            app.textFields["add-visit-search"].waitForExistence(timeout: 10),
            "adding a stay starts by searching for the place"
        )
        // Nothing chosen yet, so there is nothing to add.
        XCTAssertFalse(app.buttons["add-visit-save"].isEnabled)
        XCTAssertEqual(app.state, .runningForeground)
    }
    #endif
}
