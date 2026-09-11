import CoreLocation
import XCTest
@testable import Timeline

/// The first visit after Always is granted is the awkward one: CoreLocation knows
/// when you left but not when you arrived, because the stay began before it was
/// watching.
final class StopRepairTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func near(_ metres: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: home.latitude + metres / 111_320, longitude: home.longitude)
    }

    private func fix(_ minutes: Double, metresAway: Double) -> CapturedFix {
        CapturedFix(
            coordinate: near(metresAway),
            timestamp: origin.addingTimeInterval(minutes * 60),
            horizontalAccuracy: 30,
            speed: 0
        )
    }

    private func stop(
        startMinutes: Double,
        endMinutes: Double?,
        arrivalIsKnown: Bool = true
    ) -> CapturedStop {
        CapturedStop(
            coordinate: home,
            horizontalAccuracy: 65,
            start: origin.addingTimeInterval(startMinutes * 60),
            end: endMinutes.map { origin.addingTimeInterval($0 * 60) },
            arrivalIsKnown: arrivalIsKnown
        )
    }

    func testAStayThatEndsBeforeItStartsIsRefused() {
        // Exactly what shipped: arrival replaced by "now", a minute after the
        // real departure, so the stay had negative length and sorted into the
        // wrong part of the day.
        let inverted = stop(startMinutes: 61, endMinutes: 60)
        XCTAssertNil(StopRepair.repaired(inverted, openStart: nil, fixes: []))
    }

    func testAZeroLengthStayIsRefused() {
        XCTAssertNil(StopRepair.repaired(stop(startMinutes: 60, endMinutes: 60), openStart: nil, fixes: []))
    }

    func testAStayWeWatchedBeginKeepsItsOwnTimes() {
        let good = stop(startMinutes: 10, endMinutes: 70)
        let repaired = StopRepair.repaired(good, openStart: nil, fixes: [])
        XCTAssertEqual(repaired?.start, good.start)
        XCTAssertEqual(repaired?.end, good.end)
    }

    func testAnOpenStayProvidesTheMissingArrival() {
        // We saw them arrive at 10 past, then monitoring reported only a departure.
        let halfSeen = stop(startMinutes: 70, endMinutes: 70, arrivalIsKnown: false)
        let repaired = StopRepair.repaired(
            halfSeen,
            openStart: origin.addingTimeInterval(10 * 60),
            fixes: []
        )
        XCTAssertEqual(repaired?.start, origin.addingTimeInterval(10 * 60))
        XCTAssertEqual(repaired?.duration, 60 * 60)
    }

    func testTheFixesSayWhenWeGotThere() {
        // Fixes put us at home from 20 past until the departure at 70.
        let fixes = [
            fix(5, metresAway: 4_000),
            fix(20, metresAway: 40),
            fix(45, metresAway: 30),
            fix(69, metresAway: 25),
        ]
        let halfSeen = stop(startMinutes: 70, endMinutes: 70, arrivalIsKnown: false)
        let repaired = StopRepair.repaired(halfSeen, openStart: nil, fixes: fixes)
        XCTAssertEqual(repaired?.start, origin.addingTimeInterval(20 * 60))
    }

    func testAnEarlierPassNearbyDoesNotSwallowTheDay() {
        // Drove past home in the morning, went elsewhere, came back. The stay
        // starts when we came back, not at the morning pass.
        let fixes = [
            fix(5, metresAway: 60),
            fix(15, metresAway: 6_000),
            fix(40, metresAway: 50),
            fix(65, metresAway: 30),
        ]
        let halfSeen = stop(startMinutes: 70, endMinutes: 70, arrivalIsKnown: false)
        let repaired = StopRepair.repaired(halfSeen, openStart: nil, fixes: fixes)
        XCTAssertEqual(repaired?.start, origin.addingTimeInterval(40 * 60))
    }

    func testWithNoEvidenceItAssumesAShortStayRatherThanInventingOne() {
        let halfSeen = stop(startMinutes: 70, endMinutes: 70, arrivalIsKnown: false)
        let repaired = StopRepair.repaired(halfSeen, openStart: nil, fixes: [])
        XCTAssertEqual(repaired?.duration, StopRepair.unknownArrivalFallback)
        XCTAssertEqual(repaired?.end, origin.addingTimeInterval(70 * 60))
    }

    func testAnInferredArrivalIsCapped() {
        // An open stay from three days ago is stale, not evidence.
        let halfSeen = stop(startMinutes: 70, endMinutes: 70, arrivalIsKnown: false)
        let repaired = StopRepair.repaired(
            halfSeen,
            openStart: origin.addingTimeInterval(-3 * 24 * 60 * 60),
            fixes: []
        )
        XCTAssertEqual(repaired?.duration, StopRepair.unknownArrivalFallback)
    }

    func testAnOpenStayIsLeftOpen() {
        let open = stop(startMinutes: 10, endMinutes: nil)
        let repaired = StopRepair.repaired(open, openStart: nil, fixes: [])
        XCTAssertNotNil(repaired)
        XCTAssertNil(repaired?.end)
    }
}

