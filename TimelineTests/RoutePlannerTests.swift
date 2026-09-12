import XCTest
import CoreLocation
import MapKit
@testable import Timeline

final class RoutePlannerTests: XCTestCase {
    func testStayToStayHopUsesAutomobileForTheParisFixture() throws {
        let parsed = try TimelineParser.parse(data: Data(contentsOf: bundledFixture()), sourceName: "fixture")
        let day = try XCTUnwrap(parsed.days.first)
        let hops = RoutePlanner.plannedHops(for: day)
        XCTAssertEqual(hops.count, 1)
        XCTAssertEqual(hops[0].kind, .automobile)
        XCTAssertEqual(hops[0].points.count, 2)
        XCTAssertEqual(hops[0].points[0].latitude, Landmark.eiffelTower.latitude, accuracy: 0.000001)
        XCTAssertEqual(hops[0].points[0].longitude, Landmark.eiffelTower.longitude, accuracy: 0.000001)
        XCTAssertEqual(hops[0].points[1].latitude, Landmark.louvrePyramid.latitude, accuracy: 0.000001)
        XCTAssertEqual(hops[0].points[1].longitude, Landmark.louvrePyramid.longitude, accuracy: 0.000001)
    }

    func testCollapsesConsecutiveVisitsAtTheSamePin() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let first = visit("a", placeKey: "home", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let second = visit("b", placeKey: "home", start: start.addingTimeInterval(600), end: start.addingTimeInterval(1_200), at: Landmark.eiffelTower)
        XCTAssertEqual(RoutePlanner.collapsedSpots([first, second]).count, 1)
    }

