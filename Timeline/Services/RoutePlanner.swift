import Foundation
import CoreLocation

enum RoutePlanner {
    static func plannedHops(for day: DayRecord) -> [(id: String, points: [CLLocationCoordinate2D], kind: TravelKind, at: Date, until: Date)] {
        let spots = collapsedSpots(day.visits)
        if spots.count >= 2 {
            var hops: [(id: String, points: [CLLocationCoordinate2D], kind: TravelKind, at: Date, until: Date)] = []
            for index in 0..<(spots.count - 1) {
                hops.append(contentsOf: hopsAcross(from: spots[index], to: spots[index + 1], activities: day.activityLines))
            }
            return hops
        }
        // One geocoded place for the day — don't invent loops from activity noise.
        if spots.count == 1 {
            return []
        }
        let lines = day.activityLines.filter { $0.until > $0.at }.sorted { $0.at < $1.at }
        if !lines.isEmpty {
            return lines.map { line in
                (id: line.id, points: [line.start, line.end], kind: line.kind, at: line.at, until: line.until)
            }
        }
        return day.paths.filter { $0.points.count >= 2 }.map { path in
            (id: path.id, points: path.points, kind: path.kind, at: path.start, until: path.end)
        }
    }

    /// Consecutive same-place (or <50m) stays collapse so hops run place-to-place.
    ///
    /// A collapsed spot spans the whole run, because the hops either side of it
    /// are timed from its edges: you arrived when the run began and left when it
    /// ended. Taking both from the last stay in the run made the journey *into*
    /// a place look as long as the stay itself — an eight-minute drive home,
    /// followed by five hours indoors and a walk round the block, was timed as a
    /// five-hour crawl, and read as a walk.
    static func collapsedSpots(_ visits: [TimelineVisit]) -> [(TimelineVisit, CLLocationCoordinate2D)] {
        var spots: [(TimelineVisit, CLLocationCoordinate2D)] = []
        for run in PlaceVisitRun.coalesced(from: visits) {
            guard let visit = run.visits.last(where: { $0.coordinate != nil }),
                  let coordinate = visit.coordinate else { continue }
            let spanned = spanning(visit, over: run.visits)
            if let last = spots.last, meters(last.1, coordinate) < 50 {
                spots[spots.count - 1] = (spanning(spanned, over: [last.0, spanned]), coordinate)
                continue
            }
            spots.append((spanned, coordinate))
        }
        return spots
    }

    /// The representative stay stretched across everything it stands for. Keeps
    /// its own id, which hop ids are built from.
    private static func spanning(
        _ representative: TimelineVisit,
        over visits: [TimelineVisit]
    ) -> TimelineVisit {
        let start = visits.map(\.start).min() ?? representative.start
        let end = visits.map(\.end).max() ?? representative.end
        guard start != representative.start || end != representative.end else { return representative }
        return TimelineVisit(
            id: representative.id,
            start: start,
            end: end,
            coordinate: representative.coordinate,
            semanticType: representative.semanticType,
            placeKey: representative.placeKey,
            isDerived: representative.isDerived
        )
    }

    static func hopsAcross(
        from: (TimelineVisit, CLLocationCoordinate2D),
        to: (TimelineVisit, CLLocationCoordinate2D),
        activities: [ActivityLine]
    ) -> [(id: String, points: [CLLocationCoordinate2D], kind: TravelKind, at: Date, until: Date)] {
        if from.0.placeKey == to.0.placeKey || meters(from.1, to.1) < 40 {
            return []
        }
        let gapStart = from.0.end
        let gapEnd = to.0.start > gapStart ? to.0.start : gapStart.addingTimeInterval(1)
        let overlapping = activities
            .filter { $0.at < gapEnd && $0.until > gapStart }
            .sorted { $0.at < $1.at }
        var runs: [ActivityLine] = []
        for activity in overlapping {
            if let last = runs.last, last.kind == activity.kind, meters(last.end, activity.start) < 80 {
                runs[runs.count - 1] = ActivityLine(
                    id: last.id,
                    at: last.at,
                    until: activity.until,
                    start: last.start,
                    end: activity.end,
                    kind: last.kind
                )
            } else {
                runs.append(activity)
            }
        }
        if runs.count <= 1 {
            let travelKind = kind(from: from.0, to: to.0, activities: activities)
            return [(
                id: "hop:\(from.0.id):\(to.0.id)",
                points: [from.1, to.1],
                kind: travelKind,
                at: gapStart,
                until: gapEnd
            )]
        }
        var hops: [(id: String, points: [CLLocationCoordinate2D], kind: TravelKind, at: Date, until: Date)] = []
        var prev = from.1
        var prevAt = gapStart
        for (index, run) in runs.enumerated() {
            let dest = index == runs.count - 1 ? to.1 : run.end
            let until = index == runs.count - 1 ? gapEnd : run.until
            if meters(prev, dest) >= 40 {
                hops.append((
                    id: "hop:\(from.0.id):\(to.0.id):\(run.id):\(index)",
                    points: [prev, dest],
                    kind: run.kind,
                    at: prevAt,
                    until: until
                ))
            }
            prev = dest
            prevAt = until
        }
        return hops
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func kind(from: TimelineVisit, to: TimelineVisit, activities: [ActivityLine]) -> TravelKind {
        let gapStart = from.end
        let gapEnd = to.start > gapStart ? to.start : gapStart.addingTimeInterval(1)
        let gap = gapEnd.timeIntervalSince(gapStart)
        let overlapping = activities.filter { $0.at < gapEnd && $0.until > gapStart }
        guard let match = overlapping.max(by: { lhs, rhs in
            overlap(lhs, gapStart: gapStart, gapEnd: gapEnd) < overlap(rhs, gapStart: gapStart, gapEnd: gapEnd)
        }) else {
            return inferredKind(from: from, to: to, seconds: gap)
        }
        // Speed over the time actually spent moving, not the whole gap. Leaving
        // the shops at 11 and reaching home at 16 is a five-hour gap around an
        // eight-minute drive; measured against the gap every such drive looks
        // like a stroll, and the override below would then discard Core Motion
        // saying plainly that it was a car.
        let moving = overlapping.reduce(0.0) { total, line in
            total + max(0, overlap(line, gapStart: gapStart, gapEnd: gapEnd))
        }
        let inferred = inferredKind(from: from, to: to, seconds: moving > 0 ? moving : gap)
        // Core Motion reports the car you were sitting in, which bleeds into the
        // walk at either end of the journey. A genuinely slow hop is that walk.
        if match.kind == .automobile, inferred == .walking {
            return .walking
        }
        return match.kind
    }

    private static func overlap(_ activity: ActivityLine, gapStart: Date, gapEnd: Date) -> TimeInterval {
        min(activity.until, gapEnd).timeIntervalSince(max(activity.at, gapStart))
    }

    private static func inferredKind(
        from: TimelineVisit,
        to: TimelineVisit,
        seconds: TimeInterval
    ) -> TravelKind {
        guard let start = from.coordinate, let end = to.coordinate else { return .automobile }
        let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        if meters / max(seconds, 1) < 2.6 { return .walking }
        return .automobile
    }
}
