import Foundation
import CoreLocation

/// Where a row in the library came from. Imports keep writing `google`; anything
/// the phone recorded itself is `device`.
enum RecordSource: String {
    case google
    case device
    /// Added by hand. Never shadowed by reconciliation and never overwritten by a
    /// recording: if someone took the trouble to say they were somewhere, that
    /// beats anything inferred.
    case manual
}

/// How much the recorder is allowed to spend. Stored as a raw string so the
/// setting survives upgrades even if cases are reordered.
enum TrackingMode: String, CaseIterable, Identifiable {
    case off
    case places
    case balanced
    case fullTrace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .places: return "Places only"
        case .balanced: return "Balanced"
        case .fullTrace: return "Full trace"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Nothing is recorded. Imported exports still work."
        case .places: return "Stays and how long they lasted. No lines between them."
        case .balanced: return "Stays, typed trips, and a coarse line between places."
        case .fullTrace: return "Road-accurate lines while you are moving. Uses far more battery."
        }
    }

    var batteryLabel: String {
        switch self {
        case .off: return "—"
        case .places: return "< 1% a day"
        case .balanced: return "1–3% a day"
        case .fullTrace: return "10–20% a day"
        }
    }

    var isRecording: Bool { self != .off }

    /// Coarse fixes between stays, so a day has lines and not only pins.
    var tracksMovement: Bool { self == .balanced || self == .fullTrace }

    /// Continuous updates while Core Motion says we are moving.
    var tracksFinePaths: Bool { self == .fullTrace }
}

/// One stay, as the phone saw it. `end` is nil while the stay is still open.
/// Deliberately not `CLVisit`: that type is iOS-only, so keeping our own lets the
/// clustering and notification rules compile and be tested on macOS too.
struct CapturedStop: Equatable {
    let coordinate: CLLocationCoordinate2D
    let horizontalAccuracy: CLLocationAccuracy
    var start: Date
    var end: Date?
    /// False when CoreLocation reported the arrival as `.distantPast` — you were
    /// already there before monitoring began, so it knows you left but not when
    /// you got there. `start` is then only a placeholder for the repair to
    /// replace, never a time to write down.
    var arrivalIsKnown = true

    var duration: TimeInterval {
        guard let end else { return 0 }
        return max(end.timeIntervalSince(start), 0)
    }

    var isClosed: Bool { end != nil }

    static func == (lhs: CapturedStop, rhs: CapturedStop) -> Bool {
        lhs.start == rhs.start
            && lhs.end == rhs.end
            && lhs.horizontalAccuracy == rhs.horizontalAccuracy
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// The stay we are still inside, carrying the key it was already assigned so a
/// cold launch mid-stay closes it against the same place.
struct OpenStop: Equatable {
    var stop: CapturedStop
    var placeKey: String
}

/// A location fix worth keeping. Significant-change and live updates both land here.
struct CapturedFix: Equatable {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let horizontalAccuracy: CLLocationAccuracy
    let speed: CLLocationSpeed

    static func == (lhs: CapturedFix, rhs: CapturedFix) -> Bool {
        lhs.timestamp == rhs.timestamp
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// Core Motion's verdict for one interval, flattened to the cases we can draw.
enum MotionKind: String {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    var isMoving: Bool { self != .stationary && self != .unknown }

    var travelKind: TravelKind {
        switch self {
        case .walking, .running: return .walking
        case .cycling: return .cycling
        case .automotive: return .automobile
        case .stationary, .unknown: return .raw
        }
    }

    var label: String {
        switch self {
        case .stationary: return "Stopped"
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .automotive: return "Driving"
        case .unknown: return "Moving"
        }
    }
}

/// One classified interval. Core Motion reports a start only; the segmenter pairs
/// each sample with the next one to get an end.
struct MotionSample: Equatable {
    let start: Date
    let kind: MotionKind
    /// 0 low, 1 medium, 2 high — CMMotionActivityConfidence's raw values.
    let confidence: Int
}

/// A run of same-kind motion with both ends known.
struct MotionTrip: Equatable {
    let start: Date
    let end: Date
    let kind: MotionKind

    var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }
}

/// A place we already know about, used to snap a new stop onto an existing key.
struct PlaceAnchor: Equatable {
    let placeKey: String
    let coordinate: CLLocationCoordinate2D
    let visitCount: Int
    let isNamed: Bool

    static func == (lhs: PlaceAnchor, rhs: PlaceAnchor) -> Bool {
        lhs.placeKey == rhs.placeKey
            && lhs.visitCount == rhs.visitCount
            && lhs.isNamed == rhs.isNamed
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// Names the recorder marks its progress against, so a wake knows which window
/// of Core Motion history it still owes the library.
enum CaptureMark {
    static let motion = "motion"
    static let fixes = "fixes"
    static let reconcile = "reconcile"
    static let health = "health"
}

/// Sources the recorder pulls from. Concrete implementations wrap CoreLocation and
/// CoreMotion on iOS; the tests hand it scripted streams instead.
protocol StopSource: AnyObject {
    var onStop: ((CapturedStop) -> Void)? { get set }
    var onFix: ((CapturedFix) -> Void)? { get set }
    func start(mode: TrackingMode)
    func stop()
    /// Fine-grained updates, gated on a motion transition out of stationary.
    func setLiveTracing(_ enabled: Bool)
}

protocol MotionSource: AnyObject {
    var isAvailable: Bool { get }
    /// Core Motion keeps roughly seven days of history on the device.
    func samples(from: Date, to: Date) async -> [MotionSample]
    /// Live transitions, used only to gate fine tracing.
    func startLiveUpdates(_ handler: @escaping (MotionSample) -> Void)
    func stopLiveUpdates()
}
