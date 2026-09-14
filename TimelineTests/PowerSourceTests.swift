#if os(macOS)
import XCTest
import IOKit.ps
@testable import Timeline

final class PowerSourceTests: XCTestCase {
    /// Mains, mains through a UPS, and a desktop with no battery all report no
    /// time limit.
    func testUnlimitedPowerIsTheWall() {
        XCTAssertTrue(PowerSource.isWallPower(timeRemaining: kIOPSTimeRemainingUnlimited, lowPowerMode: false))
    }

    /// A laptop battery, or a UPS carrying the Mac through an outage.
    func testAnythingRunningDownIsNot() {
        XCTAssertFalse(PowerSource.isWallPower(timeRemaining: 3 * 3_600, lowPowerMode: false))
        XCTAssertFalse(PowerSource.isWallPower(timeRemaining: kIOPSTimeRemainingUnknown, lowPowerMode: false))
    }

    func testLowPowerModeOverrulesTheWall() {
        XCTAssertFalse(PowerSource.isWallPower(timeRemaining: kIOPSTimeRemainingUnlimited, lowPowerMode: true))
    }
}
#endif
