#if os(iOS)
import Foundation
import CoreLocation

/// CoreLocation, reduced to the two things the recorder wants: stays and fixes.
///
/// Visit monitoring and significant-change monitoring both relaunch the app after
/// it has been terminated, which is the normal state of a tracking app — so this
/// object must be constructible and armed without any UI on screen.
final class DeviceLocationSource: NSObject, StopSource, CLLocationManagerDelegate {
    var onStop: ((CapturedStop) -> Void)?
    var onFix: ((CapturedFix) -> Void)?
    /// Raised when authorization changes, so the settings screen can catch up.
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private let manager = CLLocationManager()
    private var mode: TrackingMode = .off
    private var isTracing = false
    /// Held only while fine tracing is on. Its lifetime is what tells iOS the
    /// background updates are deliberate, and what lights the status indicator.
    private var backgroundSession: CLBackgroundActivitySession?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other
        manager.allowsBackgroundLocationUpdates = false
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    var hasAlwaysAuthorization: Bool { manager.authorizationStatus == .authorizedAlways }

    /// Fine paths need full accuracy; stays survive the reduced-accuracy grant.
    var hasFullAccuracy: Bool { manager.accuracyAuthorization == .fullAccuracy }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Only ever called after the first recorded stay, so the system prompt lands
    /// when the user can already see what it buys them.
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    func start(mode: TrackingMode) {
        self.mode = mode
        guard mode.isRecording else {
            stop()
            return
        }
        manager.startMonitoringVisits()
        if mode.tracksMovement {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
        if !mode.tracksFinePaths {
            setLiveTracing(false)
        }
        TimelineLog.info("capture location started", ["mode": mode.rawValue])
    }

    func stop() {
        mode = .off
        setLiveTracing(false)
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        TimelineLog.info("capture location stopped")
    }

    /// Continuous updates, armed only while Core Motion says we are moving. iOS
    /// shows the location indicator the whole time this is on, which is a useful
    /// honesty check: if it is lit while the phone sits on a desk, this is a bug.
    func setLiveTracing(_ enabled: Bool) {
        let wanted = enabled && mode.tracksFinePaths && hasAlwaysAuthorization && hasFullAccuracy
        guard wanted != isTracing else { return }
        isTracing = wanted
        if wanted {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 25
            manager.allowsBackgroundLocationUpdates = true
            backgroundSession = CLBackgroundActivitySession()
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
            backgroundSession?.invalidate()
            backgroundSession = nil
            manager.allowsBackgroundLocationUpdates = false
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        }
        TimelineLog.info("capture live tracing", ["on": "\(wanted)"])
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard CLLocationCoordinate2DIsValid(visit.coordinate) else { return }
        // CoreLocation uses .distantPast / .distantFuture for the ends it does not
        // know. A .distantPast arrival means the stay began before monitoring did
        // — common right after Always is granted. Substituting "now" for it wrote
        // stays that ended before they started.
        let arrivalIsKnown = visit.arrivalDate != .distantPast
        let arrival = arrivalIsKnown ? visit.arrivalDate : (visit.departureDate == .distantFuture ? Date() : visit.departureDate)
        let departure = visit.departureDate == .distantFuture ? nil : visit.departureDate
        // Arriving somewhere ends the trip: stop burning the radio even if Core
        // Motion has not admitted we are stationary yet.
        if departure == nil { setLiveTracing(false) }
        onStop?(
            CapturedStop(
                coordinate: visit.coordinate,
                horizontalAccuracy: visit.horizontalAccuracy,
                start: arrival,
                end: departure,
                arrivalIsKnown: arrivalIsKnown
            )
        )
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy > 0 {
            onFix?(
                CapturedFix(
                    coordinate: location.coordinate,
                    timestamp: location.timestamp,
                    horizontalAccuracy: location.horizontalAccuracy,
                    speed: max(location.speed, 0)
                )
            )
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        TimelineLog.info(
            "capture authorization",
            ["status": "\(manager.authorizationStatus.rawValue)", "accuracy": "\(manager.accuracyAuthorization.rawValue)"]
        )
        onAuthorizationChange?(manager.authorizationStatus)
        if mode.isRecording, manager.authorizationStatus == .authorizedAlways {
            start(mode: mode)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        TimelineLog.error("capture location failed", ["error": error.localizedDescription])
    }
}
#endif
