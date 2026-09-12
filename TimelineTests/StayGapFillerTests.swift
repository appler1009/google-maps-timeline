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
