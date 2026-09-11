#if os(iOS)
import Foundation
import CoreMotion

/// Core Motion, which is the whole reason movement typing is affordable.
///
/// The phone classifies motion all day on its coprocessor whether we ask or not,
/// and keeps roughly seven days of it. So the recorder does not stream: it wakes
/// for some other reason and collects the window it missed.
final class DeviceMotionSource: MotionSource {
    private let manager = CMMotionActivityManager()
    private let queue = OperationQueue()
    private var isLive = false

    init() {
        queue.name = "timeline.motion"
        queue.maxConcurrentOperationCount = 1
    }

    var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    var isAuthorized: Bool { CMMotionActivityManager.authorizationStatus() == .authorized }

    func samples(from: Date, to: Date) async -> [MotionSample] {
        guard isAvailable, to > from else { return [] }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: from, to: to, to: queue) { activities, error in
                if let error {
                    TimelineLog.error("motion query failed", ["error": error.localizedDescription])
                }
                continuation.resume(returning: (activities ?? []).map(Self.sample))
            }
        }
    }

    func startLiveUpdates(_ handler: @escaping (MotionSample) -> Void) {
        guard isAvailable, !isLive else { return }
        isLive = true
        manager.startActivityUpdates(to: queue) { activity in
            guard let activity else { return }
            handler(Self.sample(activity))
        }
    }

    func stopLiveUpdates() {
        guard isLive else { return }
        isLive = false
        manager.stopActivityUpdates()
    }

    /// CMMotionActivity sets a flag per kind and can set several at once. Pick the
    /// most specific one that is set, since "automotive + stationary" is a car at
    /// a red light, not a stay.
    private static func sample(_ activity: CMMotionActivity) -> MotionSample {
        let kind: MotionKind
        if activity.cycling {
            kind = .cycling
        } else if activity.running {
            kind = .running
        } else if activity.automotive {
            kind = .automotive
        } else if activity.walking {
            kind = .walking
        } else if activity.stationary {
            kind = .stationary
        } else {
            kind = .unknown
        }
        return MotionSample(
            start: activity.startDate,
            kind: kind,
            confidence: activity.confidence.rawValue
        )
    }
}
#endif
