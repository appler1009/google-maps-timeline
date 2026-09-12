import Foundation
import CoreLocation

/// Makes a stay writable, or refuses it.
///
/// CoreLocation reports a stay it only half saw — you were already somewhere when
/// monitoring began, so it knows when you left but not when you arrived. That is
/// the normal shape of the very first visit after Always is granted, and it has
/// to be repaired from other evidence rather than guessed at, because a stay with
/// a made-up arrival is worse than a short one: it sorts into the wrong place in
/// the day and makes the rest of the day read as nonsense.
enum StopRepair {
    /// A fix this close to the stay counts as being there.
    static let atPlaceRadius: CLLocationDistance = 200
    /// With no other evidence, how long to assume the stay ran before departure.
    static let unknownArrivalFallback: TimeInterval = 10 * 60
    /// Never infer an arrival further back than this from the departure.
    static let longestInferredStay: TimeInterval = 16 * 60 * 60

    /// Returns a stay safe to write, or nil when it cannot be placed in the day.
    ///
    /// - `openStart`: the stay already in progress at this place, if we saw it begin.
    /// - `fixes`: the day's fixes, used to find when we first arrived near here.
    static func repaired(
        _ stop: CapturedStop,
        openStart: Date?,
        fixes: [CapturedFix],
        previousTripEnd: Date? = nil
    ) -> CapturedStop? {
        guard let end = stop.end else { return stop }

        var repaired = stop
        if !stop.arrivalIsKnown {
            repaired.start = inferredArrival(
                departure: end,
                coordinate: stop.coordinate,
                openStart: openStart,
                previousTripEnd: previousTripEnd,
                fixes: fixes
            )
            repaired.arrivalIsKnown = true
        }

        // Whatever we inferred, a stay that ends before it starts is not a stay.
        guard repaired.start < end else { return nil }
        guard end.timeIntervalSince(repaired.start) >= 1 else { return nil }
        return repaired
    }

    /// Best evidence first: a stay we watched begin, then the moment the journey
    /// here ended, then the earliest fix that puts us here, then an assumption.
    ///
    /// The trip is the strong one. A stay begins when travelling stops, and Core
    /// Motion records travel from the coprocessor without needing location at all
    /// — so it is available precisely when fixes are not, which is the first
    /// morning after Always is granted.
    static func inferredArrival(
        departure: Date,
        coordinate: CLLocationCoordinate2D,
        openStart: Date?,
        previousTripEnd: Date? = nil,
        fixes: [CapturedFix]
    ) -> Date {
        let earliestAllowed = departure.addingTimeInterval(-longestInferredStay)

        if let openStart, openStart < departure, openStart >= earliestAllowed {
            return openStart
        }
        if let previousTripEnd, previousTripEnd < departure, previousTripEnd >= earliestAllowed {
            return previousTripEnd
        }
        if let arrival = firstFixNearby(
            coordinate: coordinate,
            before: departure,
            notBefore: earliestAllowed,
            fixes: fixes
        ) {
            return arrival
        }
        return departure.addingTimeInterval(-unknownArrivalFallback)
    }

    /// The start of the unbroken run of fixes near this place that ends at the
    /// departure. A fix from earlier in the day that happens to be nearby does not
    /// count unless we stayed nearby the whole way through — otherwise a morning
    /// pass close to home would swallow the afternoon.
    static func firstFixNearby(
        coordinate: CLLocationCoordinate2D,
        before departure: Date,
        notBefore earliest: Date,
        fixes: [CapturedFix]
    ) -> Date? {
        let ordered = fixes
            .filter { $0.timestamp <= departure && $0.timestamp >= earliest }
            .sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else { return nil }

        var arrival: Date?
        for fix in ordered.reversed() {
            guard RoutePlanner.meters(fix.coordinate, coordinate) <= atPlaceRadius else { break }
            arrival = fix.timestamp
        }
        return arrival
    }
}