    func testCollapsesConsecutiveSamePlaceKeyEvenWhenFarApart() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let first = visit("a", placeKey: "home", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let second = visit("b", placeKey: "home", start: start.addingTimeInterval(700), end: start.addingTimeInterval(1_200), at: Landmark.louvrePyramid)
        XCTAssertEqual(RoutePlanner.collapsedSpots([first, second]).count, 1)
        let day = DayRecord(
            day: Calendar.current.startOfDay(for: start),
            visits: [first, second],
            paths: [],
            activityLines: [
                ActivityLine(
                    id: "noise",
                    at: first.end,
                    until: second.start,
                    start: Landmark.eiffelTower,
                    end: Landmark.louvrePyramid,
                    kind: .automobile
                ),
            ],
            travelMeters: 3_000,
            region: MKCoordinateRegion(
                center: Landmark.eiffelTower,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        )
        XCTAssertTrue(RoutePlanner.plannedHops(for: day).isEmpty)
    }

    func testKeepsNonConsecutiveRevisitsAsSeparateSpots() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let home1 = visit("a", placeKey: "home", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let work = visit("b", placeKey: "work", start: start.addingTimeInterval(700), end: start.addingTimeInterval(1_200), at: Landmark.louvrePyramid)
        let home2 = visit("c", placeKey: "home", start: start.addingTimeInterval(1_300), end: start.addingTimeInterval(1_800), at: Landmark.eiffelTower)
        XCTAssertEqual(RoutePlanner.collapsedSpots([home1, work, home2]).count, 3)
        let day = DayRecord(
            day: Calendar.current.startOfDay(for: start),
            visits: [home1, work, home2],
            paths: [],
            activityLines: [],
            travelMeters: 6_000,
            region: MKCoordinateRegion(
                center: Landmark.eiffelTower,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        )
        XCTAssertEqual(RoutePlanner.plannedHops(for: day).count, 2)
    }

    func testSkipsHopsShorterThanFortyMeters() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let nearby = CLLocationCoordinate2D(latitude: Landmark.eiffelTower.latitude, longitude: Landmark.eiffelTower.longitude + 0.0001)
        let from = visit("a", placeKey: "a", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let to = visit("b", placeKey: "b", start: start.addingTimeInterval(700), end: start.addingTimeInterval(1_200), at: nearby)
        XCTAssertTrue(RoutePlanner.hopsAcross(from: (from, Landmark.eiffelTower), to: (to, nearby), activities: []).isEmpty)
    }

    func testSkipsHopsBetweenSamePlaceKey() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let from = visit("a", placeKey: "home", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let to = visit("b", placeKey: "home", start: start.addingTimeInterval(700), end: start.addingTimeInterval(1_200), at: Landmark.louvrePyramid)
        XCTAssertTrue(RoutePlanner.hopsAcross(from: (from, Landmark.eiffelTower), to: (to, Landmark.louvrePyramid), activities: []).isEmpty)
    }


    /// A drive does not become a walk because the day around it was quiet.
    ///
    /// Speed used to be measured across the whole gap between two stays, which
    /// includes every minute spent standing still. Leaving the shops at 11:00
    /// and reaching home at 16:00 made an eight-minute drive read as 0.1 m/s,
    /// and that fake slowness then overrode Core Motion saying plainly it was a
    /// car. Correcting a place's location made it worse, since a longer distance
    /// over the same idle gap still looks slow.
    func testLongIdleGapDoesNotTurnADriveIntoAWalk() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let shops = visit("shops", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        // Home, two kilometres and five hours later.
        let home = visit(
            "home",
            start: start.addingTimeInterval(18_600),
            end: start.addingTimeInterval(22_000),
            at: Landmark.louvrePyramid
        )
        // The drive itself: eight minutes, an hour after leaving the shops.
        let drive = ActivityLine(
            id: "drive",
            at: shops.end.addingTimeInterval(3_600),
            until: shops.end.addingTimeInterval(4_080),
            start: Landmark.eiffelTower,
            end: Landmark.louvrePyramid,
            kind: .automobile
        )
        XCTAssertEqual(RoutePlanner.kind(from: shops, to: home, activities: [drive]), .automobile)
    }

    /// The override it relies on still has to work: Core Motion reports the car
    /// you were sitting in, and that bleeds into the walk at either end of the
    /// journey. A hop that is slow over the time actually spent moving is that
    /// walk, whatever the accelerometer thought.
    func testSlowHopOverItsOwnTravelTimeIsStillAWalk() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let first = visit("a", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let nearby = CLLocationCoordinate2D(
            latitude: Landmark.eiffelTower.latitude + 0.0012,
            longitude: Landmark.eiffelTower.longitude
        )
        // 130 m over a ten-minute stroll.
        let second = visit(
            "b",
            start: start.addingTimeInterval(1_200),
            end: start.addingTimeInterval(1_800),
            at: nearby
        )
        let bleed = ActivityLine(
            id: "bleed",
            at: first.end,
            until: second.start,
            start: Landmark.eiffelTower,
            end: nearby,
            kind: .automobile
        )
        XCTAssertEqual(RoutePlanner.kind(from: first, to: second, activities: [bleed]), .walking)
    }


    /// Arriving somewhere is timed from when the run began, not when its last
    /// stay did. Home split into an afternoon and an evening stay; the drive
    /// home was being timed against the evening stay's start, five hours later,
    /// which made it read as a walk.
    func testCollapsedSpotSpansItsWholeRun() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let shops = visit("shops", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let homeAfternoon = visit(
            "home-1",
            placeKey: "home",
            start: start.addingTimeInterval(1_080),
            end: start.addingTimeInterval(18_000),
            at: Landmark.louvrePyramid
        )
        let homeEvening = visit(
            "home-2",
            placeKey: "home",
            start: start.addingTimeInterval(18_600),
            end: start.addingTimeInterval(22_000),
            at: Landmark.louvrePyramid
        )
        let spots = RoutePlanner.collapsedSpots([shops, homeAfternoon, homeEvening])
        XCTAssertEqual(spots.count, 2)
        XCTAssertEqual(spots[1].0.start, homeAfternoon.start, "arrival is when the run began")
        XCTAssertEqual(spots[1].0.end, homeEvening.end, "departure is when the run ended")

        // An eight-minute drive, not a five-hour crawl.
        let drive = ActivityLine(
            id: "drive",
            at: shops.end,
            until: homeAfternoon.start,
            start: Landmark.eiffelTower,
            end: Landmark.louvrePyramid,
            kind: .automobile
        )
        XCTAssertEqual(RoutePlanner.kind(from: spots[0].0, to: spots[1].0, activities: [drive]), .automobile)
    }

    private func visit(
        _ id: String,
        placeKey: String? = nil,
        start: Date,
        end: Date,
        at coordinate: CLLocationCoordinate2D
    ) -> TimelineVisit {
        TimelineVisit(id: id, start: start, end: end, coordinate: coordinate, semanticType: nil, placeKey: placeKey ?? id)
    }

    private func bundledFixture() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "eiffel-tower-day", withExtension: "json"))
    }
}
