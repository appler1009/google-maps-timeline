import Foundation

/// Fills the silence between a stay and the next journey.
///
/// If the last thing known is that you were at home, and nothing recorded you
/// travelling since, then you were still at home. `CLVisit` only reports
/// transitions it witnesses, so a night at home either side of a gap in
/// monitoring leaves no row at all — but the absence of any trip is itself
/// evidence, and Core Motion records trips without needing location.
///
/// These stays are derived, never stored: both devices compute the same thing
/// from the same rows, and a later import that covers the gap simply removes it.
enum StayGapFiller {
    /// Shorter than this is the pause between parking and walking in, not a stay.
    static let minimumGap: TimeInterval = 30 * 60
    /// Longer than this and we are asserting something about days we never saw.
    static let maximumGap: TimeInterval = 36 * 60 * 60
    /// A walk this short is pottering, not leaving: round the block, out to the
    /// bins, down to the lobby for a parcel.
    static let potteringDuration: TimeInterval = 10 * 60
    /// …unless it actually covered ground. Ten minutes of walking is about
    /// eight hundred metres, so anything beyond this went somewhere.
    static let potteringDistance: Double = 800

    /// Did this journey mean leaving, or just moving about?
    ///
    /// Treating every recorded trip as a departure is what lost the night at
    /// home: the last thing recorded that evening was a four-minute walk, and it
    /// ended the stay as surely as a drive to another city would have. A walk
    /// that short cannot take you anywhere you did not come straight back from.
    static func isDeparture(_ trip: TimelineActivity) -> Bool {
        let duration = trip.end.timeIntervalSince(trip.start)
        guard case .walking = trip.kind else { return true }
        guard duration <= potteringDuration else { return true }
        // Distance is zero when there were no fixes to measure it with, which is
        // not evidence of going somewhere.
        return trip.distance > potteringDistance
    }

    /// One inferred stay per gap, continuing the place the gap opened at.
    ///
    /// Walks the sorted rows rather than scanning them: a library holds tens of
    /// thousands of stays, and a scan per stay turned assembly from milliseconds
    /// into seconds.
    static func fill(
        visits: [TimelineVisit],
        trips: [TimelineActivity],
        now: Date
    ) -> [TimelineVisit] {
        guard !visits.isEmpty else { return [] }
        let orderedVisits = visits.sorted { $0.start < $1.start }
        // Pottering neither opens a gap nor closes one: the stay simply continues
        // through it.
        let orderedTrips = trips.filter(isDeparture).sorted { $0.start < $1.start }

        let visitStarts = orderedVisits.map(\.start)
        let tripStarts = orderedTrips.map(\.start)
        // Ends are not sorted, so carry the furthest end seen so far. That is what
        // answers "were we still mid-journey when this gap opened".
        let visitReach = runningMaximum(of: orderedVisits.map(\.end))
        let tripReach = runningMaximum(of: orderedTrips.map(\.end))

        var filled: [TimelineVisit] = []
        for visit in orderedVisits {
            let from = visit.end

            let nextTripIndex = firstIndex(in: tripStarts, after: from)
            let nextVisitIndex = firstIndex(in: visitStarts, after: from)

            // Something already covers this moment, so there is no gap to fill.
            if nextTripIndex > 0, tripReach[nextTripIndex - 1] > from { continue }
            if nextVisitIndex > 0, visitReach[nextVisitIndex - 1] > from { continue }

            let nextTrip = nextTripIndex < tripStarts.count ? tripStarts[nextTripIndex] : nil
            let nextVisit = nextVisitIndex < visitStarts.count ? visitStarts[nextVisitIndex] : nil
            guard let until = [nextTrip, nextVisit, now]
                .compactMap({ $0 })
                .filter({ $0 > from })
                .min() else { continue }

            let gap = until.timeIntervalSince(from)
            guard gap >= minimumGap, gap <= maximumGap else { continue }

            filled.append(
                TimelineVisit(
                    id: Geo.segmentID("gv", Geo.millis(from), visit.placeKey),
                    start: from,
                    end: until,
                    coordinate: visit.coordinate,
                    semanticType: visit.semanticType,
                    placeKey: visit.placeKey,
                    isDerived: true
                )
            )
        }
        return filled
    }

    /// `result[i]` is the latest end among the first `i + 1` rows.
    static func runningMaximum(of ends: [Date]) -> [Date] {
        var furthest = Date.distantPast
        return ends.map { end in
            furthest = max(furthest, end)
            return furthest
        }
    }

    /// Index of the first start strictly after `value`, by bisection.
    static func firstIndex(in starts: [Date], after value: Date) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] > value {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
