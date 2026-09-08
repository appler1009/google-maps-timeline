import XCTest
import CoreLocation
@testable import Timeline

final class TimelineParserTests: XCTestCase {
    func testParsesReferenceEiffelTowerVisit() throws {
        let parsed = try TimelineParser.parse(data: Self.fixtureJSON, sourceName: "eiffel-tower-day.json")
        XCTAssertEqual(parsed.days.count, 1)
        let day = try XCTUnwrap(parsed.days.first)
        XCTAssertEqual(day.visits.count, 2)

        let home = try XCTUnwrap(day.visits.first)
        XCTAssertEqual(home.semanticType, "Home")
        let coordinate = try XCTUnwrap(home.coordinate)
        XCTAssertEqual(coordinate.latitude, Landmark.eiffelTower.latitude, accuracy: 0.000001)
        XCTAssertEqual(coordinate.longitude, Landmark.eiffelTower.longitude, accuracy: 0.000001)

        let work = try XCTUnwrap(day.visits.last)
        XCTAssertEqual(work.semanticType, "Work")
        let workCoordinate = try XCTUnwrap(work.coordinate)
        XCTAssertEqual(workCoordinate.latitude, Landmark.louvrePyramid.latitude, accuracy: 0.000001)
        XCTAssertEqual(workCoordinate.longitude, Landmark.louvrePyramid.longitude, accuracy: 0.000001)
    }

    func testPlacesKeepReferenceCoordinates() throws {
        let parsed = try TimelineParser.parse(data: Self.fixtureJSON, sourceName: "fixture")
        let home = try XCTUnwrap(parsed.places.first { $0.semanticType == "Home" })
        let coordinate = try XCTUnwrap(home.coordinate)
        XCTAssertEqual(coordinate.latitude, Landmark.eiffelTower.latitude, accuracy: 0.000001)
        XCTAssertEqual(coordinate.longitude, Landmark.eiffelTower.longitude, accuracy: 0.000001)
    }

    func testRejectsUnrecognizedJSON() {
        XCTAssertThrowsError(try TimelineParser.parse(data: Data("{\"foo\":1}".utf8), sourceName: "x")) { error in
            guard case TimelineParseError.unrecognized = error else {
                return XCTFail("expected unrecognized, got \(error)")
            }
        }
    }

    func testLegacyE7Coordinates() throws {
        let json = """
        {"timelineObjects":[{"placeVisit":{
          "location":{"latitudeE7":488583700,"longitudeE7":22944810,"placeId":"eiffel","name":"Home"},
          "duration":{"startTimestamp":"2024-06-15T10:00:00Z","endTimestamp":"2024-06-15T12:00:00Z"}
        }}]}
        """
        let parsed = try TimelineParser.parse(data: Data(json.utf8), sourceName: "legacy")
        let coordinate = try XCTUnwrap(parsed.days.first?.visits.first?.coordinate)
        XCTAssertEqual(coordinate.latitude, Landmark.eiffelTower.latitude, accuracy: 0.0001)
        XCTAssertEqual(coordinate.longitude, Landmark.eiffelTower.longitude, accuracy: 0.0001)
    }

    func testBundledFixtureMatchesLandmarks() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "eiffel-tower-day", withExtension: "json"))
        let parsed = try TimelineParser.parse(data: Data(contentsOf: url), sourceName: url.lastPathComponent)
        let coordinate = try XCTUnwrap(parsed.days.first?.visits.first?.coordinate)
        XCTAssertEqual(coordinate.latitude, Landmark.eiffelTower.latitude, accuracy: 0.000001)
        XCTAssertEqual(coordinate.longitude, Landmark.eiffelTower.longitude, accuracy: 0.000001)
    }

    private static let fixtureJSON = Data(
        """
        {"semanticSegments":[
          {"startTime":"2024-06-15T10:00:00.000+02:00","endTime":"2024-06-15T12:00:00.000+02:00",
           "visit":{"topCandidate":{"placeID":"eiffel-tower","semanticType":"Home",
             "placeLocation":"\(Landmark.eiffelTowerGeoURI)"}}},
          {"startTime":"2024-06-15T12:00:00.000+02:00","endTime":"2024-06-15T12:20:00.000+02:00",
           "activity":{"start":"\(Landmark.eiffelTowerGeoURI)","end":"\(Landmark.louvrePyramidGeoURI)",
             "distanceMeters":3200,"topCandidate":{"type":"IN_PASSENGER_VEHICLE"}}},
          {"startTime":"2024-06-15T12:20:00.000+02:00","endTime":"2024-06-15T14:00:00.000+02:00",
           "visit":{"topCandidate":{"placeID":"louvre-pyramid","semanticType":"Work",
             "placeLocation":"\(Landmark.louvrePyramidGeoURI)"}}}
        ]}
        """.utf8
    )
}
