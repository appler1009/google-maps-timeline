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
}
