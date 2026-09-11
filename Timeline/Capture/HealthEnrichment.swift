import Foundation
import CoreLocation

/// A workout the Watch (or the phone) already recorded, flattened off HealthKit.
struct HealthWorkout: Equatable {
    let id: String
    let start: Date
    let end: Date
    let kind: MotionKind
    let distanceMeters: Double
    /// The GPS route HealthKit stored with it, empty when there was none.
    let route: [CLLocationCoordinate2D]

    static func == (lhs: HealthWorkout, rhs: HealthWorkout) -> Bool {
        lhs.id == rhs.id && lhs.start == rhs.start && lhs.end == rhs.end
            && lhs.kind == rhs.kind && lhs.route.count == rhs.route.count
    }
}

/// Distance the Watch logged passively, with no workout started.
struct HealthDistanceSample: Equatable {
    let start: Date
    let end: Date
    let meters: Double
    let kind: MotionKind
}

/// Reads workouts and passive distance. Implemented against HealthKit on iOS;
/// the tests hand it scripted values.
protocol HealthSource: AnyObject {
    var isAvailable: Bool { get }
    func requestAuthorization() async -> Bool
    func workouts(from: Date, to: Date) async -> [HealthWorkout]
    func distances(from: Date, to: Date) async -> [HealthDistanceSample]
}

/// What the Watch is actually good for.
///
/// It cannot stream its motion classification to the phone, and a watchOS app
/// could only run in the background during a workout — at which point HealthKit
/// already has the answer. So this takes the two things HealthKit gives for free:
/// an exact route for workouts, and the passive distance that settles Core
/// Motion's one genuinely weak call.
enum HealthEnrichment {
    /// A recorded workout route is the best evidence there is, so it replaces
    /// whatever Core Motion guessed for the same window.
    static func batch(for workouts: [HealthWorkout]) -> TimelineBatch {
        var activities: [TimelineActivity] = []
        var paths: [TimelinePath] = []
        for workout in workouts where workout.end > workout.start {
            activities.append(
                TimelineActivity(
                    id: activityID(workout),
                    start: workout.start,
                    end: workout.end,
                    distance: workout.distanceMeters,
                    startCoordinate: workout.route.first,
                    endCoordinate: workout.route.count > 1 ? workout.route.last : nil,
                    kind: workout.kind.travelKind
                )
            )
            guard workout.route.count >= 2 else { continue }
            paths.append(
                TimelinePath(
                    id: pathID(workout),
                    start: workout.start,
                    end: workout.end,
                    points: workout.route,
                    kind: workout.kind.travelKind
                )
            )
        }
        return TimelineBatch(visits: [], activities: activities, paths: paths)
    }

    static func activityID(_ workout: HealthWorkout) -> String {
        Geo.segmentID("hw", Geo.millis(workout.start), workout.id)
    }

    static func pathID(_ workout: HealthWorkout) -> String {
        Geo.segmentID("hp", Geo.millis(workout.start), workout.id)
    }

    /// Enough cycling distance inside a window to rule out a car.
    static let cyclingEvidenceMeters: Double = 300

    /// Core Motion's weakest call is a slow urban ride read as driving. If the
    /// Watch logged real cycling distance across the same window, it was a ride.
    /// This is the entire justification for asking for HealthKit at all.
    static func corrected(
        _ activities: [TimelineActivity],
        using samples: [HealthDistanceSample]
    ) -> [TimelineActivity] {
        let cycling = samples.filter { $0.kind == .cycling }
        guard !cycling.isEmpty else { return activities }
        return activities.map { activity in
            guard case .automobile = activity.kind else { return activity }
            let meters = overlappingMeters(cycling, from: activity.start, to: activity.end)
            guard meters >= cyclingEvidenceMeters else { return activity }
            return TimelineActivity(
                id: activity.id,
                start: activity.start,
                end: activity.end,
                distance: max(activity.distance, meters),
                startCoordinate: activity.startCoordinate,
                endCoordinate: activity.endCoordinate,
                kind: .cycling
            )
        }
    }

    /// Samples are pro-rated: a Watch sample can straddle the edge of a trip.
    static func overlappingMeters(
        _ samples: [HealthDistanceSample],
        from start: Date,
        to end: Date
    ) -> Double {
        var total: Double = 0
        for sample in samples {
            let span = sample.end.timeIntervalSince(sample.start)
            let overlap = min(sample.end, end).timeIntervalSince(max(sample.start, start))
            guard overlap > 0 else { continue }
            total += span > 0 ? sample.meters * (overlap / span) : sample.meters
        }
        return total
    }
}
