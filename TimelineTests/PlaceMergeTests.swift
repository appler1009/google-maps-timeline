import CoreLocation
import XCTest
@testable import Timeline

final class PlaceMergeTests: XCTestCase {
    func testSoftMergeRemapsOnLoadAndUnmergeRestoresAlias() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("place-merge-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        let homeKey = "home"
        let otherKey = "other"
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3_600)
        let visit = TimelineVisit(
            id: Geo.segmentID("v", Geo.millis(start), Geo.millis(end), otherKey),
            start: start,
            end: end,
            coordinate: CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12),
            semanticType: nil,
            placeKey: otherKey
        )
        try await db.upsert(
            batch: TimelineBatch(visits: [visit], activities: [], paths: []),
            sourceName: "test"
        )

        try await db.mergePlace(from: otherKey, into: homeKey, targetSemantic: "Home")
        let merged = try await db.loadBatch()
        XCTAssertEqual(merged?.visits.first?.placeKey, homeKey)

        try await db.unmergePlace(from: otherKey)
        let split = try await db.loadBatch()
        XCTAssertEqual(split?.visits.first?.placeKey, otherKey)
    }

    func testUnmergeRestoresHistoricallyHardRemappedVisits() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("place-unmerge-hard-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        let homeKey = "home"
        let otherKey = "other"
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        let end = start.addingTimeInterval(1_800)
        // Id minted from the source key, but row already rewritten onto the target (legacy hard merge).
        let visit = TimelineVisit(
            id: Geo.segmentID("v", Geo.millis(start), Geo.millis(end), otherKey),
            start: start,
            end: end,
            coordinate: CLLocationCoordinate2D(latitude: 49.26, longitude: -123.13),
            semanticType: "Home",
            placeKey: homeKey
        )
        try await db.upsert(
            batch: TimelineBatch(visits: [visit], activities: [], paths: []),
            sourceName: "test"
        )
        try await db.mergePlace(from: otherKey, into: homeKey, targetSemantic: "Home")

        try await db.unmergePlace(from: otherKey)
        let split = try await db.loadBatch()
        XCTAssertEqual(split?.visits.first?.placeKey, otherKey)
    }

    func testMergeTombstoneWinsInIdentitySync() {
        let older = PlaceIdentityMerge(toKey: "home", updatedAt: 10)
        let newerTombstone = PlaceIdentityMerge(toKey: "", updatedAt: 20)
        let merged = PlaceIdentitySync.merged(
            local: PlaceIdentitySnapshot(names: [:], merges: ["other": newerTombstone]),
            remote: PlaceIdentitySnapshot(names: [:], merges: ["other": older])
        )
        XCTAssertTrue(merged.merges["other"]?.isTombstone == true)
    }
}
