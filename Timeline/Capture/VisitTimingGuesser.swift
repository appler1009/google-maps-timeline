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
    /// The same question asked of a stored route, which is a simplification: a
    /// half-hour drive comes back as a handful of points, and the corner where
    /// it turned into a car park is exactly the detail that gets cut. Measured
    /// against a real drive that stopped at a music school, the nearest the
    /// saved polyline came was some six hundred metres.
    static let routeApproachRadius: CLLocationDistance = 800
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

    /// `fixes` should be the day's fixes, in any order; `paths` the day's routes.
    ///
    /// Fixes are the better evidence — they carry speed, so they can tell a stop
    /// from a pass — but they are local scaffolding: pruned after a week and
    /// never synced. On the other device there are none at all, which is why
    /// adding a stay there could only ever propose midday. Paths do sync, so
    /// fall back to those.
    static func guess(
        placeCoordinate: CLLocationCoordinate2D,
        fixes: [CapturedFix],
        paths: [TimelinePath] = [],
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
            if let passed = passingTime(placeCoordinate: placeCoordinate, paths: paths) {
                return Guess(
                    start: passed.addingTimeInterval(-driveByDuration / 2),
                    end: passed.addingTimeInterval(driveByDuration / 2),
                    basis: .droveBy
                )
            }
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

    /// When the day's route came closest to a place.
    ///
    /// A path carries only its own start and end times, so the moment is read
    /// off the distance travelled: a point a third of the way along the line
    /// happened about a third of the way through the journey. Coarse — a route
    /// is not driven at a constant speed — but a coarse time inside the right
    /// few minutes beats midday, and the sheet is there to be adjusted.
    ///
    /// Measured to the line rather than to its corners. A stored route puts its
    /// points kilometres apart, so asking only about the corners misses a place
    /// sitting beside a long straight leg entirely.
    static func passingTime(
        placeCoordinate: CLLocationCoordinate2D,
        paths: [TimelinePath]
    ) -> Date? {
        var best: (distance: CLLocationDistance, at: Date)?
        for path in paths where path.points.count >= 2 {
            let legs = zip(path.points, path.points.dropFirst()).map { RoutePlanner.meters($0, $1) }
            let total = legs.reduce(0, +)
            guard total > 0 else { continue }
            var travelled: CLLocationDistance = 0
            for (index, leg) in legs.enumerated() {
                let from = path.points[index]
                let to = path.points[index + 1]
                let (away, fraction) = approach(of: placeCoordinate, toSegmentFrom: from, to: to)
                defer { travelled += leg }
                guard away <= routeApproachRadius else { continue }
                guard best == nil || away < best!.distance else { continue }
                let along = (travelled + leg * fraction) / total
                let span = path.end.timeIntervalSince(path.start)
                best = (away, path.start.addingTimeInterval(span * along))
            }
        }
        return best?.at
    }

    /// How close a segment comes to a point, and how far along it that happens.
    ///
    /// Flat-earth arithmetic: over the length of one leg of a drive the error is
    /// far smaller than the simplification already in the line.
    static func approach(
        of place: CLLocationCoordinate2D,
        toSegmentFrom from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> (distance: CLLocationDistance, fraction: Double) {
        let metresPerDegree = 111_320.0
        let shrink = cos(place.latitude * .pi / 180)
        func project(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            (c.longitude * metresPerDegree * shrink, c.latitude * metresPerDegree)
        }
        let point = project(place)
        let start = project(from)
        let end = project(to)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return (RoutePlanner.meters(place, from), 0)
        }
        let raw = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let fraction = min(max(raw, 0), 1)
        let closest = (x: start.x + fraction * dx, y: start.y + fraction * dy)
        return (hypot(point.x - closest.x, point.y - closest.y), fraction)
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
