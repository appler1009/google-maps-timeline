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

    func testDayPlotFoldsConsecutiveSamePlacePins() {
        let start = Date(timeIntervalSince1970: 1_718_445_600)
        let home1 = TimelineVisit(
            id: "a",
            start: start,
            end: start.addingTimeInterval(600),
            coordinate: Landmark.eiffelTower,
            semanticType: "Home",
            placeKey: "home"
        )
        let home2 = TimelineVisit(
            id: "b",
            start: start.addingTimeInterval(700),
            end: start.addingTimeInterval(1_200),
            coordinate: Landmark.eiffelTower,
            semanticType: "Home",
            placeKey: "home"
        )
        let work = TimelineVisit(
            id: "c",
            start: start.addingTimeInterval(1_300),
            end: start.addingTimeInterval(1_800),
            coordinate: Landmark.louvrePyramid,
            semanticType: "Work",
            placeKey: "work"
        )
        let day = DayRecord(
            day: Calendar.current.startOfDay(for: start),
            visits: [home1, home2, work],
            paths: [],
            activityLines: [],
            travelMeters: 3_000,
            region: MKCoordinateRegion(
                center: Landmark.eiffelTower,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        )
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        TimelineMapPlotter.install(on: map, day: day, place: nil, routed: [])
        let pins = map.annotations.compactMap { $0 as? VisitAnnotation }
        XCTAssertEqual(pins.count, 2)
        XCTAssertEqual(Set(pins.compactMap(\.placeKey)), Set(["home", "work"]))
        XCTAssertEqual(pins.first { $0.placeKey == "home" }?.visitID, "a")
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

    func testDifferentKindsDrawDriveUnderWalkWithCasing() {
        let start = CLLocationCoordinate2D(latitude: 48.858, longitude: 2.294)
        let end = CLLocationCoordinate2D(latitude: 48.861, longitude: 2.336)
        let later = Date(timeIntervalSince1970: 2_000)
        let earlier = Date(timeIntervalSince1970: 1_000)
        // Walking listed first chronologically later — display order must still put the drive underneath.
        let routed = [
            RoutedHop(id: "walk", points: [start, end], kind: .walking, at: later, until: later.addingTimeInterval(600)),
            RoutedHop(id: "drive", points: [start, end], kind: .automobile, at: earlier, until: earlier.addingTimeInterval(600)),
        ]

        let ordered = TimelineMapPlotter.orderedForDisplay(routed)
        XCTAssertEqual(ordered.map(\.kind), [.automobile, .walking])

        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        TimelineMapPlotter.addDayPaths(map: map, routed: routed)
        let lines = map.overlays.compactMap { $0 as? KindPolyline }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].kind, .automobile)
        XCTAssertFalse(lines[0].isCasing)
        XCTAssertEqual(lines[1].kind, .walking)
        XCTAssertTrue(lines[1].isCasing)
        XCTAssertEqual(lines[2].kind, .walking)
        XCTAssertFalse(lines[2].isCasing)
    }

    func testWalkAndCycleCasingsSitUnderEveryDashedStroke() {
        let start = CLLocationCoordinate2D(latitude: 48.858, longitude: 2.294)
        let end = CLLocationCoordinate2D(latitude: 48.861, longitude: 2.336)
        let routed = [
            RoutedHop(id: "walk", points: [start, end], kind: .walking, at: Date(timeIntervalSince1970: 2_000), until: Date(timeIntervalSince1970: 2_600)),
            RoutedHop(id: "cycle", points: [start, end], kind: .cycling, at: Date(timeIntervalSince1970: 1_000), until: Date(timeIntervalSince1970: 1_600)),
        ]
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        TimelineMapPlotter.addDayPaths(map: map, routed: routed)
        let lines = map.overlays.compactMap { $0 as? KindPolyline }
        XCTAssertEqual(lines.map(\.kind), [.cycling, .walking, .cycling, .walking])
        XCTAssertEqual(lines.map(\.isCasing), [true, true, false, false])
    }

    func testRawPathsHaveNoCasing() {
        let start = CLLocationCoordinate2D(latitude: 48.858, longitude: 2.294)
        let end = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)
        let routed = [
            RoutedHop(id: "flight", points: [start, end], kind: .raw, at: Date(timeIntervalSince1970: 1_000), until: Date(timeIntervalSince1970: 8_000)),
        ]
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        TimelineMapPlotter.addDayPaths(map: map, routed: routed)
        let lines = map.overlays.compactMap { $0 as? KindPolyline }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .raw)
        XCTAssertFalse(lines[0].isCasing)
    }

    func testSameKindPathsKeepChronologicalOrderWithoutCasing() {
        let a = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.29)
        let b = CLLocationCoordinate2D(latitude: 48.86, longitude: 2.30)
        let c = CLLocationCoordinate2D(latitude: 48.87, longitude: 2.31)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let routed = [
            RoutedHop(id: "second", points: [b, c], kind: .automobile, at: t1, until: t1.addingTimeInterval(300)),
            RoutedHop(id: "first", points: [a, b], kind: .automobile, at: t0, until: t0.addingTimeInterval(300)),
        ]

        let ordered = TimelineMapPlotter.orderedForDisplay(routed)
        XCTAssertEqual(ordered.map(\.id), ["first", "second"])

        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        TimelineMapPlotter.addDayPaths(map: map, routed: routed)
        let lines = map.overlays.compactMap { $0 as? KindPolyline }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { !$0.isCasing })
    }


    /// Going somewhere twice in a day is one place, so one pin.
    ///
    /// It used to be one pin per consecutive run of stays, each drawn where that
    /// stay was recorded. A music school visited in the morning and again in the
    /// evening got two, a couple of hundred metres apart because one fix was
    /// off, with the name written twice over itself. Places returned to within a
    /// single run only looked right because their stays landed on the same spot.
    func testOnePinPerPlaceHoweverOftenYouGoThere() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let school = CLLocationCoordinate2D(latitude: 49.274856, longitude: -123.144436)
        // The evening fix landed a couple of hundred metres west of the school.
        let strayFix = CLLocationCoordinate2D(latitude: 49.274484, longitude: -123.147782)

        func stay(_ id: String, hours: Double, at: CLLocationCoordinate2D, place: String) -> TimelineVisit {
            TimelineVisit(
                id: id,
                start: start.addingTimeInterval(hours * 3_600),
                end: start.addingTimeInterval(hours * 3_600 + 600),
                coordinate: at,
                semanticType: nil,
                placeKey: place
            )
        }
        let day = DayRecord(
            day: Calendar.current.startOfDay(for: start),
            visits: [
                stay("morning", hours: 1, at: school, place: "ChIJ_school"),
                stay("errand", hours: 3, at: Landmark.louvrePyramid, place: "ChIJ_shop"),
                stay("evening", hours: 8, at: strayFix, place: "ChIJ_school")
            ],
            paths: [],
            activityLines: [],
            travelMeters: 0,
            region: MKCoordinateRegion(center: school, latitudinalMeters: 1_000, longitudinalMeters: 1_000)
        )

        let pins = TimelineMapPlotter.dayPins(
            for: day,
            titles: ["ChIJ_school": "Vancouver Academy of Music", "ChIJ_shop": "A Shop"],
            placeCoordinates: ["ChIJ_school": school]
        )

        XCTAssertEqual(pins.count, 2, "two places, not three visits")
        let academy = try XCTUnwrap(pins.first { $0.placeKey == "ChIJ_school" })
        XCTAssertEqual(academy.title, "Vancouver Academy of Music")
        XCTAssertEqual(academy.coordinate.latitude, school.latitude, accuracy: 0.000001)
        XCTAssertEqual(academy.coordinate.longitude, school.longitude, accuracy: 0.000001)
    }

    /// A place with nowhere recorded for it still gets a pin, at the stay.
    func testAPlaceWithNoKnownLocationFallsBackToTheStay() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let day = DayRecord(
            day: Calendar.current.startOfDay(for: start),
            visits: [
                TimelineVisit(
                    id: "only",
                    start: start,
                    end: start.addingTimeInterval(600),
                    coordinate: Landmark.eiffelTower,
                    semanticType: nil,
                    placeKey: "unknown"
                )
            ],
            paths: [],
            activityLines: [],
            travelMeters: 0,
            region: MKCoordinateRegion(
                center: Landmark.eiffelTower,
                latitudinalMeters: 1_000,
                longitudinalMeters: 1_000
            )
        )
        let pins = TimelineMapPlotter.dayPins(for: day, titles: [:], placeCoordinates: [:])
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins[0].coordinate.latitude, Landmark.eiffelTower.latitude, accuracy: 0.000001)
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
        // Unwrap rather than subscript: routing is asynchronous, so on a slow
        // machine this is the one assertion that can legitimately fail — and
        // subscripting an empty array turns that failure into a crash report.
        XCTAssertEqual(store.routesForDisplay.count, 1)
        let route = try XCTUnwrap(store.routesForDisplay.first, "routing did not finish within the deadline")
        let points = route.points
        XCTAssertEqual(points.count, Landmark.eiffelToLouvreRoad.count)
        let first = try XCTUnwrap(points.first)
        let last = try XCTUnwrap(points.last)
        XCTAssertEqual(first.latitude, Landmark.eiffelTower.latitude, accuracy: 0.000001)
        XCTAssertEqual(last.longitude, Landmark.louvrePyramid.longitude, accuracy: 0.000001)
        XCTAssertEqual(route.kind, .automobile)
        XCTAssertEqual(store.focusRegion.center.latitude, day.region.center.latitude, accuracy: 0.0001)
    }
}

