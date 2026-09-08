import XCTest
import MapKit
@testable import Timeline

@MainActor
final class MarkerMapTests: XCTestCase {
    func testEiffelTowerPinSitsOnThePublishedCoordinate() throws {
        let parsed = try TimelineParser.parse(data: Data(contentsOf: bundledFixture()), sourceName: "fixture")
        let home = try XCTUnwrap(parsed.days.first?.visits.first { $0.semanticType == "Home" })
        let coordinate = try XCTUnwrap(home.coordinate)

        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        map.setRegion(
            MKCoordinateRegion(
                center: Landmark.eiffelTower,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ),
            animated: false
        )
        #if os(iOS)
        map.layoutIfNeeded()
        #else
        map.layoutSubtreeIfNeeded()
        #endif

        let pin = TimelineMapPlotter.pin(visit: home, coordinate: coordinate)
        map.addAnnotation(pin)

        let pinPoint = map.convert(pin.coordinate, toPointTo: map)
        let expectedPoint = map.convert(Landmark.eiffelTower, toPointTo: map)
        let error = hypot(pinPoint.x - expectedPoint.x, pinPoint.y - expectedPoint.y)
        XCTAssertLessThan(error, 0.75, "Home pin should land on the Eiffel Tower WGS84 coordinate")

        let swapped = CLLocationCoordinate2D(
            latitude: Landmark.eiffelTower.longitude,
            longitude: Landmark.eiffelTower.latitude
        )
        let swappedPoint = map.convert(swapped, toPointTo: map)
        XCTAssertGreaterThan(
            hypot(pinPoint.x - swappedPoint.x, pinPoint.y - swappedPoint.y),
            80,
            "A lat/lon swap would move the pin far from the tower"
        )
    }

    func testDayPlotInstallsMarkersAndMockedRoute() throws {
        let parsed = try TimelineParser.parse(data: Data(contentsOf: bundledFixture()), sourceName: "fixture")
        let day = try XCTUnwrap(parsed.days.first)
        let hops = RoutePlanner.plannedHops(for: day)
        let routed = hops.map { hop in
            RoutedHop(
                id: hop.id,
                points: ScriptedMapDirectionsClient.dogleg().hops(hop.points[0], hop.points[1], .automobile),
                kind: hop.kind,
                at: hop.at,
                until: hop.until
            )
        }

        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        TimelineMapPlotter.install(on: map, day: day, place: nil, routed: routed)

        let pins = map.annotations.compactMap { $0 as? VisitAnnotation }
        XCTAssertEqual(pins.count, 2)
        XCTAssertTrue(pins.contains { $0.title == "Home" })
        XCTAssertTrue(pins.contains { $0.title == "Work" })

        let lines = map.overlays.compactMap { $0 as? KindPolyline }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].pointCount, 3)
        XCTAssertEqual(lines[0].kind, .automobile)
    }

    func testPlacePlotUsesLouvreCoordinate() throws {
        let parsed = try TimelineParser.parse(data: Data(contentsOf: bundledFixture()), sourceName: "fixture")
        let work = try XCTUnwrap(parsed.places.first { $0.semanticType == "Work" })
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        TimelineMapPlotter.install(on: map, day: nil, place: work, routed: [])
        let pin = try XCTUnwrap(map.annotations.first as? VisitAnnotation)
        XCTAssertEqual(pin.coordinate.latitude, Landmark.louvrePyramid.latitude, accuracy: 0.000001)
        XCTAssertEqual(pin.coordinate.longitude, Landmark.louvrePyramid.longitude, accuracy: 0.000001)
    }

    private func bundledFixture() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "eiffel-tower-day", withExtension: "json"))
    }
}

@MainActor
final class TimelineStoreTests: XCTestCase {
    func testSelectingTheFixtureDayProducesAMockedRoute() async throws {
        let store = TimelineStore.uiTesting()
        let url = try XCTUnwrap(Bundle.main.url(forResource: "eiffel-tower-day", withExtension: "json"))
        let parsed = try TimelineParser.parse(data: Data(contentsOf: url), sourceName: "fixture")
        store.apply(parsed)
        let day = try XCTUnwrap(parsed.days.first)
        store.select(day: day)

        let deadline = Date().addingTimeInterval(2)
        while store.routesForDisplay.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.routesForDisplay.count, 1)
        let points = store.routesForDisplay[0].points
        XCTAssertEqual(points.count, Landmark.eiffelToLouvreRoad.count)
        XCTAssertEqual(points.first!.latitude, Landmark.eiffelTower.latitude, accuracy: 0.000001)
        XCTAssertEqual(points.last!.longitude, Landmark.louvrePyramid.longitude, accuracy: 0.000001)
        XCTAssertEqual(store.routesForDisplay[0].kind, .automobile)
        XCTAssertEqual(store.focusRegion.center.latitude, day.region.center.latitude, accuracy: 0.0001)
    }
}
