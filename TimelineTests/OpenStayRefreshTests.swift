import XCTest
import CoreLocation
@testable import Timeline

/// A stay still in progress is drawn up to the moment the library was read,
/// and nothing is written while you stay put — so the screen has to notice the
/// clock on its own. The Mac, left open overnight, showed no today at all.
@MainActor
final class OpenStayRefreshTests: XCTestCase {
    private let calendar = Calendar.current
    private var url: URL!
    private var database: TimelineDatabase!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-refresh-\(UUID().uuidString).sqlite")
        database = TimelineDatabase(fileURL: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    /// 20:43 on an ordinary evening, local time.
    private var arrival: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 20, minute: 43))!
    }

    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// The row as it reaches the Mac: written once on arrival, ending where it
    /// starts, flagged open. The Mac has no open_visit of its own.
    private func recordOpenStay() async throws {
        let home = TimelineVisit(
            id: "home-open",
            start: arrival,
            end: arrival,
            coordinate: CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1100),
            semanticType: nil,
            placeKey: "home",
            isOpen: true
        )
        try await database.record(batch: TimelineBatch(visits: [home], activities: [], paths: []))
    }

    func testReloadingAfterMidnightGivesTheStayItsNewDay() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)

        await store.reloadFromLibrary(now: at(day: 12, hour: 21, minute: 13))
        let today = calendar.startOfDay(for: at(day: 13, hour: 0))
        XCTAssertNil(store.parsed?.days.first { $0.day == today })

        await store.reloadFromLibrary(now: at(day: 13, hour: 12))
        let day = try XCTUnwrap(store.parsed?.days.first { $0.day == today })
        let home = try XCTUnwrap(day.visits.first)
        XCTAssertEqual(home.start, today)
        XCTAssertEqual(home.end, at(day: 13, hour: 12))
        XCTAssertTrue(home.isOpen)
    }

    func testAnOpenStayGoesStaleWithTimeAndAtMidnight() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)
        let loaded = at(day: 12, hour: 21, minute: 13)
        await store.reloadFromLibrary(now: loaded)

        XCTAssertTrue(store.hasOpenStay)
        XCTAssertFalse(store.isStale(now: loaded.addingTimeInterval(60), calendar: calendar))
        XCTAssertTrue(store.isStale(
            now: loaded.addingTimeInterval(TimelineStore.openStayRefreshInterval),
            calendar: calendar
        ))
        // Five minutes to midnight, then one minute past it.
        let late = at(day: 12, hour: 23, minute: 55)
        await store.reloadFromLibrary(now: late)
        XCTAssertTrue(store.isStale(now: at(day: 13, hour: 0, minute: 1), calendar: calendar))
    }

    func testNothingOpenIsNeverStale() async throws {
        let closed = TimelineVisit(
            id: "home-closed",
            start: arrival,
            end: arrival.addingTimeInterval(3_600),
            coordinate: CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1100),
            semanticType: nil,
            placeKey: "home"
        )
        try await database.record(batch: TimelineBatch(visits: [closed], activities: [], paths: []))
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 12, hour: 22))

        XCTAssertFalse(store.hasOpenStay)
        XCTAssertFalse(store.isStale(now: at(day: 14, hour: 9), calendar: calendar))
    }

    /// A reload is not a relaunch: the map stays on the day being looked at.
    func testAReloadKeepsTheMapWhereItWas() async throws {
        try await recordOpenStay()
        let earlier = TimelineVisit(
            id: "school",
            start: at(day: 10, hour: 9),
            end: at(day: 10, hour: 10),
            coordinate: CLLocationCoordinate2D(latitude: 49.2400, longitude: -123.1500),
            semanticType: nil,
            placeKey: "school"
        )
        try await database.record(batch: TimelineBatch(visits: [earlier], activities: [], paths: []))
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 13, hour: 8))

        let tenth = calendar.startOfDay(for: at(day: 10, hour: 0))
        let day = try XCTUnwrap(store.parsed?.days.first { $0.day == tenth })
        store.select(day: day)
        let generation = store.focusGeneration

        await store.reloadFromLibrary(now: at(day: 13, hour: 9))
        XCTAssertEqual(store.selectedDayID, tenth)
        XCTAssertEqual(store.focusGeneration, generation)
    }

    #if os(macOS)
    /// Watching the newest day means being carried to the next one. The Mac,
    /// left open since yesterday, held on to yesterday: today arrived from the
    /// phone and went into the list, and the map never went to it.
    func testMidnightCarriesTheNewestDayForward() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 12, hour: 21))
        XCTAssertEqual(store.selectedDayID, calendar.startOfDay(for: arrival))

        await store.reloadFromLibrary(now: at(day: 13, hour: 12))
        let today = calendar.startOfDay(for: at(day: 13, hour: 0))
        XCTAssertEqual(store.selectedDayID, today)
        XCTAssertEqual(store.selectedDay?.day, today)
        XCTAssertTrue(store.filteredDays.contains { $0.day == today })
    }
    #endif

    /// A stay growing longer moves nothing on the map, so nothing is redrawn.
    func testAStayGrowingLongerLeavesTheMapAlone() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 13, hour: 8))
        let today = try XCTUnwrap(store.parsed?.days.first { $0.day == calendar.startOfDay(for: at(day: 13, hour: 0)) })
        store.select(day: today)
        store.focusVisit(id: "home-open")
        await store.routesSettled()
        let routes = store.routeGeneration
        let content = store.dayContentGeneration

        await store.reloadFromLibrary(now: at(day: 13, hour: 9))
        await store.routesSettled()
        XCTAssertEqual(store.routeGeneration, routes)
        XCTAssertEqual(store.dayContentGeneration, content)
        XCTAssertEqual(store.selectedVisitID, "home-open")
    }

    /// A stay arriving for the day on screen does change its pins, and the
    /// camera follows so the new stay is not left off the edge.
    func testANewStayOnTheSameDayRedrawsItsPins() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 12, hour: 21))
        let day = try XCTUnwrap(store.parsed?.days.first { $0.day == calendar.startOfDay(for: arrival) })
        store.select(day: day)
        let content = store.dayContentGeneration
        let focus = store.focusGeneration

        try await database.record(batch: TimelineBatch(visits: [TimelineVisit(
            id: "gym",
            start: at(day: 12, hour: 15),
            end: at(day: 12, hour: 16),
            coordinate: CLLocationCoordinate2D(latitude: 49.2700, longitude: -123.1000),
            semanticType: nil,
            placeKey: "gym"
        )], activities: [], paths: []))
        await store.reloadFromLibrary(now: at(day: 12, hour: 21, minute: 1))
        XCTAssertNotEqual(store.dayContentGeneration, content)
        XCTAssertNotEqual(store.focusGeneration, focus)
    }

    /// A reload asked for while one is reading folds into it, so a write that
    /// lands in between is never shown and then taken away.
    func testOverlappingReloadsEndOnTheNewestRead() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 12, hour: 21))

        let first = Task { await store.reloadFromLibrary(now: at(day: 12, hour: 21, minute: 1)) }
        try await database.record(batch: TimelineBatch(visits: [TimelineVisit(
            id: "gym",
            start: at(day: 12, hour: 15),
            end: at(day: 12, hour: 16),
            coordinate: CLLocationCoordinate2D(latitude: 49.2700, longitude: -123.1000),
            semanticType: nil,
            placeKey: "gym"
        )], activities: [], paths: []))
        await store.reloadFromLibrary(now: at(day: 12, hour: 21, minute: 1))
        await first.value

        let visits = store.parsed?.days.flatMap(\.visits) ?? []
        XCTAssertTrue(visits.contains { $0.id == "gym" })
    }

    /// A stay written to disk while the sidebar still shows yesterday must be
    /// noticed without waiting for a cloud notification or a relaunch.
    func testSidebarBehindDiskReloadsTheNewerDay() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 12, hour: 21))
        XCTAssertEqual(store.parsed?.days.first?.day, calendar.startOfDay(for: arrival))

        try await database.record(batch: TimelineBatch(visits: [TimelineVisit(
            id: "monday-cafe",
            start: at(day: 13, hour: 9),
            end: at(day: 13, hour: 10),
            coordinate: CLLocationCoordinate2D(latitude: 49.2700, longitude: -123.1000),
            semanticType: nil,
            placeKey: "cafe"
        )], activities: [], paths: []))

        await store.reloadFromLibraryIfBehind(now: at(day: 13, hour: 12))
        let monday = calendar.startOfDay(for: at(day: 13, hour: 0))
        XCTAssertEqual(store.parsed?.days.first?.day, monday)
        XCTAssertEqual(store.selectedDayID, monday)
    }

    /// Past the cap the library stops stretching the stay, so the clock has
    /// nothing to add — but a midnight before the cap still counts.
    func testAStayPastTheCapStopsGoingStale() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)
        let cap = arrival.addingTimeInterval(TimelineDatabase.longestOpenStay)

        await store.reloadFromLibrary(now: cap.addingTimeInterval(-3_600))
        XCTAssertTrue(store.isStale(now: cap.addingTimeInterval(86_400), calendar: calendar))

        await store.reloadFromLibrary(now: cap.addingTimeInterval(3_600))
        XCTAssertFalse(store.isStale(now: cap.addingTimeInterval(7_200), calendar: calendar))
        XCTAssertFalse(store.isStale(now: cap.addingTimeInterval(3 * 86_400), calendar: calendar))
    }

    // MARK: - An open row left behind

    private let supermarket = CLLocationCoordinate2D(latitude: 49.2094, longitude: -123.1157)

    private func visit(_ id: String, start: Date, end: Date, open: Bool = false) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: start,
            end: end,
            coordinate: supermarket,
            semanticType: nil,
            placeKey: "supermarket",
            isOpen: open
        )
    }

    /// Monday 16:37 an arrival opened a row, 16:59 a second arrival at the same
    /// place replaced it in open_visit, and the departure closed only the
    /// second. The first ran on to the present, into Tuesday at midnight.
    private func recordLeftBehindOpenRow() async throws {
        try await database.record(batch: TimelineBatch(visits: [
            visit("left-open", start: at(day: 21, hour: 16, minute: 37), end: at(day: 21, hour: 16, minute: 37), open: true),
            visit("closed", start: at(day: 21, hour: 16, minute: 59), end: at(day: 21, hour: 17, minute: 18)),
        ], activities: [], paths: []))
    }

    func testAnOpenRowAStayBeganAfterStopsAtThatStay() async throws {
        try await recordLeftBehindOpenRow()
        let loaded = try await database.loadBatch(now: at(day: 22, hour: 10))
        let batch = try XCTUnwrap(loaded)
        let row = try XCTUnwrap(batch.visits.first { $0.id == "left-open" })
        XCTAssertEqual(row.end, at(day: 21, hour: 16, minute: 59))
        XCTAssertFalse(row.isOpen)

        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 22, hour: 10))
        // What remains on Tuesday is derived from the last stay, not the row.
        let tuesday = calendar.startOfDay(for: at(day: 22, hour: 0))
        let carried = store.parsed?.days.first { $0.day == tuesday }?.visits ?? []
        XCTAssertFalse(carried.contains { $0.id == "left-open" })
        XCTAssertFalse(store.hasOpenStay)
    }

    func testTheStayInProgressStillRunsToThePresent() async throws {
        try await recordLeftBehindOpenRow()
        try await database.record(batch: TimelineBatch(visits: [
            visit("now-open", start: at(day: 21, hour: 18), end: at(day: 21, hour: 18), open: true)
        ], activities: [], paths: []))
        let loaded = try await database.loadBatch(now: at(day: 22, hour: 10))
        let batch = try XCTUnwrap(loaded)
        let row = try XCTUnwrap(batch.visits.first { $0.id == "now-open" })
        XCTAssertEqual(row.end, at(day: 22, hour: 10))
        XCTAssertTrue(row.isOpen)
    }

    /// Still there when the next stay began, so the arrival is kept.
    func testAnOpenRowFollowedByTheSamePlaceIsClosedWhereThatStayBegins() async throws {
        try await recordLeftBehindOpenRow()
        let retired = try await database.retireSupersededOpenStays(now: at(day: 22, hour: 10))
        XCTAssertEqual(retired, 1)
        let loaded = try await database.loadBatch(now: at(day: 22, hour: 10))
        let batch = try XCTUnwrap(loaded)
        let row = try XCTUnwrap(batch.visits.first { $0.id == "left-open" })
        XCTAssertEqual(row.start, at(day: 21, hour: 16, minute: 37))
        XCTAssertEqual(row.end, at(day: 21, hour: 16, minute: 59))
        XCTAssertFalse(row.isOpen)
    }

    /// Gone somewhere else, at a time nobody saw, so the row goes.
    func testAnOpenRowFollowedBySomewhereElseIsDeleted() async throws {
        try await database.record(batch: TimelineBatch(visits: [
            visit("left-open", start: at(day: 21, hour: 16, minute: 37), end: at(day: 21, hour: 16, minute: 37), open: true),
            TimelineVisit(
                id: "cafe",
                start: at(day: 21, hour: 16, minute: 43),
                end: at(day: 21, hour: 16, minute: 58),
                coordinate: CLLocationCoordinate2D(latitude: 49.2113, longitude: -123.1124),
                semanticType: nil,
                placeKey: "cafe"
            ),
        ], activities: [], paths: []))
        let retired = try await database.retireSupersededOpenStays(now: at(day: 22, hour: 10))
        XCTAssertEqual(retired, 1)
        let loaded = try await database.loadBatch(now: at(day: 22, hour: 10))
        let batch = try XCTUnwrap(loaded)
        XCTAssertEqual(batch.visits.map(\.id), ["cafe"])
    }

    /// A stay added by hand is not the recorder seeing you leave.
    func testAHandAddedStayDoesNotRetireAnOpenRow() async throws {
        try await database.record(batch: TimelineBatch(visits: [
            visit("left-open", start: at(day: 21, hour: 16, minute: 37), end: at(day: 21, hour: 16, minute: 37), open: true)
        ], activities: [], paths: []))
        try await database.record(
            batch: TimelineBatch(visits: [
                visit("typed", start: at(day: 21, hour: 17), end: at(day: 21, hour: 17, minute: 10))
            ], activities: [], paths: []),
            source: .manual
        )
        let retired = try await database.retireSupersededOpenStays(now: at(day: 22, hour: 10))
        XCTAssertEqual(retired, 0)
    }

    func testASecondArrivalRetiresTheOpenRowItReplaces() async throws {
        let first = CapturedStop(coordinate: supermarket, horizontalAccuracy: 20, start: at(day: 21, hour: 16, minute: 37), end: nil)
        let second = CapturedStop(coordinate: supermarket, horizontalAccuracy: 20, start: at(day: 21, hour: 16, minute: 59), end: nil)
        try await database.setOpenStop(first, placeKey: "supermarket")
        try await database.setOpenStop(second, placeKey: "supermarket")
        let loaded = try await database.loadBatch(now: at(day: 21, hour: 17, minute: 30))
        let batch = try XCTUnwrap(loaded)
        let open = batch.visits.filter(\.isOpen)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.start, second.start)
        let earlier = try XCTUnwrap(batch.visits.first { $0.start == first.start })
        XCTAssertEqual(earlier.end, second.start)
    }

    /// The Mac list is rebuilt off this, so it has to move when a day arrives.
    func testTheDateListIdentityMovesWhenADayArrives() async throws {
        try await recordOpenStay()
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 12, hour: 22))
        let before = store.dateListIdentity
        await store.reloadFromLibrary(now: at(day: 12, hour: 23))
        XCTAssertEqual(store.dateListIdentity, before)
        await store.reloadFromLibrary(now: at(day: 13, hour: 1))
        XCTAssertNotEqual(store.dateListIdentity, before)
    }

    /// Launch reloads the library twice: the restore, which tidies for a few
    /// seconds first, and a cloud fetch or catch-up that lands meanwhile and
    /// opens the day. The restore landing second must not take the day away.
    func testARestoreLandingAfterAReloadKeepsTheDayOnScreen() async throws {
        try await recordOpenStay()
        try await database.record(batch: TimelineBatch(visits: [TimelineVisit(
            id: "earlier",
            start: at(day: 10, hour: 9),
            end: at(day: 10, hour: 10),
            coordinate: CLLocationCoordinate2D(latitude: 49.2700, longitude: -123.1000),
            semanticType: nil,
            placeKey: "cafe"
        )], activities: [], paths: []))
        let store = TimelineStore(database: database)
        await store.reloadFromLibrary(now: at(day: 12, hour: 22))
        let earlier = try XCTUnwrap(store.day(for: calendar.startOfDay(for: at(day: 10, hour: 0))))
        store.select(day: earlier)

        await store.restoreLibrary()
        XCTAssertEqual(store.selectedDayID, earlier.day)
        XCTAssertNotNil(store.activeDay)
    }
}
