import Foundation
import CoreLocation

/// What to do about a day the phone recorded and an export also covers.
struct ReconciliationPlan: Equatable {
    /// Imported visits to hide, because the device recorded the same day with
    /// better timing. The rows stay in the table so this is reversible.
    var shadowedVisitIDs: Set<String> = []
    /// Device place key → the Google Place ID for the same place. Applied through
    /// the existing merge table, so the name, the photo strip and iCloud sync all
    /// follow for free.
    var placeAliases: [String: String] = [:]

    var isEmpty: Bool { shadowedVisitIDs.isEmpty && placeAliases.isEmpty }
}

/// Decides how recorded days and imported days live together.
///
/// Takeout stays: it is the only source for anything before the app was installed,
/// and it carries Google Place IDs, which are better identity than a rounded
/// coordinate will ever be. The two overlap for as long as exports keep arriving,
/// so this rule matters more than the capture code does.
///
/// Pure on purpose — no database, no clock — because it is the piece most likely
/// to produce visible bugs.
enum TimelineReconciler {
    /// Two stays this close, overlapping in time, are the same stay seen twice.
    static let matchRadius: CLLocationDistance = 120

    static func plan(
        device: [TimelineVisit],
        imported: [TimelineVisit],
        calendar: Calendar = .current
    ) -> ReconciliationPlan {
        guard !device.isEmpty, !imported.isEmpty else { return ReconciliationPlan() }

        var plan = ReconciliationPlan()
        let coveredDays = days(of: device, calendar: calendar)

        for visit in imported where !days(of: [visit], calendar: calendar).isDisjoint(with: coveredDays) {
            plan.shadowedVisitIDs.insert(visit.id)
        }

        // Longest overlap wins, so a short imported stay next door cannot claim a
        // device key that a better match wants.
        var claimed = Set<String>()
        for candidate in pairs(device: device, imported: imported).sorted(by: { $0.overlap > $1.overlap }) {
            guard isGooglePlaceID(candidate.importedKey) else { continue }
            guard candidate.deviceKey != candidate.importedKey else { continue }
            guard !claimed.contains(candidate.deviceKey) else { continue }
            claimed.insert(candidate.deviceKey)
            plan.placeAliases[candidate.deviceKey] = candidate.importedKey
        }
        return plan
    }

    /// A key with a comma is the rounded-coordinate fallback, which is no better
    /// an identity than the device's own key — only a real place id is worth
    /// folding into.
    static func isGooglePlaceID(_ key: String) -> Bool {
        !key.isEmpty && !key.contains(",")
    }

    private struct Candidate {
        let deviceKey: String
        let importedKey: String
        let overlap: TimeInterval
    }

    private static func pairs(device: [TimelineVisit], imported: [TimelineVisit]) -> [Candidate] {
        var found: [Candidate] = []
        for recorded in device {
            guard let here = recorded.coordinate else { continue }
            for other in imported {
                guard let there = other.coordinate else { continue }
                let overlap = min(recorded.end, other.end).timeIntervalSince(max(recorded.start, other.start))
                guard overlap > 0 else { continue }
                guard RoutePlanner.meters(here, there) <= matchRadius else { continue }
                found.append(
                    Candidate(deviceKey: recorded.placeKey, importedKey: other.placeKey, overlap: overlap)
                )
            }
        }
        return found
    }

    private static func days(of visits: [TimelineVisit], calendar: Calendar) -> Set<Date> {
        var result: Set<Date> = []
        for visit in visits {
            var day = calendar.startOfDay(for: visit.start)
            let last = calendar.startOfDay(for: visit.end)
            while day <= last {
                result.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return result
    }
}