/// Place names written on the map do not land on top of one another.
final class PinLabelLayoutTests: XCTestCase {
    private let label = CGSize(width: 150, height: 28)

    func testFarApartPinsKeepTheirLabelsBelow() {
        let placements = PinLabelLayout.place([
            .init(id: "a", point: CGPoint(x: 100, y: 100), labelSize: label),
            .init(id: "b", point: CGPoint(x: 400, y: 400), labelSize: label),
        ])
        XCTAssertEqual(placements["a"], .below)
        XCTAssertEqual(placements["b"], .below)
    }

    /// A supermarket and the liquor store beside it, one label on the other.
    func testNeighboursDoNotShareASpot() {
        let pins: [PinLabelLayout.Pin] = [
            .init(id: "superstore", point: CGPoint(x: 200, y: 200), labelSize: label),
            .init(id: "liquor", point: CGPoint(x: 212, y: 206), labelSize: label),
        ]
        let placements = PinLabelLayout.place(pins)
        let frames = pins.map { pin in
            PinLabelLayout.rect(for: placements[pin.id]!, size: pin.labelSize!, at: pin.point)
        }
        XCTAssertFalse(frames[0].intersects(frames[1]))
        XCTAssertNotEqual(placements["superstore"], placements["liquor"])
    }

    /// A label is kept off another place's pin, not only off its label.
    func testALabelDoesNotCoverAPinBelowIt() {
        let placements = PinLabelLayout.place([
            .init(id: "upper", point: CGPoint(x: 200, y: 200), labelSize: label),
            .init(id: "lower", point: CGPoint(x: 200, y: 240), labelSize: nil),
        ])
        XCTAssertNotEqual(placements["upper"], .below)
        XCTAssertNil(placements["lower"])
    }

    /// The same pins, however they are listed, come out the same way.
    func testPlacementDoesNotDependOnOrder() {
        let a = PinLabelLayout.Pin(id: "a", point: CGPoint(x: 200, y: 200), labelSize: label)
        let b = PinLabelLayout.Pin(id: "b", point: CGPoint(x: 210, y: 205), labelSize: label)
        XCTAssertEqual(PinLabelLayout.place([a, b]), PinLabelLayout.place([b, a]))
    }
}
