import XCTest
import LogShip
@testable import Timeline

/// The unit-test bundles are hosted by the app binary, so anything the app logs
/// during a test run is shipped from the app's own identity. Left alone, a suite
/// run filled the collector with fixture coordinates under `timeline-mac`.
final class TimelineLogTests: XCTestCase {
    func testTheGateRecognisesThisIsATestRun() {
        XCTAssertTrue(
            TimelineLog.isRunningTests,
            "if this fails, the suite is shipping its own noise to the real collector"
        )
    }

    func testShippingStaysUnconfiguredUnderTest() async {
        // Exercising every level must not configure the client behind our back.
        TimelineLog.start()
        TimelineLog.debug("test debug")
        TimelineLog.info("test info", ["placeKey": "49.2765,-123.0680"])
        TimelineLog.warning("test warning")
        TimelineLog.error("test error")
        TimelineLog.refreshConfiguration()

        // Let any task that should not exist get a chance to run.
        try? await Task.sleep(for: .milliseconds(150))
        let status = await LogShip.shared.status()
        XCTAssertFalse(status.isConfigured, "a test run must never configure the log shipper")
    }

    func testTheSourceStillNamesThePlatform() {
        #if os(iOS)
        XCTAssertEqual(TimelineLog.source, "timeline-ios")
        #else
        XCTAssertEqual(TimelineLog.source, "timeline-mac")
        #endif
    }
}
