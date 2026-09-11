import Foundation
import CoreLocation

/// Whether a finished stay is worth interrupting someone for.
///
/// The failure mode this guards against is not missing a notification, it is
/// sending three too many and having the user turn them off for good. Home and
/// work must never produce one.
enum VisitNotificationPolicy {
    static let minimumDuration: TimeInterval = 10 * 60
    static let worstUsableAccuracy: CLLocationAccuracy = 250
    static let dailyCap = 3
    static let quietFrom = 22
    static let quietUntil = 7

    enum Decision: Equatable {
        case notify
        /// Recorded silently — the place is already named, or not worth asking about.
        case silent(String)
        /// Worth asking about, but not right now. Held for the morning summary.
        case hold(String)
    }

    struct Context {
        var stop: CapturedStop
        var match: PlaceClusterer.Match
        /// The place already carries a name the user chose or Google supplied.
        var isNamed: Bool
        var sentToday: Int
        var now: Date
        var calendar: Calendar = .current

        init(
            stop: CapturedStop,
            match: PlaceClusterer.Match,
            isNamed: Bool,
            sentToday: Int,
            now: Date,
            calendar: Calendar = .current
        ) {
            self.stop = stop
            self.match = match
            self.isNamed = isNamed
            self.sentToday = sentToday
            self.now = now
            self.calendar = calendar
        }
    }

    static func decide(_ context: Context) -> Decision {
        guard context.stop.isClosed else { return .silent("stay still open") }
        guard context.stop.duration >= minimumDuration else { return .silent("stay too short") }
        guard context.isNamed == false else { return .silent("place already named") }
        let accuracy = context.stop.horizontalAccuracy
        guard !accuracy.isFinite || accuracy <= worstUsableAccuracy else {
            return .silent("fix too coarse to guess a place")
        }
        guard context.sentToday < dailyCap else { return .hold("daily cap reached") }
        guard !isQuiet(context.now, calendar: context.calendar) else { return .hold("quiet hours") }
        return .notify
    }

    static func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= quietFrom || hour < quietUntil
    }

    /// "Stayed 47 minutes near Commercial Drive" reads as a record of something
    /// that happened; a present-tense "you're at…" would be a lie, because a
    /// CLVisit departure lands several minutes late.
    static func durationPhrase(_ duration: TimeInterval) -> String {
        // Clamp first: a stay that rounds down to zero still reads as one minute,
        // and the plural has to agree with the number actually shown.
        let minutes = max(Int((duration / 60).rounded()), 1)
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(hours)h \(rest)m"
    }

    static func timeRange(_ stop: CapturedStop, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.dateFormat = nil
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        guard let end = stop.end else { return formatter.string(from: stop.start) }
        return "\(formatter.string(from: stop.start))–\(formatter.string(from: end))"
    }
}
