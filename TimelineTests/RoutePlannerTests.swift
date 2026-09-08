import XCTest
import CoreLocation
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
        let first = visit("a", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let second = visit("b", start: start.addingTimeInterval(600), end: start.addingTimeInterval(1_200), at: Landmark.eiffelTower)
        XCTAssertEqual(RoutePlanner.collapsedSpots([first, second]).count, 1)
    }

    func testSkipsHopsShorterThanFortyMeters() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let nearby = CLLocationCoordinate2D(latitude: Landmark.eiffelTower.latitude, longitude: Landmark.eiffelTower.longitude + 0.0001)
        let from = visit("a", start: start, end: start.addingTimeInterval(600), at: Landmark.eiffelTower)
        let to = visit("b", start: start.addingTimeInterval(700), end: start.addingTimeInterval(1_200), at: nearby)
        XCTAssertTrue(RoutePlanner.hopsAcross(from: (from, Landmark.eiffelTower), to: (to, nearby), activities: []).isEmpty)
    }

    private func visit(_ id: String, start: Date, end: Date, at coordinate: CLLocationCoordinate2D) -> TimelineVisit {
        TimelineVisit(id: id, start: start, end: end, coordinate: coordinate, semanticType: nil, placeKey: id)
    }

    private func bundledFixture() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "eiffel-tower-day", withExtension: "json"))
    }
}
