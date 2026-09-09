import XCTest
import CoreLocation
import MapKit
@testable import Timeline

final class GeoTests: XCTestCase {
    func testParsesEiffelTowerGeoURI() {
        let coordinate = Geo.coordinate(from: Landmark.eiffelTowerGeoURI)
        XCTAssertNotNil(coordinate)
        XCTAssertEqual(coordinate!.latitude, Landmark.eiffelTower.latitude, accuracy: 0.000001)
        XCTAssertEqual(coordinate!.longitude, Landmark.eiffelTower.longitude, accuracy: 0.000001)
    }

    func testDoesNotSwapLatitudeAndLongitude() {
        let coordinate = Geo.coordinate(from: Landmark.eiffelTowerGeoURI)!
        let swapped = CLLocationCoordinate2D(
            latitude: Landmark.eiffelTower.longitude,
            longitude: Landmark.eiffelTower.latitude
        )
        XCTAssertGreaterThan(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: swapped.latitude, longitude: swapped.longitude)),
            1_000_000
        )
    }

    func testRejectsInvalidCoordinates() {
        XCTAssertNil(Geo.coordinate(from: "geo:200,0"))
        XCTAssertNil(Geo.coordinate(from: "not-a-geo"))
        XCTAssertNil(Geo.coordinate(from: nil))
    }

    func testPlaceKeyPrefersStableID() {
        XCTAssertEqual(Geo.placeKey(id: "eiffel-tower", coordinate: Landmark.eiffelTower), "eiffel-tower")
        XCTAssertEqual(
            Geo.placeKey(id: nil, coordinate: Landmark.eiffelTower),
            String(format: "%.4f,%.4f", Landmark.eiffelTower.latitude, Landmark.eiffelTower.longitude)
        )
    }
}

final class PathOffsetTests: XCTestCase {
    func testLaneSignsSeparateWalkAndCycle() {
        XCTAssertEqual(PathOffset.lane(for: .automobile), 0)
        XCTAssertEqual(PathOffset.lane(for: .raw), 0)
        XCTAssertEqual(PathOffset.lane(for: .cycling), 1)
        XCTAssertEqual(PathOffset.lane(for: .walking), -1)
    }

    func testSingleKindKeepsOriginalPoints() {
        let points = [
            CLLocationCoordinate2D(latitude: 48.858, longitude: 2.294),
            CLLocationCoordinate2D(latitude: 48.861, longitude: 2.336),
        ]
        let drawn = PathOffset.displayPoints(points, kind: .walking, amongKinds: [.walking])
        XCTAssertEqual(drawn.count, 2)
        XCTAssertEqual(drawn[0].latitude, points[0].latitude, accuracy: 1e-9)
        XCTAssertEqual(drawn[1].longitude, points[1].longitude, accuracy: 1e-9)
    }

    func testWalkOffsetsLeftOfEastboundDrive() {
        // Due-east segment: geographic left-of-travel is north (higher latitude).
        // Walking uses the negative lane (right of travel → south); we assert via
        // an explicit positive offset below, then confirm lane signs for walk/cycle.
        let start = CLLocationCoordinate2D(latitude: 48.8600, longitude: 2.3000)
        let end = CLLocationCoordinate2D(latitude: 48.8600, longitude: 2.3100)
        let points = [start, end]
        let kinds: Set<TravelKind> = [.automobile, .walking]

        let drive = PathOffset.displayPoints(points, kind: .automobile, amongKinds: kinds)
        XCTAssertEqual(drive[0].latitude, start.latitude, accuracy: 1e-9)
        XCTAssertEqual(drive[1].latitude, end.latitude, accuracy: 1e-9)

        let midSpan = [
            start,
            CLLocationCoordinate2D(latitude: 48.8600, longitude: 2.3050),
            end,
        ]
        let leftOfTravel = PathOffset.offset(midSpan, meters: PathOffset.laneWidthMeters)
        XCTAssertGreaterThan(leftOfTravel[1].latitude, 48.8600)

        let walkLane = PathOffset.offset(midSpan, meters: PathOffset.lane(for: .walking) * PathOffset.laneWidthMeters)
        XCTAssertLessThan(walkLane[1].latitude, 48.8600)

        let walk = PathOffset.displayPoints(points, kind: .walking, amongKinds: kinds)
        // Walk display still tapers endpoints toward the unoffset pins.
        XCTAssertEqual(walk[0].latitude, start.latitude, accuracy: 1e-7)
        XCTAssertEqual(walk[1].latitude, end.latitude, accuracy: 1e-7)
    }

    func testCycleOffsetsOppositeWalk() {
        let start = CLLocationCoordinate2D(latitude: 48.8600, longitude: 2.3000)
        let mid = CLLocationCoordinate2D(latitude: 48.8600, longitude: 2.3050)
        let end = CLLocationCoordinate2D(latitude: 48.8600, longitude: 2.3100)
        let points = [start, mid, end]
        let kinds: Set<TravelKind> = [.walking, .cycling]
        let walk = PathOffset.displayPoints(points, kind: .walking, amongKinds: kinds)
        let cycle = PathOffset.displayPoints(points, kind: .cycling, amongKinds: kinds)
        // Eastbound: cycle (left lane) → north; walk (right lane) → south.
        XCTAssertGreaterThan(cycle[1].latitude, mid.latitude)
        XCTAssertLessThan(walk[1].latitude, mid.latitude)
    }

    func testZeroOffsetIsIdentity() {
        let points = [
            CLLocationCoordinate2D(latitude: 48.85, longitude: 2.29),
            CLLocationCoordinate2D(latitude: 48.86, longitude: 2.30),
            CLLocationCoordinate2D(latitude: 48.87, longitude: 2.31),
        ]
        let same = PathOffset.offset(points, meters: 0)
        XCTAssertEqual(same.count, points.count)
        for (lhs, rhs) in zip(same, points) {
            XCTAssertEqual(lhs.latitude, rhs.latitude, accuracy: 1e-12)
            XCTAssertEqual(lhs.longitude, rhs.longitude, accuracy: 1e-12)
        }
    }
}

final class TravelKindTests: XCTestCase {
    func testGoogleTypes() {
        XCTAssertEqual(TravelKind(googleType: "WALKING"), .walking)
        XCTAssertEqual(TravelKind(googleType: "CYCLING"), .cycling)
        XCTAssertEqual(TravelKind(googleType: "IN_PASSENGER_VEHICLE"), .automobile)
        XCTAssertEqual(TravelKind(googleType: "FLYING"), .raw)
        XCTAssertNil(TravelKind.raw.directionsType)
        XCTAssertEqual(TravelKind.automobile.directionsType, .automobile)
    }
}
