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
        let snapped = await snapper.snap(
            id: "paris-hop",
            points: [Landmark.eiffelTower, Landmark.louvrePyramid],
            kind: .automobile
        )
        XCTAssertEqual(requested, 1)
        XCTAssertFalse(snapped.throttled)
        XCTAssertEqual(snapped.points.count, 3)
        XCTAssertEqual(snapped.points[1].latitude, 48.863000, accuracy: 0.000001)
        XCTAssertEqual(snapped.points[1].longitude, 2.300000, accuracy: 0.000001)
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
        XCTAssertFalse(points.throttled)
        XCTAssertEqual(points.points.count, 2)
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

    func testFreshRerouteKeepsRicherRouteWhenDirectionsAreThrottled() async throws {
        let database = TimelineDatabase(fileURL: temporaryDatabase())
        let rich = ScriptedMapDirectionsClient { start, end, _ in
            [
                start,
                CLLocationCoordinate2D(latitude: 48.861000, longitude: 2.301000),
                CLLocationCoordinate2D(latitude: 48.862000, longitude: 2.304000),
                CLLocationCoordinate2D(latitude: 48.863000, longitude: 2.307000),
                end
            ]
        }
        let snapper = RouteSnapper(database: database, directions: rich)
        let first = await snapper.snap(
            id: "reroute",
            points: [Landmark.eiffelTower, Landmark.louvrePyramid],
            kind: .automobile
        )
        XCTAssertEqual(first.points.count, 5)
        XCTAssertFalse(first.throttled)

        let throttled = ThrottledMapDirectionsClient()
        let again = RouteSnapper(database: database, directions: throttled)
        let second = await again.snap(
            id: "reroute",
            points: [Landmark.eiffelTower, Landmark.louvrePyramid],
            kind: .automobile,
            fresh: true
        )
        XCTAssertTrue(second.throttled)
        XCTAssertEqual(second.points.count, 5)
        XCTAssertEqual(second.points[2].latitude, 48.862000, accuracy: 0.000001)
    }

    func testFreshRerouteReplacesRouteWhenDirectionsReturnMorePoints() async throws {
        let database = TimelineDatabase(fileURL: temporaryDatabase())
        let sparse = ScriptedMapDirectionsClient { start, end, _ in
            ScriptedMapDirectionsClient.dogleg().hops(start, end, .automobile)
        }
        let firstSnapper = RouteSnapper(database: database, directions: sparse)
        let first = await firstSnapper.snap(
            id: "upgrade",
            points: [Landmark.eiffelTower, Landmark.louvrePyramid],
            kind: .automobile
        )
        XCTAssertEqual(first.points.count, 3)
        XCTAssertFalse(first.throttled)

        let dense = ScriptedMapDirectionsClient { start, end, _ in
            [
                start,
                CLLocationCoordinate2D(latitude: 48.860500, longitude: 2.298000),
                CLLocationCoordinate2D(latitude: 48.861500, longitude: 2.301000),
                CLLocationCoordinate2D(latitude: 48.862500, longitude: 2.305000),
                end
            ]
        }
        let secondSnapper = RouteSnapper(database: database, directions: dense)
        let second = await secondSnapper.snap(
            id: "upgrade",
            points: [Landmark.eiffelTower, Landmark.louvrePyramid],
            kind: .automobile,
            fresh: true
        )
        XCTAssertEqual(second.points.count, 5)
        XCTAssertFalse(second.throttled)
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
        XCTAssertFalse(points.throttled)
        XCTAssertEqual(points.points.count, 2)
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).sqlite")
    }
    // MARK: - Routes follow a corrected place

    /// Correcting a place must re-route everything that touched it.
    ///
    /// A hop is identified by the two stays it joins, and a stay keeps its id
    /// when its place moves — so the id alone cannot say whether the line is
    /// still right. Lord Byng sat 2.4 km from the real school; when it was put
    /// back, the drive to it kept its cached geometry and still ran to the old
    /// spot. The cached route is now tied to the points it was drawn between,
    /// which makes the guarantee structural: nothing at the correction site has
    /// to remember to clear anything.
    func testMovingAPlaceInvalidatesTheRouteThatRanToIt() async throws {
        let database = TimelineDatabase(fileURL: temporaryDatabase())
        var requested = 0
        let client = ScriptedMapDirectionsClient { start, end, _ in
            requested += 1
            return [start, CLLocationCoordinate2D(latitude: 48.863, longitude: 2.30), end]
        }
        let snapper = RouteSnapper(database: database, directions: client)
        let hopID = "hop:home:school"

        _ = await snapper.snap(
            id: hopID,
            points: [Landmark.eiffelTower, Landmark.louvrePyramid],
            kind: .automobile
        )
        XCTAssertEqual(requested, 1)

        // Same hop, same stays, unchanged destination: the cache answers.
        let unchanged = await snapper.cached(
            id: hopID,
            kind: .automobile,
            points: [Landmark.eiffelTower, Landmark.louvrePyramid]
        )
        XCTAssertNotNil(unchanged)
        XCTAssertEqual(requested, 1)

        // The place is corrected. The old line ran somewhere else, so it is gone.
        let moved = CLLocationCoordinate2D(latitude: 48.873, longitude: 2.295)
        let afterMove = await snapper.cached(
            id: hopID,
            kind: .automobile,
            points: [Landmark.eiffelTower, moved]
        )
        XCTAssertNil(afterMove, "a corrected place must not reuse the route to where it used to be")
    }

}

private struct ThrottledMapDirectionsClient: MapDirectionsClient {
    func route(
        from _: CLLocationCoordinate2D,
        to _: CLLocationCoordinate2D,
        transport _: MKDirectionsTransportType
    ) async throws -> [CLLocationCoordinate2D] {
        throw NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue))
    }
}

final class MapDirectionsThrottleTests: XCTestCase {
    func testRecognizesLoadingThrottledCode() {
        let error = NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue))
        XCTAssertTrue(MapDirectionsThrottle.isThrottled(error))
    }

    func testRecognizesThrottlerPayloadOnOtherMKErrors() {
        let error = NSError(
            domain: MKErrorDomain,
            code: 2,
            userInfo: ["MKErrorGEOErrorUserInfo": ["throttler.keyPath": "app:test", "timeUntilReset": 54]]
        )
        XCTAssertTrue(MapDirectionsThrottle.isThrottled(error))
    }

    func testIgnoresUnrelatedErrors() {
        XCTAssertFalse(MapDirectionsThrottle.isThrottled(NSError(domain: NSURLErrorDomain, code: -1009)))
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
