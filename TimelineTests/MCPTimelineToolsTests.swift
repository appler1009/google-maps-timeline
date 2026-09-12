import CoreLocation
import XCTest
@testable import Timeline

/// The tools against a real library, since the point of them is that they go
/// through the same paths the app's own buttons do.
final class MCPTimelineToolsTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func library() -> (MCPTimelineTools, TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString).sqlite")
        let db = TimelineDatabase(fileURL: url)
        return (MCPTimelineTools(database: db), db, url)
    }

    private func stay(_ id: String, key: String, hours: Double, at: CLLocationCoordinate2D? = nil) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: start.addingTimeInterval(hours * 3_600),
            end: start.addingTimeInterval(hours * 3_600 + 1_800),
            coordinate: at ?? here,
            semanticType: nil,
            placeKey: key
        )
    }

    private func seed(_ db: TimelineDatabase) async throws {
        try await db.record(
            batch: TimelineBatch(
                visits: [
                    stay("s1", key: "shop", hours: 1),
                    stay("s2", key: "shop", hours: 5),
                    stay("s3", key: "office", hours: 9)
                ],
                activities: [],
                paths: []
            )
        )
        try await db.setPlaceName(placeKey: "shop", name: "Save-On-Foods")
        try await db.setPlaceName(placeKey: "office", name: "InsureBC")
    }

    func testSearchingFindsAPlaceAndItsWeight() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let answer = try await tools.call("search_places", arguments: .object(["query": "save"]))
        let first = try XCTUnwrap(answer["places"]?.arrayValue?.first)
        XCTAssertEqual(first["name"]?.stringValue, "Save-On-Foods")
        XCTAssertEqual(first["stays"]?.intValue, 2)
        XCTAssertEqual(first["place_id"]?.stringValue, "shop")
    }

    func testADayListsItsStaysWithIdsThatCanBeMoved() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let date = MCPValue.dayFormatter.string(from: start.addingTimeInterval(3_600))
        let day = try await tools.call("get_day", arguments: .object(["date": .string(date)]))
        let stays = try XCTUnwrap(day["stays"]?.arrayValue)
        XCTAssertFalse(stays.isEmpty)

        let target = try XCTUnwrap(stays.first { $0["stay_id"]?.stringValue == "s1" })
        XCTAssertEqual(target["place"]?.stringValue, "Save-On-Foods")

        _ = try await tools.call("move_stay", arguments: .object([
            "stay_id": "s1", "place_id": "office"
        ]))
        let after = try await tools.call("get_day", arguments: .object(["date": .string(date)]))
        let moved = try XCTUnwrap(after["stays"]?.arrayValue?.first { $0["stay_id"]?.stringValue == "s1" })
        XCTAssertEqual(moved["place"]?.stringValue, "InsureBC")
    }

    /// The guard the rename sheet applies, applied here for the same reason.
    func testMergingAwayTheLargerHistoryIsRefusedUntilMeant() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await db.record(
            batch: TimelineBatch(
                visits: (0..<12).map { stay("big-\($0)", key: "shop", hours: Double($0)) }
                    + [stay("small-1", key: "office", hours: 20)],
                activities: [],
                paths: []
            )
        )
        try await db.setPlaceName(placeKey: "shop", name: "Save-On-Foods")
        try await db.setPlaceName(placeKey: "office", name: "InsureBC")

        do {
            _ = try await tools.call("merge_places", arguments: .object([
                "from_place_id": "shop", "into_place_id": "office"
            ]))
            XCTFail("should have refused")
        } catch let failure as MCPToolFailure {
            XCTAssertTrue(failure.message.contains("Refusing"))
        }

        // Meant, this time.
        let done = try await tools.call("merge_places", arguments: .object([
            "from_place_id": "shop", "into_place_id": "office", "confirm": true
        ]))
        XCTAssertEqual(done["stays_moved"]?.intValue, 12)

        // And it can be taken back.
        let undone = try await tools.call("unmerge_place", arguments: .object(["place_id": "shop"]))
        XCTAssertEqual(undone["stays_back"]?.intValue, 12)
    }

    func testProblemsReportPlacesStandingInTheSameDoorway() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        // Two names about thirty metres apart, which is one place with two names.
        let nearby = CLLocationCoordinate2D(latitude: here.latitude + 0.0003, longitude: here.longitude)
        try await db.record(
            batch: TimelineBatch(
                visits: [stay("a", key: "shop", hours: 1), stay("b", key: "kiosk", hours: 5, at: nearby)],
                activities: [],
                paths: []
            )
        )
        try await db.setPlaceName(placeKey: "shop", name: "Save-On-Foods")
        try await db.setPlaceName(placeKey: "kiosk", name: "The Kiosk")

        let problems = try await tools.call("find_problems", arguments: .object([:]))
        let overlapping = try XCTUnwrap(problems["places_on_top_of_each_other"]?.arrayValue)
        XCTAssertEqual(overlapping.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(overlapping[0]["metres_apart"]?.doubleValue), 60)
    }

    func testRenamingAndRelocatingGoThroughTheUsualPaths() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        _ = try await tools.call("rename_place", arguments: .object([
            "place_id": "office", "name": "Somewhere Else"
        ]))
        _ = try await tools.call("set_place_location", arguments: .object([
            "place_id": "office", "latitude": 49.2700, "longitude": -123.2500
        ]))

        let places = try await db.loadPlaces()
        XCTAssertEqual(places["office"]?.name, "Somewhere Else")
        XCTAssertEqual(places["office"]?.coordinate?.latitude ?? 0, 49.2700, accuracy: 0.0001)

        // And both are queued to reach the phone, like any edit made by hand.
        let queued = try await db.pendingChanges().map(\.kind)
        XCTAssertTrue(queued.contains(.place))
    }

    func testAnUnknownPlaceIsRefusedClearly() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        do {
            _ = try await tools.call("get_place", arguments: .object(["place_id": "nowhere"]))
            XCTFail("should have refused")
        } catch let failure as MCPToolFailure {
            XCTAssertTrue(failure.message.contains("no place with id"))
        }
    }
}
