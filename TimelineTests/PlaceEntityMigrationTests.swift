import CoreLocation
import XCTest
@testable import Timeline

/// The old model carried the place inside the stay. These pin the shape of
/// turning that into places as rows.
final class PlaceEntityMigrationTests: XCTestCase {
    private let downtown = CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
    private let corrected = CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.2000)

    func testEachDistinctKeyBecomesOnePlace() {
        let planned = PlaceEntityMigration.plan(
            visitKeys: ["ChIJhome", "ChIJwork", "49.2827,-123.1207"],
            names: [:],
            locations: [:],
            merges: [:],
            semanticTypes: [:],
            averageCoordinates: [:]
        )
        XCTAssertEqual(planned.count, 3)
        XCTAssertEqual(Set(planned.map(\.id)), ["ChIJhome", "ChIJwork", "49.2827,-123.1207"])
    }

    func testAMergedKeyIsNotAPlaceOfItsOwn() {
        let planned = PlaceEntityMigration.plan(
            visitKeys: ["annex", "main"],
            names: [:],
            locations: [:],
            merges: ["annex": "main"],
            semanticTypes: [:],
            averageCoordinates: [:]
        )
        XCTAssertEqual(planned.map(\.id), ["main"], "a merged key is another name for its target")
        XCTAssertEqual(planned[0].keys, ["annex", "main"], "but both keys still resolve to it")
    }

    func testAChainOfMergesCollapsesToTheSurvivor() {
        let planned = PlaceEntityMigration.plan(
            visitKeys: ["a", "b", "c"],
            names: [:],
            locations: [:],
            merges: ["a": "b", "b": "c"],
            semanticTypes: [:],
            averageCoordinates: [:]
        )
        XCTAssertEqual(planned.map(\.id), ["c"])
        XCTAssertEqual(planned[0].keys, ["a", "b", "c"])
    }

    func testNamesAndSemanticsCarryOver() {
        let planned = PlaceEntityMigration.plan(
            visitKeys: ["ChIJhome"],
            names: ["ChIJhome": "Home Sweet Home"],
            locations: [:],
            merges: [:],
            semanticTypes: ["ChIJhome": "Home"],
            averageCoordinates: ["ChIJhome": downtown]
        )
        XCTAssertEqual(planned[0].name, "Home Sweet Home")
        XCTAssertEqual(planned[0].semanticType, "Home")
        XCTAssertEqual(planned[0].coordinate?.latitude ?? 0, downtown.latitude, accuracy: 0.000_001)
    }

    func testACorrectedLocationBeatsTheAverageOfTheStays() {
        let planned = PlaceEntityMigration.plan(
            visitKeys: ["ChIJstaples"],
            names: [:],
            locations: ["ChIJstaples": PlaceLocation(coordinate: corrected, updatedAt: 10)],
            merges: [:],
            semanticTypes: [:],
            averageCoordinates: ["ChIJstaples": downtown]
        )
        XCTAssertEqual(
            planned[0].coordinate?.latitude ?? 0,
            corrected.latitude,
            accuracy: 0.000_001,
            "a correction outranks where the fixes landed"
        )
    }

    func testACorrectionOnAMergedKeyIsNotLost() {
        let planned = PlaceEntityMigration.plan(
            visitKeys: ["annex", "main"],
            names: [:],
            locations: ["annex": PlaceLocation(coordinate: corrected, updatedAt: 10)],
            merges: ["annex": "main"],
            semanticTypes: [:],
            averageCoordinates: ["main": downtown]
        )
        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(planned[0].coordinate?.latitude ?? 0, corrected.latitude, accuracy: 0.000_001)
    }

    func testTheNewestCorrectionWins() {
        let older = PlaceLocation(coordinate: downtown, updatedAt: 10)
        let newer = PlaceLocation(coordinate: corrected, updatedAt: 20)
        let planned = PlaceEntityMigration.plan(
            visitKeys: ["annex", "main"],
            names: [:],
            locations: ["annex": older, "main": newer],
            merges: ["annex": "main"],
            semanticTypes: [:],
            averageCoordinates: [:]
        )
        XCTAssertEqual(planned[0].coordinate?.latitude ?? 0, corrected.latitude, accuracy: 0.000_001)
    }

    func testEveryOldKeyResolvesToExactlyOnePlace() {
        let planned = PlaceEntityMigration.plan(
            visitKeys: ["a", "b", "c", "d"],
            names: [:],
            locations: [:],
            merges: ["a": "b", "c": "d"],
            semanticTypes: [:],
            averageCoordinates: [:]
        )
        let linkage = PlaceEntityMigration.linkage(for: planned)
        XCTAssertEqual(linkage["a"], "b")
        XCTAssertEqual(linkage["b"], "b")
        XCTAssertEqual(linkage["c"], "d")
        XCTAssertEqual(linkage["d"], "d")
        XCTAssertEqual(Set(linkage.values).count, 2, "four keys, two places")
    }

    // MARK: - Against the database

    func testMigrationLinksEveryStayAndIsIdempotent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func visit(_ id: String, key: String, hours: Double) -> TimelineVisit {
            TimelineVisit(
                id: id,
                start: start.addingTimeInterval(hours * 3_600),
                end: start.addingTimeInterval(hours * 3_600 + 1_800),
                coordinate: downtown,
                semanticType: key == "ChIJhome" ? "Home" : nil,
                placeKey: key
            )
        }
        try await db.upsert(
            batch: TimelineBatch(
                visits: [
                    visit("v1", key: "ChIJhome", hours: 1),
                    visit("v2", key: "ChIJhome", hours: 5),
                    visit("v3", key: "annex", hours: 9),
                ],
                activities: [],
                paths: []
            ),
            sourceName: "Timeline.json"
        )
        try await db.setPlaceName(placeKey: "ChIJhome", name: "Home")
        try await db.mergePlace(from: "annex", into: "ChIJhome", targetSemantic: "Home")

        // Stays written by this build already point at a place, so the migration
        // has nothing left to link — which is the point of it being idempotent.
        let unlinked = try await db.unlinkedVisitCount()
        XCTAssertEqual(unlinked, 0, "every stay should point at a place")

        let result = try await db.migrateToPlaceEntities()
        XCTAssertEqual(result.visitsLinked, 0, "nothing left over for it to do")

        // And the merge still resolves: the annex reads as home.
        let visits = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(Set(visits.map(\.placeKey)), ["ChIJhome"], "the annex folded into home")
    }
}

