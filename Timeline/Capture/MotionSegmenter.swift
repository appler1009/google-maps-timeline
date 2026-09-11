import Foundation
import CoreLocation

/// Turns Core Motion's sample stream and whatever fixes we collected into the
/// activities and paths the rest of the app already knows how to draw.
///
/// Core Motion reports a start time and a classification, never an end, so a
/// sample only becomes an interval once the next one arrives. Everything here is
/// a pure function over arrays: the recorder does the I/O, this does the thinking.
enum MotionSegmenter {
    /// Below this a "trip" is Core Motion noticing you walked to the kitchen.
    static let minimumTripDuration: TimeInterval = 90
    /// A gap this long between fixes means we were asleep, not standing still.
    static let maximumFixGap: TimeInterval = 30 * 60
    /// Fixes closer together than this add nothing to a drawn line.
    static let pathSpacing: CLLocationDistance = 25

    /// An interval this short is Core Motion blinking, not a change of activity.
    static let flickerDuration: TimeInterval = 60

    /// Pair each sample with the next one, drop the flickers, and coalesce
    /// neighbours that agree.
    static func trips(from samples: [MotionSample], through windowEnd: Date) -> [MotionTrip] {
        let ordered = samples
            .sorted { $0.start < $1.start }
            .filter { $0.kind != .unknown || $0.confidence > 0 }
        guard !ordered.isEmpty else { return [] }

        var intervals: [MotionTrip] = []
        for (index, sample) in ordered.enumerated() {
            let end = index + 1 < ordered.count ? ordered[index + 1].start : windowEnd
            guard end > sample.start else { continue }
            intervals.append(MotionTrip(start: sample.start, end: end, kind: sample.kind))
        }

        // One stray "stationary" second in the middle of a walk must not split the
        // walk in two, so drop the blinks first and then let the neighbours join
        // across the hole they left.
        var merged = coalesced(intervals)
        merged = coalesced(merged.filter { $0.duration >= flickerDuration })
        merged = coalesced(merged.filter { !$0.kind.isMoving || $0.duration >= minimumTripDuration })
        return merged.filter(\.kind.isMoving)
    }

    /// Join neighbours that agree, closing any gap a dropped interval left.
    private static func coalesced(_ intervals: [MotionTrip]) -> [MotionTrip] {
        var result: [MotionTrip] = []
        for interval in intervals {
            if let last = result.last, last.kind == interval.kind, interval.end > last.end {
                result[result.count - 1] = MotionTrip(start: last.start, end: interval.end, kind: last.kind)
            } else if result.last?.kind != interval.kind {
                result.append(interval)
            }
        }
        return result
    }

    static func activityID(_ trip: MotionTrip) -> String {
        Geo.segmentID("da", Geo.millis(trip.start), Geo.millis(trip.end))
    }

    static func pathID(_ trip: MotionTrip) -> String {
        Geo.segmentID("dp", Geo.millis(trip.start), Geo.millis(trip.end))
    }

    /// One activity per trip, measured against the fixes that fall inside it.
    /// With no fixes the trip still counts — the day gets a typed segment with an
    /// unknown distance rather than nothing at all.
    static func activities(for trips: [MotionTrip], fixes: [CapturedFix]) -> [TimelineActivity] {
        trips.map { trip in
            let inside = fixes.filter { $0.timestamp >= trip.start && $0.timestamp <= trip.end }
                .sorted { $0.timestamp < $1.timestamp }
            return TimelineActivity(
                id: activityID(trip),
                start: trip.start,
                end: trip.end,
                distance: distance(of: inside),
                startCoordinate: inside.first?.coordinate,
                endCoordinate: inside.count > 1 ? inside.last?.coordinate : nil,
                kind: trip.kind.travelKind
            )
        }
    }

    static func paths(for trips: [MotionTrip], fixes: [CapturedFix]) -> [TimelinePath] {
        trips.compactMap { trip in
            let inside = fixes.filter { $0.timestamp >= trip.start && $0.timestamp <= trip.end }
                .sorted { $0.timestamp < $1.timestamp }
            let points = thinned(inside).map(\.coordinate)
            guard points.count >= 2 else { return nil }
            return TimelinePath(
                id: pathID(trip),
                start: trip.start,
                end: trip.end,
                points: points,
                kind: trip.kind.travelKind
            )
        }
    }

    static func distance(of fixes: [CapturedFix]) -> Double {
        guard fixes.count > 1 else { return 0 }
        var total: Double = 0
        for (previous, next) in zip(fixes, fixes.dropFirst()) {
            guard next.timestamp.timeIntervalSince(previous.timestamp) <= maximumFixGap else { continue }
            total += RoutePlanner.meters(previous.coordinate, next.coordinate)
        }
        return total
    }

    /// Keep the ends and anything that moved far enough to change the line.
    static func thinned(_ fixes: [CapturedFix]) -> [CapturedFix] {
        guard let first = fixes.first else { return [] }
        var kept: [CapturedFix] = [first]
        for fix in fixes.dropFirst() {
            guard let last = kept.last else { continue }
            if RoutePlanner.meters(last.coordinate, fix.coordinate) >= pathSpacing {
                kept.append(fix)
            }
        }
        if let last = fixes.last, kept.last?.timestamp != last.timestamp {
            kept.append(last)
        }
        return kept
    }
}
