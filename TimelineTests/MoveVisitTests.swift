import CoreLocation
import XCTest
@testable import Timeline

/// Coarse fixes snap a stop onto the neighbouring place. Fixing that must not be
/// a rename (which relabels every other stay there) or a merge (which folds the
/// two places together for good).
final class MoveVisitTests: XCTestCase {
    private let cafe = CLLocationCoordinate2D(latitude: 49.2765, longitude: -123.0680)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private func visit(_ id: String, place: String, hour: Double) -> TimelineVisit {
        let start = origin.addingTimeInterval(hour * 3_600)
        return TimelineVisit(
            id: id,
            start: start,
            end: start.addingTimeInterval(1_800),
            coordinate: cafe,
            semanticType: nil,
            placeKey: place
        )
    }

    func testOnlyTheChosenStayMoves() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(
            batch: TimelineBatch(
                visits: [
                    visit("wrong-one", place: "bank", hour: 1),
                    visit("right-one", place: "bank", hour: 5),
                ],
                activities: [],
                paths: []
            )
        )

        try await db.moveVisit(id: "wrong-one", toPlaceKey: "cafe")

        let visits = try await db.loadBatch()?.visits ?? []
        let byID = Dictionary(uniqueKeysWithValues: visits.map { ($0.id, $0.placeKey) })
        XCTAssertEqual(byID["wrong-one"], "cafe")
        XCTAssertEqual(byID["right-one"], "bank", "the other stay at that place must not follow")
    }

    func testTheMoveTravelsToTheOtherDevices() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(batch: TimelineBatch(visits: [visit("v1", place: "bank", hour: 1)], activities: [], paths: []))
        try await db.clearChangeLog()

        try await db.moveVisit(id: "v1", toPlaceKey: "cafe")
        let queued = try await db.pendingChanges()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.rowID, "v1")
        XCTAssertEqual(queued.first?.operation, .upsert)
    }

    func testMovingIsNotMerging() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(
            batch: TimelineBatch(
                visits: [visit("v1", place: "bank", hour: 1), visit("v2", place: "bank", hour: 5)],
                activities: [],
                paths: []
            )
        )
        try await db.moveVisit(id: "v1", toPlaceKey: "cafe")

        // A merge would have left an alias folding bank into cafe for good.
        let merges = try await db.loadPlaceMerges()
        XCTAssertTrue(merges.isEmpty, "moving one stay must not fold the two places together")
    }

    func testAnEmptyTargetIsRefused() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(batch: TimelineBatch(visits: [visit("v1", place: "bank", hour: 1)], activities: [], paths: []))
        try await db.moveVisit(id: "v1", toPlaceKey: "")

        let visits = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(visits.first?.placeKey, "bank", "a blank destination should change nothing")
    }

    func testAnInferredStayIsMarkedAsSuch() {
        // There is no row behind a gap-filled stay, so the UI must not offer to
        // move it.
        let real = visit("v1", place: "home", hour: 1)
        XCTAssertFalse(real.isDerived)

        let filled = StayGapFiller.fill(
            visits: [real],
            trips: [
                TimelineActivity(
                    id: "t1",
                    start: origin.addingTimeInterval(6 * 3_600),
                    end: origin.addingTimeInterval(6.5 * 3_600),
                    distance: 1_000,
                    startCoordinate: cafe,
                    endCoordinate: cafe,
                    kind: .automobile
                )
            ],
            now: origin.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(filled.count, 1)
        XCTAssertTrue(filled[0].isDerived)
        // And it stays marked when the day slices it.
        let sliced = filled[0].appearing(
            on: Calendar.current.startOfDay(for: filled[0].start),
            calendar: .current,
            semanticType: nil
        )
        XCTAssertTrue(sliced.isDerived, "slicing a day must not lose the marker")
    }
}
