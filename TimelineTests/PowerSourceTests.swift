#if os(macOS)
import XCTest
import IOKit.ps
@testable import Timeline

final class PowerSourceTests: XCTestCase {
    func testOnlyWallPowerCountsAndLowPowerModeOverrulesIt() {
        XCTAssertTrue(PowerSource.isWallPower(providingType: kIOPSACPowerValue, lowPowerMode: false))
        XCTAssertFalse(PowerSource.isWallPower(providingType: kIOPSBatteryPowerValue, lowPowerMode: false))
        XCTAssertFalse(PowerSource.isWallPower(providingType: kIOPSACPowerValue, lowPowerMode: true))
    }

    /// A desktop reports no power source; it has no battery to save.
    func testAMacWithNoPowerSourceIsOnTheWall() {
        XCTAssertTrue(PowerSource.isWallPower(providingType: nil, lowPowerMode: false))
    }
}
#endif
