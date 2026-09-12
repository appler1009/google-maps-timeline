import CoreLocation
import XCTest
@testable import Timeline

/// If the last thing known is that you were at home and nothing recorded you
/// travelling since, you were still at home. CLVisit only reports transitions it
/// witnesses, so a night either side of a monitoring gap leaves no row at all.
final class StayGapFillerTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ hours: Double) -> Date { origin.addingTimeInterval(hours * 3_600) }

    private func visit(_ id: String, from: Double, to: Double, place: String = "home") -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: at(from),
            end: at(to),
            coordinate: home,
            semanticType: place == "home" ? "Home" : nil,
            placeKey: place
        )
    }

    private func trip(_ id: String, from: Double, to: Double) -> TimelineActivity {
        TimelineActivity(
            id: id,
            start: at(from),
            end: at(to),
            distance: 5_000,
            startCoordinate: home,
            endCoordinate: home,
            kind: .automobile
        )
    }

    func testTheNightAtHomeIsFilledInUpToTheMorningDrive() {
        // Exactly the reported case: home in the evening, no rows overnight, and
        // the first thing the next morning is driving away.
        let visits = [visit("home-evening", from: 0, to: 2)]
        let trips = [trip("morning-drive", from: 16, to: 16.3)]
        let filled = StayGapFiller.fill(visits: visits, trips: trips, now: at(20))

        XCTAssertEqual(filled.count, 1)
        XCTAssertEqual(filled.first?.placeKey, "home")
        XCTAssertEqual(filled.first?.start, at(2), "it continues from where the last stay ended")
        XCTAssertEqual(filled.first?.end, at(16), "and ends when the driving starts")
        XCTAssertEqual(filled.first?.semanticType, "Home", "so it still reads as home")
    }

    func testATripInsideTheGapMeansItWasNotOneStay() {
        let visits = [visit("home", from: 0, to: 2)]
        let trips = [trip("out", from: 5, to: 5.5), trip("back", from: 8, to: 8.5)]
        let filled = StayGapFiller.fill(visits: visits, trips: trips, now: at(20))
        // The gap closes at the first trip, not the second.
        XCTAssertEqual(filled.count, 1)
        XCTAssertEqual(filled.first?.end, at(5))
    }

    func testAKnownStayInTheGapClosesIt() {
        let visits = [visit("home", from: 0, to: 2), visit("work", from: 6, to: 9, place: "work")]
        let filled = StayGapFiller.fill(visits: visits, trips: [], now: at(20))
        XCTAssertEqual(filled.count, 2, "the gap before work, and the one after it")
        XCTAssertEqual(filled.first?.end, at(6))
    }

    func testAShortGapIsNotAStay() {
        // Parking and walking in is not a separate stay at the car park.
        let visits = [visit("shop", from: 0, to: 1, place: "shop")]
        let trips = [trip("drive", from: 1.2, to: 1.5)]
        XCTAssertTrue(StayGapFiller.fill(visits: visits, trips: trips, now: at(5)).isEmpty)
    }

    func testAnAbsurdlyLongGapIsNotAsserted() {
        // A fortnight of silence says nothing about where someone was.
        let visits = [visit("home", from: 0, to: 2)]
        let trips = [trip("much-later", from: 24 * 14, to: 24 * 14 + 1)]
        XCTAssertTrue(StayGapFiller.fill(visits: visits, trips: trips, now: at(24 * 15)).isEmpty)
    }

    func testTheGapRunsToNowWhenNothingHasHappenedSince() {
        let visits = [visit("home", from: 0, to: 2)]
        let filled = StayGapFiller.fill(visits: visits, trips: [], now: at(6))
        XCTAssertEqual(filled.count, 1)
        XCTAssertEqual(filled.first?.end, at(6), "you are still there until something says otherwise")
    }

    func testAnEmptyLibraryInfersNothing() {
        XCTAssertTrue(StayGapFiller.fill(visits: [], trips: [], now: at(6)).isEmpty)
    }

    func testInferredStaysAreStableAcrossRuns() {
        let visits = [visit("home", from: 0, to: 2)]
        let trips = [trip("drive", from: 16, to: 16.3)]
        let first = StayGapFiller.fill(visits: visits, trips: trips, now: at(20))
        let second = StayGapFiller.fill(visits: visits, trips: trips, now: at(20))
        XCTAssertEqual(first.map(\.id), second.map(\.id), "recomputing must not churn ids")
    }

    func testAssemblyIncludesTheInferredStay() {
        let batch = TimelineBatch(
            visits: [visit("home", from: 0, to: 2)],
            activities: [trip("drive", from: 16, to: 16.3)],
            paths: []
        )
        let parsed = TimelineParser.assemble(batch, sourceName: "test", now: at(20))
        let allVisits = parsed.days.flatMap(\.visits)
        XCTAssertTrue(
            allVisits.contains { $0.id.hasPrefix(Geo.segmentID("gv", Geo.millis(at(2)), "home").prefix(8)) },
            "the day should show the inferred stay"
        )
    }
    /// The reported case: adding a school drop-off must split the morning at
    /// home, not end it.
    ///
    /// Home overnight, out at 08:35, a minute at the school gate at 08:45, back
    /// by 08:55, then out again at 10:34 to the shops. Before the drop-off was
    /// added this read as one stay at home until 10:34. Adding it used to delete
    /// the second half: the morning drive reached past home's last known row, so
    /// the gap was abandoned rather than resumed on the far side.
    func testADropOffSplitsTheMorningRatherThanEndingIt() {
        let visits = [
            visit("home-overnight", from: -8, to: 0),
            visit("school", from: 8.75, to: 8.77, place: "byng")
        ]
        // One continuous drive out and back, with the school stop inside it.
        let trips = [trip("school-run", from: 8.58, to: 8.92), trip("to-the-shops", from: 10.58, to: 10.83)]
        let filled = StayGapFiller.fill(visits: visits, trips: trips, now: at(12)).sorted { $0.start < $1.start }

        XCTAssertEqual(filled.count, 2, "the morning at home, in two halves")
        XCTAssertEqual(filled[0].placeKey, "home")
        XCTAssertEqual(filled[0].start, at(0))
        XCTAssertEqual(filled[0].end, at(8.58), "the first half ends when the school run begins")
        XCTAssertEqual(filled[1].placeKey, "home")
        XCTAssertEqual(filled[1].start, at(8.92), "the second half picks up when it gets back")
        XCTAssertEqual(filled[1].end, at(10.58), "and ends leaving for the shops")
    }

    /// The same journey with no stop recorded inside it is not accounted for.
    /// Somewhere unrecorded is not home, so the stay still ends there.
    func testAJourneyWithNothingInsideItStillEndsTheStay() {
        let visits = [visit("home-overnight", from: -8, to: 0)]
        let trips = [trip("out", from: 8.58, to: 8.92), trip("out-again", from: 10.58, to: 10.83)]
        let filled = StayGapFiller.fill(visits: visits, trips: trips, now: at(12))
        XCTAssertEqual(filled.count, 1)
        XCTAssertEqual(filled.first?.end, at(8.58))
    }

    /// And a journey that ended somewhere real does not resume the old stay,
    /// even though it carried a stop along the way.
    func testArrivingSomewhereEndsTheStayDespiteAWaypoint() {
        let visits = [
            visit("home", from: -8, to: 0),
            visit("school", from: 8.75, to: 8.77, place: "byng"),
            visit("work", from: 9.2, to: 17, place: "work")
        ]
        let trips = [trip("commute", from: 8.58, to: 9.1)]
        let filled = StayGapFiller.fill(visits: visits, trips: trips, now: at(20))
        XCTAssertTrue(
            filled.allSatisfy { $0.placeKey != "home" || $0.end <= self.at(8.58) },
            "home does not resume once the journey arrived at work"
        )
    }
}

