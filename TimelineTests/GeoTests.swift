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
