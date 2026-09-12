import Foundation
import CoreLocation

/// Works out when someone was at a place, from the movement already recorded.
///
/// The case this exists for is the school run: a two-minute stop that
/// `CLVisit` will never report, inside a drive the app did record. The fixes
/// stored along that drive know when the car passed the school, and how fast it
/// was going — which is enough to propose a time the user only has to confirm.
enum VisitTimingGuesser {
    /// A fix further than this from the place was not a visit to it.
    static let approachRadius: CLLocationDistance = 250
    /// Below this, treat the car as stopped rather than passing. 2 m/s is a brisk
    /// walk, which no car does unless it is pulling in.
    static let stoppedSpeed: CLLocationSpeed = 2.0
    /// What to propose when the fixes show a pass but never a stop.
    static let driveByDuration: TimeInterval = 2 * 60
    /// Nothing usable: propose something a person can adjust rather than nothing.
    static let blindDuration: TimeInterval = 10 * 60

    struct Guess: Equatable {
        var start: Date
        var end: Date
        /// How the times were arrived at, so the sheet can say so plainly.
        var basis: Basis

        var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }

        enum Basis: Equatable {
            /// The fixes show the car slowing to a stop near the place.
            case stopped
            /// The fixes pass close by without stopping — a drop-off.
            case droveBy
            /// The place is nowhere near the day's movement; times are a placeholder.
            case unknown
        }
    }

    /// `fixes` should be the day's fixes, in any order.
    static func guess(
        placeCoordinate: CLLocationCoordinate2D,
        fixes: [CapturedFix],
        fallbackMidpoint: Date
    ) -> Guess {
        let ordered = fixes.sorted { $0.timestamp < $1.timestamp }
        let near = ordered.filter {
            RoutePlanner.meters($0.coordinate, placeCoordinate) <= approachRadius
        }
        guard let closest = near.min(by: {
            RoutePlanner.meters($0.coordinate, placeCoordinate)
                < RoutePlanner.meters($1.coordinate, placeCoordinate)
        }) else {
            return Guess(
                start: fallbackMidpoint.addingTimeInterval(-blindDuration / 2),
                end: fallbackMidpoint.addingTimeInterval(blindDuration / 2),
                basis: .unknown
            )
        }

        // A stop shows up as a run of slow fixes around the closest approach.
        let slow = contiguousSlowWindow(around: closest, in: near)
        if let slow, slow.end > slow.start {
            return Guess(start: slow.start, end: slow.end, basis: .stopped)
        }

        // Passed close by without stopping: centre a short stay on the pass.
        return Guess(
            start: closest.timestamp.addingTimeInterval(-driveByDuration / 2),
            end: closest.timestamp.addingTimeInterval(driveByDuration / 2),
            basis: .droveBy
        )
    }

    /// The unbroken run of slow fixes containing the closest approach. Returns nil
    /// when the closest approach was not itself slow — that is a drive-by.
    static func contiguousSlowWindow(
        around closest: CapturedFix,
        in fixes: [CapturedFix]
    ) -> (start: Date, end: Date)? {
        let ordered = fixes.sorted { $0.timestamp < $1.timestamp }
        guard let index = ordered.firstIndex(where: { $0.timestamp == closest.timestamp }) else { return nil }
        guard isStopped(ordered[index]) else { return nil }

        var first = index
        while first > 0, isStopped(ordered[first - 1]) { first -= 1 }
        var last = index
        while last < ordered.count - 1, isStopped(ordered[last + 1]) { last += 1 }
        return (ordered[first].timestamp, ordered[last].timestamp)
    }

    /// A fix with no speed reading is not evidence of movement either way, so it
    /// counts as stopped only if it sits among fixes that are.
    static func isStopped(_ fix: CapturedFix) -> Bool {
        fix.speed >= 0 && fix.speed <= stoppedSpeed
    }

    /// Where to centre a guess when the place is nowhere near the day's movement:
    /// the middle of the largest gap between recorded stays, which is when
    /// something unrecorded most plausibly happened.
    static func largestGapMidpoint(between visits: [TimelineVisit], on day: Date, calendar: Calendar = .current) -> Date {
        let ordered = visits.sorted { $0.start < $1.start }
        guard ordered.count > 1 else {
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        }
        var best: (gap: TimeInterval, midpoint: Date) = (0, ordered[0].end)
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            let gap = later.start.timeIntervalSince(earlier.end)
            guard gap > best.gap else { continue }
            best = (gap, earlier.end.addingTimeInterval(gap / 2))
        }
        return best.midpoint
    }
}