/// A stay exported while it was still running arrives again each time its end
/// grows, because the visit id hashes the end as well as the start.
final class DuplicateVisitCollapseTests: XCTestCase {
    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupes-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func googleVisit(_ id: String, hours: Double) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: start,
            end: start.addingTimeInterval(hours * 3_600),
            coordinate: CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460),
            semanticType: "Home",
            placeKey: "ChIJhome"
        )
    }

    func testOnlyTheLongestOfThreeImportsSurvives() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        // The shape found in the real library: one evening, three rows.
        try await db.upsert(
            batch: TimelineBatch(
                visits: [
                    googleVisit("short", hours: 20),
                    googleVisit("longer", hours: 26),
                    googleVisit("longest", hours: 28),
                ],
                activities: [],
                paths: []
            ),
            sourceName: "Timeline.json"
        )

        let collapsed = try await db.collapseDuplicateVisits()
        XCTAssertEqual(collapsed, 2)

        let remaining = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(remaining.map(\.id), ["longest"], "the fullest version of the stay wins")
    }

    func testTheRemovalTravelsToTheOtherDevices() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.upsert(
            batch: TimelineBatch(visits: [googleVisit("a", hours: 2), googleVisit("b", hours: 3)], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        try await db.clearChangeLog()
        _ = try await db.collapseDuplicateVisits()

        let queued = try await db.pendingChanges()
        XCTAssertEqual(queued.map(\.operation), [.delete])
        XCTAssertEqual(queued.first?.rowID, "a")
    }

    func testDistinctStaysAreNotCollapsed() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let later = TimelineVisit(
            id: "different-start",
            start: start.addingTimeInterval(7_200),
            end: start.addingTimeInterval(10_800),
            coordinate: CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460),
            semanticType: "Home",
            placeKey: "ChIJhome"
        )
        try await db.upsert(
            batch: TimelineBatch(visits: [googleVisit("a", hours: 1), later], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        let collapsed = try await db.collapseDuplicateVisits()
        XCTAssertEqual(collapsed, 0, "two stays that began at different times are two stays")
    }

    func testASourceIsNotCollapsedAcross() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.upsert(
            batch: TimelineBatch(visits: [googleVisit("google-row", hours: 2)], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        try await db.record(batch: TimelineBatch(visits: [googleVisit("device-row", hours: 3)], activities: [], paths: []))

        let collapsed = try await db.collapseDuplicateVisits()
        XCTAssertEqual(collapsed, 0, "choosing between sources is reconciliation's job")
    }
}

/// A short walk is pottering, not leaving. Treating every recorded trip as a
/// departure is what lost the night at home.
final class PotteringTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ hours: Double) -> Date { origin.addingTimeInterval(hours * 3_600) }


    private func visit(_ id: String, from: Double, to: Double) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: at(from),
            end: at(to),
            coordinate: home,
            semanticType: "Home",
            placeKey: "home"
        )
    }

    private func trip(
        _ id: String,
        from: Double,
        to: Double,
        kind: TravelKind = .walking,
        metres: Double = 0
    ) -> TimelineActivity {
        TimelineActivity(
            id: id,
            start: at(from),
            end: at(to),
            distance: metres,
            startCoordinate: home,
            endCoordinate: home,
            kind: kind
        )
    }

    func testAFourMinuteWalkIsNotLeaving() {
        XCTAssertFalse(StayGapFiller.isDeparture(trip("walk", from: 17.4, to: 17.47)))
    }

    func testAWalkThatCoveredGroundIsLeaving() {
        // Same four minutes, but the fixes say two kilometres — so it was not a
        // walk round the block, whatever the clock says.
        XCTAssertTrue(StayGapFiller.isDeparture(trip("hike", from: 17.4, to: 17.47, metres: 2_000)))
    }

    func testTheBarForCoveringGroundIsLow() {
        // Three hundred metres is down the road and back, not pottering.
        XCTAssertTrue(StayGapFiller.isDeparture(trip("errand", from: 17.4, to: 17.5, metres: 300)))
        // A hundred and fifty is round the block.
        XCTAssertFalse(StayGapFiller.isDeparture(trip("block", from: 17.4, to: 17.5, metres: 150)))
    }

    func testALongWalkIsLeaving() {
        XCTAssertTrue(StayGapFiller.isDeparture(trip("stroll", from: 1, to: 1.5)))
    }

    func testAShortDriveIsAlwaysLeaving() {
        // Four minutes in a car is a couple of kilometres.
        XCTAssertTrue(StayGapFiller.isDeparture(trip("drive", from: 1, to: 1.07, kind: .automobile)))
    }

    func testTheNightSurvivesAnEveningWalk() {
        // The reported case: home until 16:47, a four-minute walk at 17:24, then
        // nothing until the morning drive. The night should read as one stay.
        let visits = [visit("evening", from: 14, to: 16.78)]
        let trips = [
            trip("evening-walk", from: 17.4, to: 17.47),
            trip("morning-drive", from: 32.58, to: 32.9, kind: .automobile, metres: 10_000),
        ]
        let filled = StayGapFiller.fill(visits: visits, trips: trips, now: at(40))

        XCTAssertEqual(filled.count, 1, "one continuous stay, not one either side of the walk")
        XCTAssertEqual(filled.first?.start, at(16.78))
        XCTAssertEqual(filled.first?.end, at(32.58), "up to the moment the morning drive begins")
        XCTAssertEqual(filled.first?.placeKey, "home")
    }

    func testARealDepartureStillEndsTheStay() {
        let visits = [visit("evening", from: 14, to: 16.78)]
        let trips = [trip("out", from: 17.4, to: 17.9, kind: .automobile, metres: 8_000)]
        let filled = StayGapFiller.fill(visits: visits, trips: trips, now: at(40))
        XCTAssertEqual(filled.first?.end, at(17.4), "a drive out is leaving")
    }
}


