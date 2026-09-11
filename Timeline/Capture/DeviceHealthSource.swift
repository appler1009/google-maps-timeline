#if os(iOS)
import Foundation
import CoreLocation
import HealthKit

/// HealthKit, reduced to workouts with their routes and passive distance.
///
/// Read-only and entirely optional: if the user never grants it, everything else
/// keeps working and trips simply keep Core Motion's classification.
final class DeviceHealthSource: HealthSource {
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        if let cycling = HKQuantityType.quantityType(forIdentifier: .distanceCycling) {
            types.insert(cycling)
        }
        if let walking = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(walking)
        }
        return types
    }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            TimelineLog.error("health authorization failed", ["error": error.localizedDescription])
            return false
        }
    }

    func workouts(from: Date, to: Date) async -> [HealthWorkout] {
        guard isAvailable, to > from else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let samples: [HKWorkout] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error {
                    // "Protected health data is inaccessible" just means the phone
                    // was locked when a background pass ran. It retries next wake.
                    TimelineLog.info("workout query skipped", ["reason": error.localizedDescription])
                }
                continuation.resume(returning: results as? [HKWorkout] ?? [])
            }
            store.execute(query)
        }

        var found: [HealthWorkout] = []
        for workout in samples {
            guard let kind = Self.kind(for: workout.workoutActivityType) else { continue }
            found.append(
                HealthWorkout(
                    id: workout.uuid.uuidString,
                    start: workout.startDate,
                    end: workout.endDate,
                    kind: kind,
                    distanceMeters: Self.meters(of: workout),
                    route: await route(for: workout)
                )
            )
        }
        return found
    }

    func distances(from: Date, to: Date) async -> [HealthDistanceSample] {
        guard isAvailable, to > from else { return [] }
        var found: [HealthDistanceSample] = []
        let wanted: [(HKQuantityTypeIdentifier, MotionKind)] = [
            (.distanceCycling, .cycling),
            (.distanceWalkingRunning, .walking),
        ]
        for (identifier, kind) in wanted {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
            let samples: [HKQuantitySample] = await withCheckedContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, results, _ in
                    continuation.resume(returning: results as? [HKQuantitySample] ?? [])
                }
                store.execute(query)
            }
            found.append(
                contentsOf: samples.map { sample in
                    HealthDistanceSample(
                        start: sample.startDate,
                        end: sample.endDate,
                        meters: sample.quantity.doubleValue(for: .meter()),
                        kind: kind
                    )
                }
            )
        }
        return found
    }

    /// Wakes the app when a workout lands, so a ride shows up without the user
    /// opening Timeline.
    func startObserving(_ handler: @escaping () -> Void) {
        guard isAvailable else { return }
        let query = HKObserverQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: nil
        ) { _, completion, error in
            if error == nil { handler() }
            completion()
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .hourly) { ok, error in
            if let error {
                TimelineLog.error("health background delivery failed", ["error": error.localizedDescription])
            } else {
                TimelineLog.info("health background delivery", ["enabled": "\(ok)"])
            }
        }
    }

    private func route(for workout: HKWorkout) async -> [CLLocationCoordinate2D] {
        let routeSamples: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                continuation.resume(returning: results as? [HKWorkoutRoute] ?? [])
            }
            store.execute(query)
        }
        guard let series = routeSamples.first else { return [] }

        return await withCheckedContinuation { continuation in
            var points: [CLLocationCoordinate2D] = []
            var resumed = false
            // HKWorkoutRouteQuery calls back repeatedly until `done`; resuming
            // twice would trap, so the flag is not optional politeness.
            let query = HKWorkoutRouteQuery(route: series) { _, locations, done, _ in
                points.append(contentsOf: (locations ?? []).map(\.coordinate))
                guard done, !resumed else { return }
                resumed = true
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    private static func meters(of workout: HKWorkout) -> Double {
        let identifier: HKQuantityTypeIdentifier = workout.workoutActivityType == .cycling
            ? .distanceCycling
            : .distanceWalkingRunning
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier),
              let statistics = workout.statistics(for: type),
              let sum = statistics.sumQuantity() else { return 0 }
        return sum.doubleValue(for: .meter())
    }

    /// Only the activity types that are travel. A pool swim is not a trip.
    private static func kind(for type: HKWorkoutActivityType) -> MotionKind? {
        switch type {
        case .cycling, .handCycling: return .cycling
        case .running: return .running
        case .walking, .hiking: return .walking
        default: return nil
        }
    }
}
#endif