/// One stop should be one row. It was two, because the stay's id was hashed from
/// its place and re-clustering picked a different one.
final class DuplicateStayCollapseTests: XCTestCase {
    private let staples = CLLocationCoordinate2D(latitude: 49.2665, longitude: -123.2452)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupstay-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private func stay(_ id: String, key: String) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: start,
            end: start.addingTimeInterval(7 * 60),
            coordinate: staples,
            semanticType: nil,
            placeKey: key
        )
    }

    func testAStayIdNoLongerDependsOnItsPlace() {
        // The whole cause: cluster the same stop onto two places, get two ids.
        let onto = PlaceClusterer.visitID(placeKey: "ChIJstaples", start: start)
        let ontoOther = PlaceClusterer.visitID(placeKey: "49.2665,-123.2452", start: start)
        XCTAssertEqual(onto, ontoOther, "re-clustering must update the stay, not mint another")
    }

    func testTheSameStopUnderTwoPlacesBecomesOne() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(
            batch: TimelineBatch(
                visits: [stay("as-coordinate", key: "49.2665,-123.2452"), stay("as-google", key: "ChIJstaples")],
                activities: [],
                paths: []
            )
        )
        try await db.setPlaceName(placeKey: "ChIJstaples", name: "Staples")
        _ = try await db.migrateToPlaceEntities()

        let collapsed = try await db.collapseDuplicateStays()
        XCTAssertEqual(collapsed, 1)

        let visits = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.id, "as-google", "the named place is the one already reasoned about")
    }

    func testTwoRealStopsAreNotCollapsed() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let later = TimelineVisit(
            id: "later",
            start: start.addingTimeInterval(3_600),
            end: start.addingTimeInterval(3_600 + 420),
            coordinate: staples,
            semanticType: nil,
            placeKey: "ChIJstaples"
        )
        try await db.record(
            batch: TimelineBatch(visits: [stay("first", key: "ChIJstaples"), later], activities: [], paths: [])
        )
        _ = try await db.migrateToPlaceEntities()

        let collapsed = try await db.collapseDuplicateStays()
        XCTAssertEqual(collapsed, 0, "two visits an hour apart are two visits")
    }

    func testTheCollapseTravelsToTheOtherDevices() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(
            batch: TimelineBatch(
                visits: [stay("a", key: "49.2665,-123.2452"), stay("b", key: "ChIJstaples")],
                activities: [],
                paths: []
            )
        )
        _ = try await db.migrateToPlaceEntities()
        try await db.clearChangeLog()
        _ = try await db.collapseDuplicateStays()

        let queued = try await db.pendingChanges()
        XCTAssertEqual(queued.map(\.operation), [.delete])
    }
}

