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
