#if os(macOS)
import Foundation
import IOKit.ps

/// Whether the Mac is running off the wall.
///
/// Work that only makes the app a little more current — asking iCloud for
/// changes nobody has announced — is worth doing plugged in and not worth a
/// laptop's battery. Unplugged, the app waits for iCloud to say something
/// changed, or for you to bring it forward, as it always has.
enum PowerSource {
    static var isOnWallPower: Bool {
        isWallPower(
            timeRemaining: IOPSGetTimeRemainingEstimate(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// The decision alone, so it can be tested without unplugging anything.
    ///
    /// Asked as "is there a time limit", not "which source is providing".
    /// The providing source has a third answer, "UPS Power", which IOKit uses
    /// both for a Mac on a UPS with the mains present and for one running off
    /// the UPS's own battery. The time-remaining estimate tells those apart:
    /// it is unlimited on external power with no limit — mains, mains through
    /// a UPS, or a desktop with no battery at all — and anything else is a
    /// battery running down. Low Power Mode is someone asking for less work to
    /// be done, plugged in or not.
    static func isWallPower(timeRemaining: CFTimeInterval, lowPowerMode: Bool) -> Bool {
        guard !lowPowerMode else { return false }
        return timeRemaining == kIOPSTimeRemainingUnlimited
    }
}
#endif
