import XCTest
import CoreLocation
import MapKit
@testable import Timeline

final class RouteSnapperTests: XCTestCase {
    func testUsesMockedAppleMapsRouteNotTheStraightLine() async throws {
        let database = TimelineDatabase(fileURL: temporaryDatabase())
        var requested = 0
        let client = ScriptedMapDirectionsClient { start, end, transport in
            requested += 1
            XCTAssertEqual(transport, .automobile)
            return [
                start,
                CLLocationCoordinate2D(latitude: 48.863000, longitude: 2.300000),
                end
            ]
        }
        let snapper = RouteSnapper(database: database, directions: client)
        let points = await snapper.snap(
            id: "paris-hop",
            points: [Landmark.eiffelTower, Landmark.louvrePyramid],
            kind: .automobile
        )
        XCTAssertEqual(requested, 1)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[1].latitude, 48.863000, accuracy: 0.000001)
        XCTAssertEqual(points[1].longitude, 2.300000, accuracy: 0.000001)
    }

    func testDoesNotCallDirectionsForVeryShortHops() async throws {
        let database = TimelineDatabase(fileURL: temporaryDatabase())
        var requested = 0
        let client = ScriptedMapDirectionsClient { start, end, _ in
            requested += 1
            return [start, end]
        }
        let snapper = RouteSnapper(database: database, directions: client)
        let nearby = CLLocationCoordinate2D(
            latitude: Landmark.eiffelTower.latitude,
            longitude: Landmark.eiffelTower.longitude + 0.00005
        )
        let points = await snapper.snap(id: "short", points: [Landmark.eiffelTower, nearby], kind: .automobile)
        XCTAssertEqual(requested, 0)
        XCTAssertEqual(points.count, 2)
    }

    func testCachesMockedRouteOnDisk() async throws {
        let url = temporaryDatabase()
        let database = TimelineDatabase(fileURL: url)
        var requested = 0
        let client = ScriptedMapDirectionsClient { start, end, _ in
            requested += 1
            return ScriptedMapDirectionsClient.dogleg().hops(start, end, .automobile)
        }
        let first = RouteSnapper(database: database, directions: client)
        _ = await first.snap(id: "cached", points: [Landmark.eiffelTower, Landmark.louvrePyramid], kind: .automobile)

        let second = RouteSnapper(database: TimelineDatabase(fileURL: url), directions: client)
        let cached = await second.cached(
            id: "cached",
            kind: .automobile,
            points: [Landmark.eiffelTower, Landmark.louvrePyramid]
        )
        XCTAssertEqual(requested, 1)
        XCTAssertEqual(cached?.count, 3)
    }

    func testRawTravelDoesNotCallDirections() async throws {
        var requested = 0
        let client = ScriptedMapDirectionsClient { start, end, _ in
            requested += 1
            return [start, end]
        }
        let snapper = RouteSnapper(database: TimelineDatabase(fileURL: temporaryDatabase()), directions: client)
        let points = await snapper.snap(
            id: "flight",
            points: [Landmark.eiffelTower, Landmark.louvrePyramid],
            kind: .raw
        )
        XCTAssertEqual(requested, 0)
        XCTAssertEqual(points.count, 2)
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).sqlite")
    }
}

final class CoordBlobTests: XCTestCase {
    func testRoundTrip() {
        let packed = CoordBlob.pack([Landmark.eiffelTower, Landmark.louvrePyramid])
        let unpacked = CoordBlob.unpack(packed)
        XCTAssertEqual(unpacked?.count, 2)
        XCTAssertEqual(unpacked![0].latitude, Landmark.eiffelTower.latitude, accuracy: 0.0000001)
        XCTAssertEqual(unpacked![1].longitude, Landmark.louvrePyramid.longitude, accuracy: 0.0000001)
    }
}
