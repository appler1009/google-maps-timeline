import Foundation

/// What the model came back with.
struct ModelPlaceChoice: Equatable, Sendable {
    /// Must be one of the titles it was offered; anything else is discarded.
    let title: String
    let confidence: Double
    /// One short phrase, shown to the user so a wrong guess is legible rather
    /// than mysterious.
    let reason: String
}

/// The inference step, behind a protocol so everything around it can be tested
/// without a model — and so devices without one simply do not have it.
protocol PlaceChoosing: Sendable {
    var isAvailable: Bool { get }
    func choose(from titles: [String], prompt: String) async throws -> ModelPlaceChoice
}

/// Re-ranks candidates with an on-device language model, but only when the
/// measurable evidence is genuinely ambiguous.
///
/// The heuristic ranker settles the cases that are really statistics — a place
/// you already go, a candidate ten metres away. What it cannot do is know that
/// forty minutes at 12:30 is lunch. That is the gap this fills, and it is the
/// common case here, because the app only ever asks about places with no name
/// yet, which are usually first visits.
struct ModelPlaceRanker: PlaceRanking {
    /// Above this the measurable evidence already picked a clear winner.
    static let confidenceFloor = 0.25
    /// Asking about more than this wastes context on candidates nobody would pick.
    static let shortlistSize = 5
    /// A notification that arrives late is worse than one ranked by distance.
    static let defaultTimeout: Duration = .seconds(8)

    let heuristic: HeuristicPlaceRanker
    let chooser: any PlaceChoosing
    let timeout: Duration

    init(
        heuristic: HeuristicPlaceRanker = HeuristicPlaceRanker(),
        chooser: any PlaceChoosing,
        timeout: Duration = ModelPlaceRanker.defaultTimeout
    ) {
        self.heuristic = heuristic
        self.chooser = chooser
        self.timeout = timeout
    }

    func rank(
        _ candidates: [PlaceNameSuggestion],
        context: VisitNamingContext
    ) async -> [PlaceNameSuggestion] {
        let ordered = await heuristic.rank(candidates, context: context)
        guard chooser.isAvailable, ordered.count > 1 else { return ordered }

        let confidence = heuristic.confidence(candidates, context: context)
        guard confidence < Self.confidenceFloor else { return ordered }

        let shortlist = Array(ordered.prefix(Self.shortlistSize))
        let titles = shortlist.map(\.title)
        let prompt = PlaceNamingPrompt.build(context: context, candidates: shortlist)

        guard let choice = await chosen(from: titles, prompt: prompt) else { return ordered }
        // The model is constrained to these titles, but a constraint is not a
        // guarantee: if it answers with something that was never offered, the
        // measurable ranking stands.
        guard let winner = shortlist.first(where: { $0.title == choice.title }) else {
            TimelineLog.info("place model answered off-list", ["title": choice.title])
            return ordered
        }
        TimelineLog.info(
            "place model reranked",
            ["title": winner.title, "confidence": String(format: "%.2f", choice.confidence)]
        )
        return [winner] + ordered.filter { $0.id != winner.id }
    }

    private func chosen(from titles: [String], prompt: String) async -> ModelPlaceChoice? {
        await withTaskGroup(of: ModelPlaceChoice?.self) { group in
            group.addTask {
                try? await chooser.choose(from: titles, prompt: prompt)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Builds the prompt. Pure and separate, because the prompt is the part worth
/// reviewing and the only part that can be tested deterministically.
enum PlaceNamingPrompt {
    /// Worked examples were a mistake here: given one, the model repeated its
    /// wording back as the reason and ignored the hour it had actually been
    /// given. These instructions describe how to weigh the facts instead.
    static let instructions = """
        You identify which nearby place a person most likely visited.
        Weigh only the facts given: the day, the stated arrival time and part of \
        day, how long the stay lasted, where they arrived from, any earlier stays \
        at the same spot, and the kind of each candidate.
        Do not assume a time of day that was not stated. Do not assume a stay was \
        short or long except by comparing it to how long people usually spend at \
        that kind of place.
        Answer with one of the candidate names exactly as written. Never invent a \
        name. If nothing fits well, choose the nearest candidate and say so.
        Give the reason as a short phrase naming the facts you used.
        """

    static func build(context: VisitNamingContext, candidates: [PlaceNameSuggestion]) -> String {
        var lines: [String] = []
        lines.append(
            "Stay: \(context.weekday), arrived \(context.startTime) (\(context.partOfDay)), "
                + "stayed \(context.durationMinutes) minutes."
        )
        if let cameFrom = context.cameFrom {
            lines.append("Arrived from: \(cameFrom).")
        }

        if context.isFirstVisitHere {
            lines.append("This is the first recorded stay at this spot.")
        } else {
            lines.append("Earlier stays at this exact spot:")
            for visit in context.priorVisitsHere {
                lines.append("- \(visit.weekday) \(visit.startTime), \(visit.durationPhrase)")
            }
        }

        if !context.routine.isEmpty {
            lines.append("Their usual places:")
            for entry in context.routine {
                lines.append("- \(entry.name), typically \(entry.typicalHours) (\(entry.visitCount) stays)")
            }
        }

        lines.append("Candidates:")
        for candidate in candidates {
            var parts = ["\(candidate.title)"]
            if let category = candidate.category, !category.isEmpty {
                parts.append("kind: \(category)")
            }
            if candidate.distanceMeters.isFinite {
                parts.append("\(Int(candidate.distanceMeters)) m away")
            }
            if candidate.visitCount > 0 {
                parts.append("visited \(candidate.visitCount) times before")
            }
            lines.append("- " + parts.joined(separator: ", "))
        }
        lines.append("Which candidate is this place?")
        return lines.joined(separator: "\n")
    }
}

/// A chooser for devices that have no model. Keeps the wiring uniform so the
/// recorder never has to branch on availability.
struct UnavailableChooser: PlaceChoosing {
    var isAvailable: Bool { false }
    func choose(from titles: [String], prompt: String) async throws -> ModelPlaceChoice {
        throw CocoaError(.featureUnsupported)
    }
}
