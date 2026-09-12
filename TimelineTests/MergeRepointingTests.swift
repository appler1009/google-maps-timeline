import CoreLocation
import XCTest
@testable import Timeline

/// A merge used to be an alias every read had to resolve through. It is now a
/// move: the stays themselves change place, and remember where they came from so
/// it can be undone.
final class MergeRepointingTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 49.2765, longitude: -123.0680)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoint-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private func stay(_ id: String, key: String, hours: Double) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: start.addingTimeInterval(hours * 3_600),
            end: start.addingTimeInterval(hours * 3_600 + 1_800),
            coordinate: here,
            semanticType: nil,
            placeKey: key
        )
    }

    private func seed(_ db: TimelineDatabase) async throws {
        try await db.record(
            batch: TimelineBatch(
                visits: [
                    stay("annex-1", key: "annex", hours: 1),
                    stay("annex-2", key: "annex", hours: 5),
                    stay("main-1", key: "main", hours: 9),
                ],
                activities: [],
                paths: []
            )
        )
    }

    func testMergingMovesTheStays() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        try await db.mergePlace(from: "annex", into: "main", targetSemantic: nil)

        let visits = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(Set(visits.map(\.placeKey)), ["main"], "all three stays are at main now")
        let origins = try await db.mergedOrigins(into: "main")
        XCTAssertEqual(origins, ["annex"], "and main remembers what was folded into it")
    }

    func testUnmergingPutsThemBack() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        try await db.mergePlace(from: "annex", into: "main", targetSemantic: nil)
        try await db.unmergePlace(from: "annex")

        let visits = try await db.loadBatch()?.visits ?? []
        let byID = Dictionary(uniqueKeysWithValues: visits.map { ($0.id, $0.placeKey) })
        XCTAssertEqual(byID["annex-1"], "annex")
        XCTAssertEqual(byID["annex-2"], "annex")
        XCTAssertEqual(byID["main-1"], "main", "a stay that was always at main does not move")
        let origins = try await db.mergedOrigins(into: "main")
        XCTAssertTrue(origins.isEmpty)
    }

    func testAChainOfMergesUnwindsOneStepAtATime() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        // annex → main, then main → hub. The annex stays keep annex as their
        // origin, so unmerging annex sends them home rather than to main.
        try await db.mergePlace(from: "annex", into: "main", targetSemantic: nil)
        try await db.mergePlace(from: "main", into: "hub", targetSemantic: nil)

        let merged = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(Set(merged.map(\.placeKey)), ["hub"])

        try await db.unmergePlace(from: "annex")
        let visits = try await db.loadBatch()?.visits ?? []
        let byID = Dictionary(uniqueKeysWithValues: visits.map { ($0.id, $0.placeKey) })
        XCTAssertEqual(byID["annex-1"], "annex", "back to where it started, not to main")
        XCTAssertEqual(byID["main-1"], "hub", "the other merge is untouched")
    }

    func testAMergeTravelsToTheOtherDevices() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        try await db.clearChangeLog()

        try await db.mergePlace(from: "annex", into: "main", targetSemantic: nil)
        let queued = try await db.pendingChanges()
        let movedStays = queued.filter { $0.kind == .visit }.map(\.rowID)
        XCTAssertEqual(Set(movedStays), ["annex-1", "annex-2"], "the stays that moved have to travel")
    }

    func testMergingAPlaceWithNoStaysIsHarmless() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        try await db.mergePlace(from: "nowhere", into: "main", targetSemantic: nil)
        let visits = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(visits.count, 3)
    }
}
