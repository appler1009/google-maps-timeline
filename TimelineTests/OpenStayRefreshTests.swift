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
}
