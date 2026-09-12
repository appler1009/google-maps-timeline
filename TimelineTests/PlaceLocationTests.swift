import CoreLocation
import CloudKit
import XCTest
@testable import Timeline

/// Google ships one coordinate per Place ID and it is sometimes the wrong end of
/// the block; a recorded stay sits wherever the fix landed. Both are assumptions
/// the data made, and neither could be argued with.
final class PlaceLocationTests: XCTestCase {
    private let assumed = CLLocationCoordinate2D(latitude: 49.26636, longitude: -123.24252)
    private let actual = CLLocationCoordinate2D(latitude: 49.26490, longitude: -123.23900)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("placeloc-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private func visit(_ id: String, hours: Double) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: origin.addingTimeInterval(hours * 3_600),
            end: origin.addingTimeInterval(hours * 3_600 + 1_800),
            coordinate: assumed,
            semanticType: nil,
            placeKey: "ChIJstaples"
        )
    }

    func testCorrectingAPlaceMovesEveryStayAtIt() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.upsert(
            batch: TimelineBatch(visits: [visit("v1", hours: 1), visit("v2", hours: 30)], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        try await db.setPlaceLocation(placeKey: "ChIJstaples", coordinate: actual)

        let visits = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(visits.count, 2)
        for moved in visits {
            XCTAssertEqual(moved.coordinate?.latitude ?? 0, actual.latitude, accuracy: 0.000_001)
            XCTAssertEqual(moved.coordinate?.longitude ?? 0, actual.longitude, accuracy: 0.000_001)
        }
    }

    func testAnotherPlaceIsUntouched() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let elsewhere = TimelineVisit(
            id: "other",
            start: origin,
            end: origin.addingTimeInterval(600),
            coordinate: assumed,
            semanticType: nil,
            placeKey: "ChIJsomewhere-else"
        )
        try await db.upsert(
            batch: TimelineBatch(visits: [visit("v1", hours: 1), elsewhere], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        try await db.setPlaceLocation(placeKey: "ChIJstaples", coordinate: actual)

        let visits = try await db.loadBatch()?.visits ?? []
        let other = visits.first { $0.id == "other" }
        XCTAssertEqual(other?.coordinate?.latitude ?? 0, assumed.latitude, accuracy: 0.000_001)
    }

    func testANewStayNearbySnapsToTheCorrectedSpot() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.upsert(
            batch: TimelineBatch(visits: [visit("v1", hours: 1)], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        try await db.setPlaceLocation(placeKey: "ChIJstaples", coordinate: actual)

        let anchors = try await db.placeAnchors()
        let staples = anchors.first { $0.placeKey == "ChIJstaples" }
        XCTAssertEqual(
            staples?.coordinate.latitude ?? 0,
            actual.latitude,
            accuracy: 0.000_001,
            "clustering should use the corrected spot, not the one we were told"
        )
    }

    func testPuttingItBackRestoresTheOriginal() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.upsert(
            batch: TimelineBatch(visits: [visit("v1", hours: 1)], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        try await db.setPlaceLocation(placeKey: "ChIJstaples", coordinate: actual)
        try await db.clearPlaceLocation(placeKey: "ChIJstaples")

        let visits = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(visits.first?.coordinate?.latitude ?? 0, assumed.latitude, accuracy: 0.000_001)
    }

    func testTheCorrectionTravelsToTheOtherDevices() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.setPlaceLocation(placeKey: "ChIJstaples", coordinate: actual)
        let queued = try await db.pendingChanges()
        XCTAssertEqual(queued.map(\.kind), [.placeLocation])
        XCTAssertEqual(queued.first?.rowID, "ChIJstaples")

        let batch = try await db.changeBatch()
        XCTAssertEqual(batch.locations["ChIJstaples"]?.coordinate.latitude ?? 0, actual.latitude, accuracy: 0.000_001)
    }

    func testAnOlderCorrectionDoesNotOverwriteANewerOne() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date().timeIntervalSince1970
        try await db.setPlaceLocation(placeKey: "ChIJstaples", coordinate: actual, updatedAt: now)
        let applied = try await db.applyPlaceLocationIfNewer(
            placeKey: "ChIJstaples",
            coordinate: assumed,
            updatedAt: now - 600
        )
        XCTAssertFalse(applied, "a stale correction from another device must not win")

        let stored = try await db.loadPlaceLocations()["ChIJstaples"]
        XCTAssertEqual(stored?.coordinate.latitude ?? 0, actual.latitude, accuracy: 0.000_001)
    }

    func testApplyingARemoteCorrectionDoesNotEchoItBack() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.applyPlaceLocationIfNewer(
            placeKey: "ChIJstaples",
            coordinate: actual,
            updatedAt: Date().timeIntervalSince1970
        )
        let queued = try await db.pendingChangeCount()
        XCTAssertEqual(queued, 0, "a correction that arrived must not be queued straight back out")
    }

    func testTheRecordRoundTrips() throws {
        let zoneID = CKRecordZone.ID(zoneName: TimelineRecordMapper.zoneName, ownerName: CKCurrentUserDefaultName)
        let record = TimelineRecordMapper.record(
            forPlaceKey: "ChIJstaples",
            location: PlaceLocation(coordinate: actual, updatedAt: 42),
            in: zoneID
        )
        XCTAssertEqual(record.recordType, "PlaceLocation")
        let parsed = try XCTUnwrap(TimelineRecordMapper.placeLocation(from: record))
        XCTAssertEqual(parsed.key, "ChIJstaples", "the prefix must not leak into the place key")
        XCTAssertEqual(parsed.location.coordinate.latitude, actual.latitude, accuracy: 0.000_001)
        XCTAssertEqual(parsed.location.updatedAt, 42)
    }

    func testALocationRecordDoesNotCollideWithANameOrAMerge() {
        let zoneID = CKRecordZone.ID(zoneName: TimelineRecordMapper.zoneName, ownerName: CKCurrentUserDefaultName)
        let key = "ChIJstaples"
        let names = Set([
            TimelineRecordMapper.recordName(for: .placeName, rowID: key),
            TimelineRecordMapper.recordName(for: .placeMerge, rowID: key),
            TimelineRecordMapper.recordName(for: .placeLocation, rowID: key),
        ])
        XCTAssertEqual(names.count, 3, "record names are unique per zone, not per type")
        _ = zoneID
    }
}