/// A stay written now must point at a place immediately. Leaving that to the
/// migration meant a stay recorded in the background had no place until the app
/// was next opened — and the recorder runs precisely when the app is not.
final class NewStayLinkingTests: XCTestCase {
    private let cafe = CLLocationCoordinate2D(latitude: 49.2765, longitude: -123.0680)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("newlink-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private func stay(_ id: String, key: String, semantic: String? = nil) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: start,
            end: start.addingTimeInterval(1_800),
            coordinate: cafe,
            semanticType: semantic,
            placeKey: key
        )
    }

    func testARecordedStayPointsAtAPlaceStraightAway() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(batch: TimelineBatch(visits: [stay("v1", key: "cafe")], activities: [], paths: []))

        let unlinked = try await db.unlinkedVisitCount()
        XCTAssertEqual(unlinked, 0, "no waiting for the next launch")

        let places = try await db.loadPlaces()
        XCTAssertNotNil(places["cafe"], "and the place it points at exists")
        XCTAssertEqual(places["cafe"]?.coordinate?.latitude ?? 0, cafe.latitude, accuracy: 0.000_001)
    }

    func testAnImportedStayLinksToo() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.upsert(
            batch: TimelineBatch(visits: [stay("g1", key: "ChIJhome", semantic: "Home")], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        let unlinked = try await db.unlinkedVisitCount()
        XCTAssertEqual(unlinked, 0)
        let places = try await db.loadPlaces()
        XCTAssertEqual(places["ChIJhome"]?.semanticType, "Home")
    }

    func testWritingAStayNeverOverwritesWhatIsKnownAboutThePlace() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(batch: TimelineBatch(visits: [stay("v1", key: "cafe")], activities: [], paths: []))
        try await db.setPlaceName(placeKey: "cafe", name: "Continental Coffee")
        let corrected = CLLocationCoordinate2D(latitude: 49.2700, longitude: -123.0700)
        try await db.setPlaceLocation(placeKey: "cafe", coordinate: corrected)

        // A later stay at the same place arrives with a raw fix. It must not undo
        // the name or the correction.
        try await db.record(batch: TimelineBatch(visits: [stay("v2", key: "cafe")], activities: [], paths: []))

        let places = try await db.loadPlaces()
        XCTAssertEqual(places["cafe"]?.name, "Continental Coffee")
        XCTAssertEqual(
            places["cafe"]?.coordinate?.latitude ?? 0,
            corrected.latitude,
            accuracy: 0.000_001,
            "a raw fix is weaker evidence than a correction"
        )
    }
}
