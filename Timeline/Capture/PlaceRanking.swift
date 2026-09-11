import Foundation

/// Everything known about a stay at the moment we have to guess what it was.
///
/// Deliberately made of strings and small values rather than database rows: it is
/// both the input to the scorer and the thing a prompt is built from, and a shape
/// that reads well in a sentence is easier to check than one that reads well in
/// SQL.
struct VisitNamingContext: Equatable {
    /// "Tuesday"
    var weekday: String
    /// Minutes since midnight, so the scorer can do arithmetic on it.
    var startMinutes: Int
    /// "12:30"
    var startTime: String
    /// "midday". Computed here rather than left for the model to infer from the
    /// clock, because inferring it is exactly what it got wrong.
    var partOfDay: String
    var durationMinutes: Int
    /// "40 minutes"
    var durationPhrase: String
    /// Earlier stays at this same place — the strongest signal there is, and
    /// usually empty, because we only ask about places with no name yet.
    var priorVisitsHere: [PriorVisit]
    /// A couple of lines of routine: the named places and when they are used.
    var routine: [RoutineEntry]
    /// Where the person came from, when we know. "Work, 18 minutes ago"
    var cameFrom: String?

    struct PriorVisit: Equatable {
        var weekday: String
        var startTime: String
        var durationPhrase: String
    }

    struct RoutineEntry: Equatable {
        var name: String
        var typicalHours: String
        var visitCount: Int
    }

    var isFirstVisitHere: Bool { priorVisitsHere.isEmpty }
}

/// Orders the candidates for a stay, best first.
protocol PlaceRanking: Sendable {
    func rank(
        _ candidates: [PlaceNameSuggestion],
        context: VisitNamingContext
    ) async -> [PlaceNameSuggestion]
}

/// Ranks candidates from what can be measured: how near they are, whether they
/// are somewhere you already go, and whether a place of that kind is plausibly
/// where someone spends this long at this hour.
///
/// Deterministic, instant, and available on every device — the baseline anything
/// cleverer has to beat.
struct HeuristicPlaceRanker: PlaceRanking {
    /// Past this, a candidate is in a different building.
    static let usefulRadius: Double = 450

    func rank(
        _ candidates: [PlaceNameSuggestion],
        context: VisitNamingContext
    ) async -> [PlaceNameSuggestion] {
        scored(candidates, context: context).map(\.candidate)
    }

    struct Scored {
        let candidate: PlaceNameSuggestion
        let score: Double
    }

    func scored(
        _ candidates: [PlaceNameSuggestion],
        context: VisitNamingContext
    ) -> [Scored] {
        candidates
            .map { Scored(candidate: $0, score: Self.score($0, context: context)) }
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.001 { return lhs.score > rhs.score }
                return lhs.candidate.distanceMeters < rhs.candidate.distanceMeters
            }
    }

    /// How clearly the winner won. Low means the top two are interchangeable on
    /// the evidence we have, which is exactly when a language model is worth
    /// asking.
    func confidence(
        _ candidates: [PlaceNameSuggestion],
        context: VisitNamingContext
    ) -> Double {
        let ordered = scored(candidates, context: context)
        guard let best = ordered.first else { return 0 }
        guard ordered.count > 1 else { return best.score }
        return min(max(best.score - ordered[1].score, 0), 1)
    }

    static func score(_ candidate: PlaceNameSuggestion, context: VisitNamingContext) -> Double {
        var score = proximityScore(candidate.distanceMeters) * 0.4
        score += familiarityScore(candidate) * 0.35
        score += plausibilityScore(candidate.category, context: context) * 0.25
        if candidate.source == .address {
            // A street address is what you fall back to when nothing fits, not an
            // answer to "what is this place".
            score *= 0.6
        }
        return min(max(score, 0), 1)
    }

    static func proximityScore(_ meters: Double) -> Double {
        guard meters.isFinite, meters >= 0 else { return 0.2 }
        return max(0, 1 - meters / usefulRadius)
    }

    /// Somewhere you already go, weighted by how often — a place visited twenty
    /// times is not twice as likely as one visited ten, so this saturates.
    static func familiarityScore(_ candidate: PlaceNameSuggestion) -> Double {
        guard candidate.targetPlaceID != nil else { return 0 }
        return min(Double(candidate.visitCount), 10) / 10
    }

    /// Would someone plausibly spend this long, at this hour, at a place of this
    /// kind? Unknown categories score neutral rather than badly — most of the
    /// world is not in Apple's category list.
    static func plausibilityScore(_ category: String?, context: VisitNamingContext) -> Double {
        guard let profile = DwellProfile.profile(for: category) else { return 0.5 }
        let fitsDuration = profile.durationMinutes.contains(context.durationMinutes)
        let fitsHour = profile.fitsHour(context.startMinutes)
        switch (fitsDuration, fitsHour) {
        case (true, true): return 1
        case (true, false), (false, true): return 0.5
        case (false, false): return 0.1
        }
    }
}

/// How long people stay at a kind of place, and when.
///
/// Crude on purpose: this exists to rule out the obviously wrong — a four-hour
/// stay is not a coffee, an eight-minute stop is not a hotel — not to pick the
/// winner. Ruling out is what a fixed table can do honestly.
struct DwellProfile {
    let durationMinutes: ClosedRange<Int>
    /// Minutes since midnight. Empty means any time of day.
    let hourWindows: [ClosedRange<Int>]

    func fitsHour(_ minutes: Int) -> Bool {
        guard !hourWindows.isEmpty else { return true }
        return hourWindows.contains { $0.contains(minutes) }
    }

    private static func hours(_ from: Int, _ to: Int) -> ClosedRange<Int> {
        (from * 60)...(to * 60)
    }

    /// Apple's raw values drop the `MKPOICategory` prefix before they reach us.
    static func profile(for category: String?) -> DwellProfile? {
        guard let category, !category.isEmpty else { return nil }
        switch category.lowercased() {
        case "cafe", "bakery":
            return DwellProfile(durationMinutes: 5...120, hourWindows: [hours(5, 20)])
        case "restaurant", "foodmarket":
            return DwellProfile(durationMinutes: 20...180, hourWindows: [hours(11, 15), hours(17, 23)])
        case "brewery", "winery", "nightlife":
            return DwellProfile(durationMinutes: 30...300, hourWindows: [hours(15, 24)])
        case "fitnesscenter", "gym":
            return DwellProfile(durationMinutes: 25...150, hourWindows: [])
        case "hotel":
            return DwellProfile(durationMinutes: 360...2_880, hourWindows: [])
        case "airport":
            return DwellProfile(durationMinutes: 45...600, hourWindows: [])
        case "school", "university":
            return DwellProfile(durationMinutes: 60...600, hourWindows: [hours(7, 18)])
        case "hospital", "pharmacy":
            return DwellProfile(durationMinutes: 10...480, hourWindows: [])
        case "park", "beach", "nationalpark":
            return DwellProfile(durationMinutes: 15...480, hourWindows: [hours(6, 22)])
        case "store", "atm", "bank", "postoffice", "laundry":
            return DwellProfile(durationMinutes: 3...90, hourWindows: [hours(7, 22)])
        case "gasstation", "evcharger":
            return DwellProfile(durationMinutes: 3...60, hourWindows: [])
        case "movietheater", "theater", "museum":
            return DwellProfile(durationMinutes: 45...300, hourWindows: [hours(10, 24)])
        case "library":
            return DwellProfile(durationMinutes: 15...360, hourWindows: [hours(8, 21)])
        default:
            return nil
        }
    }
}
