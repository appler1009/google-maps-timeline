import Foundation
import Observation

/// User-facing recorder preferences, plus the small amount of bookkeeping the
/// notification cap needs. Backed by UserDefaults so a background launch can read
/// it without touching the database.
@MainActor
@Observable
final class TrackingSettings {
    static let shared = TrackingSettings()

    private enum Key {
        static let mode = "trackingMode"
        static let notifyVisits = "trackingNotifyVisits"
        static let sentDay = "trackingNotifySentDay"
        static let sentCount = "trackingNotifySentCount"
        static let held = "trackingNotifyHeld"
        static let health = "trackingUsesHealth"
        static let cloud = "syncsWithCloud"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Key.mode) ?? TrackingMode.off.rawValue
        mode = TrackingMode(rawValue: raw) ?? .off
        notifiesVisits = defaults.object(forKey: Key.notifyVisits) as? Bool ?? true
        usesHealth = defaults.bool(forKey: Key.health)
        syncsWithCloud = defaults.bool(forKey: Key.cloud)
    }

    /// Stored, not computed: `@Observable` only tracks stored properties, and the
    /// settings screen has to redraw the moment the mode changes.
    var mode: TrackingMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Key.mode)
        }
    }

    var notifiesVisits: Bool {
        didSet {
            guard notifiesVisits != oldValue else { return }
            defaults.set(notifiesVisits, forKey: Key.notifyVisits)
        }
    }

    /// Off until asked for: HealthKit means an extra permission prompt that would
    /// be a surprise in a maps app, and everything works without it.
    var usesHealth: Bool {
        didSet {
            guard usesHealth != oldValue else { return }
            defaults.set(usesHealth, forKey: Key.health)
        }
    }

    /// Off until asked for. Sync needs an iCloud account, and the Mac cannot
    /// record — it only ever receives.
    var syncsWithCloud: Bool {
        didSet {
            guard syncsWithCloud != oldValue else { return }
            defaults.set(syncsWithCloud, forKey: Key.cloud)
        }
    }

    /// Notifications already sent today, reset on the first read of a new day.
    func sentToday(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        guard defaults.double(forKey: Key.sentDay) == day else { return 0 }
        return defaults.integer(forKey: Key.sentCount)
    }

    func recordSent(now: Date = Date(), calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        if defaults.double(forKey: Key.sentDay) == day {
            defaults.set(defaults.integer(forKey: Key.sentCount) + 1, forKey: Key.sentCount)
        } else {
            defaults.set(day, forKey: Key.sentDay)
            defaults.set(1, forKey: Key.sentCount)
        }
    }

    /// Place keys whose stays were worth asking about but arrived during quiet
    /// hours or over the cap. They become one morning summary.
    var heldPlaceKeys: [String] {
        get { defaults.stringArray(forKey: Key.held) ?? [] }
        set { defaults.set(Array(newValue.suffix(20)), forKey: Key.held) }
    }

    func hold(_ placeKey: String) {
        var held = heldPlaceKeys
        guard !held.contains(placeKey) else { return }
        held.append(placeKey)
        heldPlaceKeys = held
    }

    func clearHeld() {
        defaults.removeObject(forKey: Key.held)
    }
}
