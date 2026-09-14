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
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let providing = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        return isWallPower(
            providingType: providing,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// The decision alone, so it can be tested without unplugging anything.
    ///
    /// A Mac that reports no power source at all is a desktop: it has no
    /// battery to save. Low Power Mode is someone asking for less work to be
    /// done, plugged in or not.
    static func isWallPower(providingType: String?, lowPowerMode: Bool) -> Bool {
        guard !lowPowerMode else { return false }
        guard let providingType else { return true }
        return providingType == kIOPSACPowerValue
    }
}
#endif