/// The bad row is already in the library and on the server, so removing it has to
/// travel too — otherwise the next fetch brings it straight back.
final class InvalidVisitPurgeTests: XCTestCase {
    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func visit(_ id: String, startOffset: Double, endOffset: Double) -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: origin.addingTimeInterval(startOffset),
            end: origin.addingTimeInterval(endOffset),
            coordinate: CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460),
            semanticType: nil,
            placeKey: "home"
        )
    }

    func testAnInvertedStayIsRemovedAndTheDeletionIsQueued() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(
            batch: TimelineBatch(
                visits: [
                    visit("good", startOffset: 0, endOffset: 3_600),
                    // start 10:36:52, end 10:35:52 — the shape that shipped.
                    visit("inverted", startOffset: 60, endOffset: 1),
                ],
                activities: [],
                paths: []
            )
        )
        try await db.clearChangeLog()

        let purged = try await db.purgeInvalidVisits()
        XCTAssertEqual(purged, 1)

        let remaining = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(remaining.map(\.id), ["good"])

        let queued = try await db.pendingChanges()
        XCTAssertEqual(queued.count, 1, "the removal has to reach the other devices")
        XCTAssertEqual(queued.first?.rowID, "inverted")
        XCTAssertEqual(queued.first?.operation, .delete)
    }

    func testAHealthyLibraryIsLeftAlone() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(
            batch: TimelineBatch(visits: [visit("good", startOffset: 0, endOffset: 3_600)], activities: [], paths: [])
        )
        try await db.clearChangeLog()

        let purged = try await db.purgeInvalidVisits()
        XCTAssertEqual(purged, 0)
        let queued = try await db.pendingChangeCount()
        XCTAssertEqual(queued, 0, "a clean library should queue nothing")
    }
}

/// A stay begins where the journey to it ended. Core Motion records travel from
/// the coprocessor without needing location, so this evidence exists exactly when
/// fixes do not — the first morning after Always is granted.
final class TripBoundedArrivalTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 49.2645, longitude: -123.2460)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func halfSeenStop(departureMinutes: Double) -> CapturedStop {
        CapturedStop(
            coordinate: home,
            horizontalAccuracy: 65,
            start: origin.addingTimeInterval(departureMinutes * 60),
            end: origin.addingTimeInterval(departureMinutes * 60),
            arrivalIsKnown: false
        )
    }

    func testTheStayStartsWhereTheDriveHomeEnded() {
        // The real shape of the morning: drove out 08:35, back 08:55, left again
        // 10:35. Without the trip we had nothing; with it the stay is 08:55–10:35.
        let droveHomeAt = origin.addingTimeInterval(55 * 60)
        let repaired = StopRepair.repaired(
            halfSeenStop(departureMinutes: 155),
            openStart: nil,
            fixes: [],
            previousTripEnd: droveHomeAt
        )
        XCTAssertEqual(repaired?.start, droveHomeAt)
        XCTAssertEqual(repaired?.duration, 100 * 60)
    }

    func testAWatchedArrivalStillBeatsTheTrip() {
        let watched = origin.addingTimeInterval(60 * 60)
        let repaired = StopRepair.repaired(
            halfSeenStop(departureMinutes: 155),
            openStart: watched,
            fixes: [],
            previousTripEnd: origin.addingTimeInterval(55 * 60)
        )
        XCTAssertEqual(repaired?.start, watched, "what we saw outranks what we inferred")
    }

    func testTheTripBeatsTheFixesWhenBothExist() {
        // Fixes only start once location is permitted, so they can begin long
        // after the arrival they are supposed to date.
        let fixes = [
            CapturedFix(
                coordinate: home,
                timestamp: origin.addingTimeInterval(100 * 60),
                horizontalAccuracy: 30,
                speed: 0
            )
        ]
        let repaired = StopRepair.repaired(
            halfSeenStop(departureMinutes: 155),
            openStart: nil,
            fixes: fixes,
            previousTripEnd: origin.addingTimeInterval(55 * 60)
        )
        XCTAssertEqual(repaired?.start, origin.addingTimeInterval(55 * 60))
    }

    func testAStaleTripIsNotEvidence() {
        // A trip from days ago says nothing about today's stay.
        let repaired = StopRepair.repaired(
            halfSeenStop(departureMinutes: 155),
            openStart: nil,
            fixes: [],
            previousTripEnd: origin.addingTimeInterval(-3 * 24 * 60 * 60)
        )
        XCTAssertEqual(repaired?.duration, StopRepair.unknownArrivalFallback)
    }

    func testATripEndingAfterTheDepartureIsIgnored() {
        let repaired = StopRepair.repaired(
            halfSeenStop(departureMinutes: 155),
            openStart: nil,
            fixes: [],
            previousTripEnd: origin.addingTimeInterval(200 * 60)
        )
        XCTAssertEqual(repaired?.duration, StopRepair.unknownArrivalFallback)
    }
}
