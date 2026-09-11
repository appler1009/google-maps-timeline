import Foundation

/// Turns rows from the library into the handful of facts worth reasoning about.
///
/// The temptation is to hand over seven days of everything. That spends the
/// budget on noise: most stays say nothing about the one in question. Three
/// things carry nearly all the signal — what happened at this exact place
/// before, what the person's routine looks like, and where they just came from.
enum VisitNamingContextBuilder {
    /// Prior visits worth showing. Beyond a handful it is a list, not a pattern.
    static let maximumPriorVisits = 5
    /// Named places to describe as routine.
    static let maximumRoutineEntries = 3
    /// A trip longer than this tells us nothing about where we ended up.
    static let recentArrivalWindow: TimeInterval = 3 * 60 * 60

    static func build(
        stop: CapturedStop,
        placeKey: String,
        recentVisits: [TimelineVisit],
        priorVisitsHere: [TimelineVisit],
        names: [String: String],
        calendar: Calendar = .current
    ) -> VisitNamingContext {
        let startMinutes = minutesSinceMidnight(stop.start, calendar: calendar)
        let duration = Int(stop.duration / 60)

        return VisitNamingContext(
            weekday: weekdayName(stop.start, calendar: calendar),
            startMinutes: startMinutes,
            startTime: clockTime(stop.start, calendar: calendar),
            partOfDay: partOfDay(minutes: startMinutes),
            durationMinutes: duration,
            durationPhrase: VisitNotificationPolicy.durationPhrase(stop.duration),
            priorVisitsHere: priorVisits(priorVisitsHere, excluding: stop, calendar: calendar),
            routine: routine(from: recentVisits, names: names, calendar: calendar),
            cameFrom: cameFrom(stop: stop, recentVisits: recentVisits, names: names, calendar: calendar)
        )
    }

    static func priorVisits(
        _ visits: [TimelineVisit],
        excluding stop: CapturedStop,
        calendar: Calendar
    ) -> [VisitNamingContext.PriorVisit] {
        visits
            .filter { abs($0.start.timeIntervalSince(stop.start)) > 60 }
            .sorted { $0.start > $1.start }
            .prefix(maximumPriorVisits)
            .map { visit in
                VisitNamingContext.PriorVisit(
                    weekday: weekdayName(visit.start, calendar: calendar),
                    startTime: clockTime(visit.start, calendar: calendar),
                    durationPhrase: VisitNotificationPolicy.durationPhrase(visit.duration)
                )
            }
    }

    /// The named places someone actually uses, with the hours they use them.
    static func routine(
        from visits: [TimelineVisit],
        names: [String: String],
        calendar: Calendar
    ) -> [VisitNamingContext.RoutineEntry] {
        var byPlace: [String: [TimelineVisit]] = [:]
        for visit in visits {
            guard let name = names[visit.placeKey], !name.isEmpty else { continue }
            byPlace[visit.placeKey, default: []].append(visit)
        }
        return byPlace
            .compactMap { key, visits -> (VisitNamingContext.RoutineEntry, Int)? in
                guard let name = names[key], !visits.isEmpty else { return nil }
                let starts = visits.map { minutesSinceMidnight($0.start, calendar: calendar) }
                let ends = visits.map { minutesSinceMidnight($0.end, calendar: calendar) }
                let entry = VisitNamingContext.RoutineEntry(
                    name: name,
                    typicalHours: "\(clock(minutes: median(starts)))–\(clock(minutes: median(ends)))",
                    visitCount: visits.count
                )
                return (entry, visits.count)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maximumRoutineEntries)
            .map(\.0)
    }

    /// The stay we left to get here, when it was recent enough to be related.
    static func cameFrom(
        stop: CapturedStop,
        recentVisits: [TimelineVisit],
        names: [String: String],
        calendar: Calendar
    ) -> String? {
        let previous = recentVisits
            .filter { $0.end <= stop.start && stop.start.timeIntervalSince($0.end) < recentArrivalWindow }
            .max { $0.end < $1.end }
        guard let previous else { return nil }
        let gap = Int(stop.start.timeIntervalSince(previous.end) / 60)
        let name = names[previous.placeKey]
            ?? TimelineParser.semanticTitle(previous.semanticType)
            ?? "somewhere unnamed"
        if gap <= 1 { return name }
        return "\(name), \(gap) minute\(gap == 1 ? "" : "s") earlier"
    }

    /// Plain words for the hour, so nothing has to be inferred from "12:30".
    static func partOfDay(minutes: Int) -> String {
        switch minutes {
        case ..<(5 * 60): return "the middle of the night"
        case ..<(8 * 60): return "early morning"
        case ..<(11 * 60): return "mid-morning"
        case ..<(14 * 60): return "midday"
        case ..<(17 * 60): return "afternoon"
        case ..<(21 * 60): return "evening"
        default: return "late evening"
        }
    }

    // MARK: - Formatting

    static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    static func clockTime(_ date: Date, calendar: Calendar) -> String {
        clock(minutes: minutesSinceMidnight(date, calendar: calendar))
    }

    static func minutesSinceMidnight(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func clock(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
