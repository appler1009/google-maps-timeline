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

    /// The same name twice is worth acting on. A plaza is not.
    func testProblemsSeparateRealDuplicatesFromANeighbourhood() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        // The same shop written twice, a hundred metres apart.
        let along = CLLocationCoordinate2D(latitude: here.latitude + 0.0009, longitude: here.longitude)
        // And a different shop forty metres away, which is just next door.
        let nextDoor = CLLocationCoordinate2D(latitude: here.latitude + 0.00036, longitude: here.longitude)
        try await db.record(
            batch: TimelineBatch(
                visits: [
                    stay("a", key: "shop", hours: 1),
                    stay("b", key: "shop-again", hours: 5, at: along),
                    stay("c", key: "bank", hours: 9, at: nextDoor)
                ],
                activities: [],
                paths: []
            )
        )
        try await db.setPlaceName(placeKey: "shop", name: "Save-On-Foods")
        try await db.setPlaceName(placeKey: "shop-again", name: "Save-On-Foods")
        try await db.setPlaceName(placeKey: "bank", name: "RBC Royal Bank")

        let problems = try await tools.call("find_problems", arguments: .object([:]))
        let duplicates = try XCTUnwrap(problems["same_name_twice"]?.arrayValue)
        XCTAssertEqual(duplicates.count, 1, "the shop written twice")

        let neighbours = try XCTUnwrap(problems["close_enough_to_be_one_doorway"]?.arrayValue)
        XCTAssertTrue(neighbours.isEmpty, "a bank forty metres from a supermarket is not a duplicate")
    }

    /// A place that knows it is home reads fine without a name of its own.
    func testHomeIsNotReportedAsAnUnnamedProblem() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        let visits = (0..<6).map { index in
            TimelineVisit(
                id: "h\(index)",
                start: start.addingTimeInterval(Double(index) * 3_600),
                end: start.addingTimeInterval(Double(index) * 3_600 + 1_800),
                coordinate: here,
                semanticType: "Home",
                placeKey: "home"
            )
        }
        try await db.record(batch: TimelineBatch(visits: visits, activities: [], paths: []))

        let problems = try await tools.call("find_problems", arguments: .object([:]))
        let unnamed = try XCTUnwrap(problems["unnamed_places_with_history"]?.arrayValue)
        XCTAssertFalse(unnamed.contains { $0["place_id"]?.stringValue == "home" })
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

    /// A duplicate that was already folded is a duplicate that was dealt with.
    /// Reporting it again asks for the same work twice.
    func testAlreadyFoldedPlacesAreNotReportedAgain() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        let along = CLLocationCoordinate2D(latitude: here.latitude + 0.0009, longitude: here.longitude)
        try await db.record(
            batch: TimelineBatch(
                visits: [stay("a", key: "shop", hours: 1), stay("b", key: "shop-again", hours: 5, at: along)],
                activities: [],
                paths: []
            )
        )
        try await db.setPlaceName(placeKey: "shop", name: "Save-On-Foods")
        try await db.setPlaceName(placeKey: "shop-again", name: "Save-On-Foods")

        let before = try await tools.call("find_problems", arguments: .object([:]))
        XCTAssertEqual(before["same_name_twice"]?.arrayValue?.count, 1)

        _ = try await tools.call("merge_places", arguments: .object([
            "from_place_id": "shop-again", "into_place_id": "shop"
        ]))

        let after = try await tools.call("find_problems", arguments: .object([:]))
        XCTAssertEqual(after["same_name_twice"]?.arrayValue?.count, 0, "dealt with")
        XCTAssertEqual(
            after["places_holding_nothing"]?.arrayValue?.count, 0,
            "a folded place is meant to be empty"
        )
    }


    // MARK: - Editing a day

    /// The thing that was needed all day and had no tool: a stop that happened
    /// and was never captured.
    func testAStayCanBeAddedWithTimesGiven() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let from = start.addingTimeInterval(30 * 3_600)
        let added = try await tools.call("add_stay", arguments: .object([
            "place_id": "shop",
            "start": .number(from.timeIntervalSince1970),
            "end": .number(from.addingTimeInterval(600).timeIntervalSince1970)
        ]))
        XCTAssertEqual(added["minutes"]?.intValue, 10)

        let stayID = try XCTUnwrap(added["stay_id"]?.stringValue)
        let all = try await db.loadBatch()?.visits ?? []
        XCTAssertTrue(all.contains { $0.id == stayID && $0.placeKey == "shop" })
    }

    /// Leaving the times out asks the day's movement where it passed closest,
    /// the same as the Add Visit sheet does.
    func testAddingAStayWithoutTimesGuessesThem() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let day = MCPValue.dayFormatter.string(from: start.addingTimeInterval(3_600))
        let added = try await tools.call("add_stay", arguments: .object([
            "name": "Somewhere New",
            "latitude": .number(here.latitude),
            "longitude": .number(here.longitude),
            "date": .string(day)
        ]))
        XCTAssertNotNil(added["stay_id"]?.stringValue)
        let basis = try XCTUnwrap(added["times"]?.stringValue)
        XCTAssertTrue(basis.contains("guessed") || basis.contains("placeholder"))
    }

    func testTimesCanBeCorrectedAndAStaySplitInTwo() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let from = start.addingTimeInterval(3_600)
        let to = from.addingTimeInterval(4 * 3_600)
        _ = try await tools.call("set_stay_times", arguments: .object([
            "stay_id": "s1",
            "start": .number(from.timeIntervalSince1970),
            "end": .number(to.timeIntervalSince1970)
        ]))

        let middle = from.addingTimeInterval(2 * 3_600)
        let split = try await tools.call("split_stay", arguments: .object([
            "stay_id": "s1",
            "at": .number(middle.timeIntervalSince1970)
        ]))
        let second = try XCTUnwrap(split["second_half"]?.stringValue)

        let all = try await db.loadBatch()?.visits ?? []
        let first = try XCTUnwrap(all.first { $0.id == "s1" })
        let tail = try XCTUnwrap(all.first { $0.id == second })
        XCTAssertEqual(first.end, middle)
        XCTAssertEqual(tail.start, middle)
        XCTAssertEqual(tail.end, to)
        XCTAssertEqual(tail.placeKey, first.placeKey, "both halves are the same place")
    }

    /// Splitting somewhere outside the stay would invent a stay that never was.
    func testSplittingOutsideTheStayIsRefused() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        do {
            _ = try await tools.call("split_stay", arguments: .object([
                "stay_id": "s1",
                "at": .number(start.addingTimeInterval(90 * 3_600).timeIntervalSince1970)
            ]))
            XCTFail("should have refused")
        } catch let failure as MCPToolFailure {
            XCTAssertTrue(failure.message.contains("not inside it"))
        }
    }

    // MARK: - What was replaced

    /// Deleting takes a stay out of the timeline. It does not destroy it: a
    /// wrong reading of where you were is still evidence of something.
    func testADeletedStayIsKeptAndComesBack() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        _ = try await tools.call("delete_stay", arguments: .object([
            "stay_id": "s1", "reason": "was never there"
        ]))

        let gone = try await db.loadBatch()?.visits ?? []
        XCTAssertFalse(gone.contains { $0.id == "s1" }, "out of the timeline")

        let history = try await tools.call("stay_history", arguments: .object(["only_deleted": true]))
        let entry = try XCTUnwrap(history["versions"]?.arrayValue?.first)
        XCTAssertEqual(entry["stay_id"]?.stringValue, "s1")
        XCTAssertEqual(entry["reason"]?.stringValue, "was never there")
        XCTAssertEqual(entry["change"]?.stringValue, "deleted")
        XCTAssertEqual(entry["place"]?.stringValue, "Save-On-Foods", "still known for what it was")
        XCTAssertEqual(entry["still_in_timeline"]?.boolValue, false)

        _ = try await tools.call("restore_stay", arguments: .object(["stay_id": "s1"]))
        let back = try await db.loadBatch()?.visits ?? []
        XCTAssertTrue(back.contains { $0.id == "s1" })
    }

    /// Correcting times used to overwrite with nothing kept. A correction is
    /// usually right, and "usually" is the reason to keep what it replaced.
    func testRetimingAStayKeepsWhatItReplaced() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        let loaded = try await db.loadBatch()
        let before = try XCTUnwrap(loaded?.visits.first { $0.id == "s1" })

        let from = start.addingTimeInterval(50 * 3_600)
        _ = try await tools.call("set_stay_times", arguments: .object([
            "stay_id": "s1",
            "start": .number(from.timeIntervalSince1970),
            "end": .number(from.addingTimeInterval(900).timeIntervalSince1970)
        ]))

        let history = try await tools.call("stay_history", arguments: .object(["stay_id": "s1"]))
        let kept = try XCTUnwrap(history["versions"]?.arrayValue?.first)
        XCTAssertEqual(kept["change"]?.stringValue, "times")
        XCTAssertEqual(kept["still_in_timeline"]?.boolValue, true, "the stay is still there, just different")

        // And undone: the stay goes back to the times it had.
        _ = try await tools.call("restore_stay", arguments: .object(["stay_id": "s1"]))
        let reloaded = try await db.loadBatch()
        let restored = try XCTUnwrap(reloaded?.visits.first { $0.id == "s1" })
        XCTAssertEqual(restored.start, before.start)
        XCTAssertEqual(restored.end, before.end)
    }

    /// Splitting is an edit to the first half, so the whole stay is kept.
    func testSplittingKeepsTheWholeStay() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        let loadedBefore = try await db.loadBatch()
        let before = try XCTUnwrap(loadedBefore?.visits.first { $0.id == "s1" })

        let middle = before.start.addingTimeInterval(before.duration / 2)
        _ = try await tools.call("split_stay", arguments: .object([
            "stay_id": "s1", "at": .number(middle.timeIntervalSince1970)
        ]))

        let history = try await tools.call("stay_history", arguments: .object(["stay_id": "s1"]))
        let kept = try XCTUnwrap(history["versions"]?.arrayValue?.first)
        XCTAssertEqual(kept["change"]?.stringValue, "split")

        _ = try await tools.call("restore_stay", arguments: .object(["stay_id": "s1"]))
        let loadedWhole = try await db.loadBatch()
        let whole = try XCTUnwrap(loadedWhole?.visits.first { $0.id == "s1" })
        XCTAssertEqual(whole.end, before.end, "the first half is whole again")
    }

    /// History keeps its order, so what happened when is answerable later.
    func testHistoryKeepsItsOrder() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        _ = try await tools.call("delete_stay", arguments: .object(["stay_id": "s1"]))
        _ = try await tools.call("delete_stay", arguments: .object(["stay_id": "s3"]))

        let history = try await tools.call("stay_history", arguments: .object(["only_deleted": true]))
        let ids = try XCTUnwrap(history["versions"]?.arrayValue).compactMap { $0["stay_id"]?.stringValue }
        XCTAssertEqual(ids, ["s3", "s1"], "most recently changed first")
    }

    func testCountingTimeSpentSomewhere() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let counted = try await tools.call("stays_at_place", arguments: .object(["place_id": "shop"]))
        XCTAssertEqual(counted["place"]?.stringValue, "Save-On-Foods")
        XCTAssertEqual(counted["stays"]?.intValue, 2)
        XCTAssertNotNil(counted["first"]?.stringValue)
    }


    // MARK: - Right now

    /// The Mac has no recorder, so the only way it can answer "where am I" is
    /// for the stay to have reached it as a row.
    func testCurrentStayAnswersWhileAStayIsStillGoing() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let arrived = Date().addingTimeInterval(-2 * 3_600)
        try await db.setOpenStop(
            CapturedStop(coordinate: here, horizontalAccuracy: 50, start: arrived, end: nil),
            placeKey: "shop"
        )

        let now = try await tools.call("current_stay", arguments: .object([:]))
        XCTAssertEqual(now["in_progress"]?.boolValue, true)
        XCTAssertEqual(now["place"]?.stringValue, "Save-On-Foods")
        XCTAssertEqual(try XCTUnwrap(now["minutes_so_far"]?.doubleValue), 120, accuracy: 2)
    }

    /// And says so plainly when there is nothing to report, rather than
    /// implying the last stay of the day is where you are.
    func testCurrentStaySaysWhenNothingIsOpen() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let now = try await tools.call("current_stay", arguments: .object([:]))
        XCTAssertEqual(now["in_progress"]?.boolValue, false)
        XCTAssertNil(now["place"])
    }

    /// A stay that is still going has run for that long so far, not lasted it.
    func testAnInProgressStayIsFlaggedWhereStaysAreListed() async throws {
        let (tools, db, url) = library()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        try await db.setOpenStop(
            CapturedStop(coordinate: here, horizontalAccuracy: 50, start: Date().addingTimeInterval(-600), end: nil),
            placeKey: "shop"
        )

        let counted = try await tools.call("stays_at_place", arguments: .object(["place_id": "shop"]))
        let recent = try XCTUnwrap(counted["recent"]?.arrayValue)
        XCTAssertTrue(recent.contains { $0["in_progress"]?.boolValue == true })
    }

}
