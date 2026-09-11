#if os(iOS)
import Foundation
import UserNotifications

/// What the user tapped on a visit notification.
struct VisitNameChoice {
    let placeKey: String
    /// Chosen name, or nil when they asked to pick something else themselves.
    let name: String?
    /// Set when the chosen suggestion was a place they already visit, in which
    /// case this stay should fold into it rather than become a second place.
    let mergeInto: String?
    let opensRenameSheet: Bool
}

/// Local notifications for finished stays, with the name guesses as actions.
///
/// Notification action titles are fixed when a category is registered, so a
/// category is registered per notification with that stay's guesses in it. The
/// set is trimmed to the last few so it does not grow without bound.
@MainActor
final class VisitNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = VisitNotifier()

    /// Held when the app was launched by the tap and nothing is listening yet.
    private(set) var pendingChoice: VisitNameChoice?

    private let center = UNUserNotificationCenter.current()
    private var categoryIDs: [String] = []
    private var categories: [String: UNNotificationCategory] = [:]

    private enum ActionID {
        static let guessPrefix = "guess."
        static let other = "other"
    }

    private enum InfoKey {
        static let placeKey = "placeKey"
        static let titles = "titles"
        static let targets = "targets"
    }

    func start() {
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            TimelineLog.error("notification authorization failed", ["error": error.localizedDescription])
            return false
        }
    }

    var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    /// Past tense on purpose: a CLVisit departure lands minutes late, so "you're
    /// at…" would be a small lie every single time.
    func notify(stop: CapturedStop, placeKey: String, guesses: [PlaceNameSuggestion], areaHint: String?) async {
        guard await isAuthorized else { return }
        let identifier = "visit.\(placeKey).\(Int(stop.start.timeIntervalSince1970))"
        let category = registerCategory(for: identifier, guesses: guesses)

        let content = UNMutableNotificationContent()
        let duration = VisitNotificationPolicy.durationPhrase(stop.duration)
        if let areaHint, !areaHint.isEmpty {
            content.title = "Stayed \(duration) near \(areaHint)"
        } else {
            content.title = "Stayed \(duration) here"
        }
        if let first = guesses.first {
            content.body = "\(VisitNotificationPolicy.timeRange(stop)) · is this \(first.title)?"
        } else {
            content.body = "\(VisitNotificationPolicy.timeRange(stop)) · tap to name this place"
        }
        content.categoryIdentifier = category
        content.interruptionLevel = .active
        content.sound = nil
        content.userInfo = [
            InfoKey.placeKey: placeKey,
            InfoKey.titles: guesses.map(\.title),
            InfoKey.targets: guesses.map { $0.targetPlaceID ?? "" },
        ]

        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            TimelineLog.info("visit notification sent", ["placeKey": placeKey, "guesses": "\(guesses.count)"])
        } catch {
            TimelineLog.error("visit notification failed", ["error": error.localizedDescription])
        }
    }

    /// One notification for everything held overnight or over the daily cap.
    func notifyHeldSummary(count: Int) async {
        guard count > 0, await isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(count) place\(count == 1 ? "" : "s") to name"
        content.body = "Stays from yesterday are waiting for a name in Places."
        content.interruptionLevel = .passive
        try? await center.add(
            UNNotificationRequest(identifier: "visit.summary", content: content, trigger: nil)
        )
    }

    private func registerCategory(for identifier: String, guesses: [PlaceNameSuggestion]) -> String {
        var actions: [UNNotificationAction] = guesses.prefix(2).enumerated().map { index, guess in
            UNNotificationAction(
                identifier: "\(ActionID.guessPrefix)\(index)",
                title: guess.title,
                options: []
            )
        }
        actions.append(
            UNNotificationAction(
                identifier: ActionID.other,
                title: guesses.isEmpty ? "Name this place" : "Something else",
                options: [.foreground]
            )
        )
        categories[identifier] = UNNotificationCategory(
            identifier: identifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        categoryIDs.append(identifier)
        // Action titles are baked in at registration, so each stay needs its own
        // category. Keep the last handful; older notifications are long gone.
        while categoryIDs.count > 8 {
            categories.removeValue(forKey: categoryIDs.removeFirst())
        }
        center.setNotificationCategories(Set(categories.values))
        return identifier
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let placeKey = info[InfoKey.placeKey] as? String else { return }
        let titles = info[InfoKey.titles] as? [String] ?? []
        let targets = info[InfoKey.targets] as? [String] ?? []
        let action = response.actionIdentifier

        let choice: VisitNameChoice
        if action.hasPrefix(ActionID.guessPrefix),
           let index = Int(action.dropFirst(ActionID.guessPrefix.count)),
           index < titles.count {
            let target = index < targets.count && !targets[index].isEmpty ? targets[index] : nil
            choice = VisitNameChoice(
                placeKey: placeKey,
                name: titles[index],
                mergeInto: target,
                opensRenameSheet: false
            )
        } else {
            // "Something else" and a plain tap both mean: let me do this myself.
            choice = VisitNameChoice(placeKey: placeKey, name: nil, mergeInto: nil, opensRenameSheet: true)
        }
        await MainActor.run {
            VisitNotifier.shared.deliver(choice)
        }
    }

    func deliver(_ choice: VisitNameChoice) {
        pendingChoice = choice
        NotificationCenter.default.post(name: .visitNameChosen, object: nil)
    }

    func takePendingChoice() -> VisitNameChoice? {
        defer { pendingChoice = nil }
        return pendingChoice
    }
}

extension Notification.Name {
    static let visitNameChosen = Notification.Name("visitNameChosen")
}
#endif