/// A stay that has begun and not ended is still a stay.
///
/// Core Location reports a visit twice, on arrival and on departure, and only
/// the second can be written down — until then there is no end to record. So a
/// week working from home showed nothing at all: the arrival was witnessed, and
/// the library stayed silent about it until the day you finally went out.
final class OpenStayTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460)

    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openstay-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private func stay(_ id: String, from: Date, to: Date) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: from,
            end: to,
            coordinate: home,
            semanticType: "Home",
            placeKey: "home"
        )
    }

    func testAnOpenStayIsReadAsRunningUpToNow() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        let arrived = Date(timeIntervalSince1970: 1_800_000_000)
        let now = arrived.addingTimeInterval(3 * 24 * 3_600)

        // Something has to exist or the library reads as empty.
        try await db.record(
            batch: TimelineBatch(
                visits: [stay("earlier", from: arrived.addingTimeInterval(-7_200), to: arrived.addingTimeInterval(-3_600))],
                activities: [],
                paths: []
            )
        )
        try await db.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "home"
        )

        let loaded = try await db.loadBatch(now: now)
        let batch = try XCTUnwrap(loaded)
        let open = try XCTUnwrap(batch.visits.first { $0.isOpen })
        XCTAssertEqual(open.start, arrived)
        XCTAssertEqual(open.end, now, "it runs up to the present, not to a departure that has not happened")
        XCTAssertEqual(open.placeKey, "home")
        XCTAssertFalse(
            open.isDerived,
            "it is a real row from the moment it opens, so it can be moved like any other"
        )
    }

    /// Three days at home should read as three days at home, not three blanks.
    func testAMultiDayOpenStayCoversEveryDay() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        let arrived = Date(timeIntervalSince1970: 1_800_000_000)
        let now = arrived.addingTimeInterval(3 * 24 * 3_600)

        try await db.record(
            batch: TimelineBatch(
                visits: [stay("earlier", from: arrived.addingTimeInterval(-7_200), to: arrived.addingTimeInterval(-3_600))],
                activities: [],
                paths: []
            )
        )
        try await db.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "home"
        )
        let loaded = try await db.loadBatch(now: now)
        let batch = try XCTUnwrap(loaded)
        let parsed = TimelineParser.assemble(batch, sourceName: "test", now: now)

        let covered = parsed.days.filter { day in
            day.visits.contains { $0.placeKey == "home" }
        }
        XCTAssertGreaterThanOrEqual(covered.count, 3, "every day of the stay should show it")
    }

    /// Core Location reports an arrival it missed as `.distantPast` — it knows
    /// you are somewhere but not since when. A stay running back to the
    /// beginning of time is worse than none.
    func testAnArrivalItNeverSawIsRefused() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await db.record(
            batch: TimelineBatch(
                visits: [stay("earlier", from: now.addingTimeInterval(-7_200), to: now.addingTimeInterval(-3_600))],
                activities: [],
                paths: []
            )
        )
        var stop = CapturedStop(coordinate: home, horizontalAccuracy: 50, start: .distantPast, end: nil)
        stop.arrivalIsKnown = false
        try await db.setOpenStop(stop, placeKey: "home")

        let loaded = try await db.loadBatch(now: now)
        let batch = try XCTUnwrap(loaded)
        XCTAssertFalse(batch.visits.contains { $0.isOpen })
    }

    /// When it finally ends, the written row replaces it rather than sitting
    /// beside it: the id is hashed from the arrival time, which does not change.
    func testClosingTheStayDoesNotLeaveTwo() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        let arrived = Date(timeIntervalSince1970: 1_800_000_000)
        let left = arrived.addingTimeInterval(7_200)

        try await db.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "home"
        )
        let loadedOpen = try await db.loadBatch(now: arrived.addingTimeInterval(3_600))
        let whileOpen = try XCTUnwrap(loadedOpen)
        let openID = try XCTUnwrap(whileOpen.visits.first { $0.isOpen }).id

        let closed = try XCTUnwrap(PlaceClusterer.visit(
            for: CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: left),
            placeKey: "home"
        ))
        XCTAssertEqual(closed.id, openID, "the same stay keeps the same identity")

        try await db.record(batch: TimelineBatch(visits: [closed], activities: [], paths: []))
        try await db.clearOpenStop()
        let loadedAfter = try await db.loadBatch(now: left.addingTimeInterval(60))
        let after = try XCTUnwrap(loadedAfter)
        XCTAssertEqual(after.visits.filter { $0.id == openID }.count, 1)
        XCTAssertFalse(after.visits.contains { $0.isOpen })
    }

    /// An open stay that outlives any plausible visit was a departure nobody
    /// saw, or an app that has not run in a month. Drawing it asserts something
    /// nobody witnessed.
    func testAStaleOpenStayIsNotDrawn() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        let arrived = Date(timeIntervalSince1970: 1_800_000_000)
        let muchLater = arrived.addingTimeInterval(TimelineDatabase.longestOpenStay + 3_600)

        try await db.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "home"
        )
        let stale = try await db.openStay(now: muchLater)
        XCTAssertNil(stale)

        // Still drawn a week in, which is an ordinary stretch of working at home.
        let withinReason = try await db.openStay(now: arrived.addingTimeInterval(6 * 24 * 3_600))
        XCTAssertNotNil(withinReason)
    }


    /// The Mac has no recorder, so the only way it can know you are at home is
    /// to be told — and a stay that has not ended has to be a row before it can
    /// travel. A week working from home was a week of empty days over there.
    func testAnOpenStayTravelsToTheOtherDevice() async throws {
        let (phone, phoneURL) = database()
        defer { try? FileManager.default.removeItem(at: phoneURL) }
        let (mac, macURL) = database()
        defer { try? FileManager.default.removeItem(at: macURL) }

        let arrived = Date(timeIntervalSince1970: 1_800_000_000)
        try await phone.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "home"
        )

        let outgoing = try await phone.changeBatch()
        let sent = try XCTUnwrap(outgoing.visits.first { $0.isOpen })
        XCTAssertEqual(sent.start, arrived)

        try await mac.applyRemote(
            TimelineBatch(visits: [sent], activities: [], paths: []),
            visitSources: [:]
        )

        // Three days later the Mac still shows it, grown against its own clock.
        let threeDaysOn = arrived.addingTimeInterval(3 * 24 * 3_600)
        let loaded = try await mac.loadBatch(now: threeDaysOn)
        let batch = try XCTUnwrap(loaded)
        let open = try XCTUnwrap(batch.visits.first { $0.isOpen })
        XCTAssertEqual(open.placeKey, "home")
        XCTAssertEqual(open.end, threeDaysOn, "it runs up to the present on this device too")
    }

    /// Written once and left alone. However long the stay runs it is one row and
    /// one send — reading is what grows it.
    func testAnOpenStayIsNotRewrittenAsItRuns() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        let arrived = Date(timeIntervalSince1970: 1_800_000_000)
        try await db.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "home"
        )
        let first = try await db.pendingChangeCount()
        try await db.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "home"
        )
        let second = try await db.pendingChangeCount()
        XCTAssertEqual(second, first, "the same stay is not queued twice")
    }

    /// Past a week an unclosed stay means the departure was missed, and drawing
    /// it further asserts something nobody witnessed.
    func testAnOpenStayStopsGrowingOnceItIsNotCredible() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        let arrived = Date(timeIntervalSince1970: 1_800_000_000)
        try await db.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "home"
        )
        let muchLater = arrived.addingTimeInterval(30 * 24 * 3_600)
        let loaded = try await db.loadBatch(now: muchLater)
        let batch = try XCTUnwrap(loaded)
        let open = try XCTUnwrap(batch.visits.first { $0.isOpen })
        XCTAssertEqual(
            open.end.timeIntervalSince(arrived),
            TimelineDatabase.longestOpenStay,
            accuracy: 1
        )
    }

}
