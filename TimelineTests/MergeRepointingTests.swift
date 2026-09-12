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

    /// A merge that arrived from the other device could never be undone.
    ///
    /// `origin_place_id` is the record of the move, and only a merge performed
    /// on this device wrote one. A merge that came over sync was resolved while
    /// the entity migration linked stays to places, which moved them onto the
    /// survivor without leaving a trail — so unmerging found nothing to restore.
    /// This is the real case: seventy-nine stays at a supermarket folded into an
    /// insurance office, and no way back.
    func testAMergeWithNoRecordedOriginCanStillBeUndone() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        // The state a synced merge leaves behind: the stay points at the
        // survivor, still carries the key it was clustered under, and has no
        // origin recorded.
        try await db.mergePlace(from: "annex", into: "main", targetSemantic: nil)
        try await db.forgetMergeOrigins()

        let beforeCount = try await db.loadPlaces()
        XCTAssertNotNil(beforeCount["main"])

        try await db.unmergePlace(from: "annex")

        let visits = try await db.loadBatch()?.visits ?? []
        let restored = visits.filter { $0.placeKey == "annex" }
        XCTAssertEqual(restored.count, 2, "both stays go back to the place they were clustered under")
    }


    /// Clustering must answer with the place a stay belongs to now, not the one
    /// it was filed under when it was captured.
    ///
    /// place_key is where clustering put a stay at the time; place_id is where
    /// it belongs after merging, unmerging or moving it. Anchoring on the old
    /// column meant a place the library had already stopped believing in kept
    /// winning: a supermarket's seventy-nine stays had been folded into an
    /// insurance office, and every new stop there was still offered the office
    /// even after the fold was undone.
    func testAnchorsFollowThePlaceAStayPointsAtNow() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        // "annex" holds two stays, "main" one. Fold annex into main, so the
        // stays keep place_key "annex" while pointing at "main".
        try await db.mergePlace(from: "annex", into: "main", targetSemantic: nil)

        let merged = try await db.placeAnchors()
        XCTAssertNil(merged.first { $0.placeKey == "annex" }, "annex is not a place any more")
        XCTAssertEqual(merged.first { $0.placeKey == "main" }?.visitCount, 3)

        // Undo it: the stays point at annex again, though nothing rewrote
        // place_key on the way back either.
        try await db.unmergePlace(from: "annex")

        let restored = try await db.placeAnchors()
        XCTAssertEqual(restored.first { $0.placeKey == "annex" }?.visitCount, 2)
        XCTAssertEqual(restored.first { $0.placeKey == "main" }?.visitCount, 1)
    }


    /// Where a stay belongs has to cross between devices.
    ///
    /// Reads resolve through place_id, but an arriving stay only ever updated
    /// place_key — so a merge, an unmerge or a move changed the library on one
    /// device, sent a record carrying the new place, and the other device filed
    /// it under the old column and went on showing what it had. A supermarket
    /// repaired on the Mac still read as an insurance office on the phone.
    func testMovingAStayCrossesToTheOtherDevice() async throws {
        let (here, hereURL) = database()
        defer { try? FileManager.default.removeItem(at: hereURL) }
        let (there, thereURL) = database()
        defer { try? FileManager.default.removeItem(at: thereURL) }

        try await seed(here)
        try await seed(there)

        // Move one stay on this device only.
        try await here.moveVisit(id: "annex-1", toPlaceKey: "main")

        let outgoing = try await here.changeBatch()
        let moved = try XCTUnwrap(outgoing.visits.first { $0.id == "annex-1" })
        XCTAssertEqual(moved.placeKey, "main", "the record carries where it belongs now")

        try await there.applyRemote(
            TimelineBatch(visits: [moved], activities: [], paths: []),
            visitSources: [:]
        )

        let landed = try await there.loadBatch()?.visits.first { $0.id == "annex-1" }
        XCTAssertEqual(landed?.placeKey, "main", "and the other device agrees")
    }

    /// Undoing a merge has to cross too. A place that was never merged carries
    /// no target; one that was unmerged carries an empty one, which is a
    /// statement rather than an absence.
    func testUnmergingCrossesToTheOtherDevice() async throws {
        let (here, hereURL) = database()
        defer { try? FileManager.default.removeItem(at: hereURL) }
        let (there, thereURL) = database()
        defer { try? FileManager.default.removeItem(at: thereURL) }

        try await seed(here)
        try await seed(there)
        try await here.mergePlace(from: "annex", into: "main", targetSemantic: nil)
        try await there.mergePlace(from: "annex", into: "main", targetSemantic: nil)

        try await here.unmergePlace(from: "annex")
        let places = try await here.loadPlaces()
        let annex = try XCTUnwrap(places["annex"])
        XCTAssertEqual(annex.mergedInto, "", "an unmerged place says so rather than saying nothing")

        _ = try await there.applyPlaceIfNewer(annex)

        let counts = try await there.stayCountsByPlace()
        XCTAssertEqual(counts["annex"], 2, "the stays come back on the other device too")
        XCTAssertEqual(counts["main"], 1)
    }

}
