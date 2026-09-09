import Foundation
import CoreLocation
import MapKit

protocol MapDirectionsClient: Sendable {
    func route(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transport: MKDirectionsTransportType
    ) async throws -> [CLLocationCoordinate2D]
}

enum MapDirectionsThrottle {
    static func isThrottled(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == MKErrorDomain, ns.code == Int(MKError.Code.loadingThrottled.rawValue) {
            return true
        }
        let info = String(describing: ns.userInfo).lowercased()
        return info.contains("throttler") || info.contains("timeuntilreset")
    }
}

struct AppleMapDirectionsClient: MapDirectionsClient {
    /// Off-peak Sunday so Apple does not optimize around live congestion.
    static let staticDeparture: Date = {
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        parts.year = 2024
        parts.month = 1
        parts.day = 7
        parts.hour = 4
        return parts.date ?? Date(timeIntervalSince1970: 1_704_600_000)
    }()

    func route(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transport: MKDirectionsTransportType
    ) async throws -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = transport
        request.requestsAlternateRoutes = false
        request.departureDate = Self.staticDeparture
        request.arrivalDate = nil
        request.highwayPreference = .any
        request.tollPreference = .any

        let response = try await MKDirections(request: request).calculate()
        guard let polyline = response.routes.first?.polyline else {
            return [start, end]
        }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        let valid = coords.filter { CLLocationCoordinate2DIsValid($0) }
        return valid.count >= 2 ? valid : [start, end]
    }
}

/// Deterministic stand-in for Apple Maps. UI tests and unit tests use this so
/// route drawing does not depend on the network or live MapKit directions.
struct ScriptedMapDirectionsClient: MapDirectionsClient {
    var hops: @Sendable (CLLocationCoordinate2D, CLLocationCoordinate2D, MKDirectionsTransportType) -> [CLLocationCoordinate2D]

    static func dogleg() -> ScriptedMapDirectionsClient {
        ScriptedMapDirectionsClient { start, end, _ in
            let mid = CLLocationCoordinate2D(
                latitude: (start.latitude + end.latitude) / 2,
                longitude: start.longitude
            )
            return [start, mid, end]
        }
    }

    /// Same contract as Apple Maps for the bundled Paris day: follow the
    /// quais and Rue de Rivoli instead of a straight cut across the 7th.
    static func alongRoads() -> ScriptedMapDirectionsClient {
        ScriptedMapDirectionsClient { start, end, _ in
            if Self.near(start, Landmark.eiffelTower), Self.near(end, Landmark.louvrePyramid) {
                return Landmark.eiffelToLouvreRoad
            }
            if Self.near(start, Landmark.louvrePyramid), Self.near(end, Landmark.eiffelTower) {
                return Array(Landmark.eiffelToLouvreRoad.reversed())
            }
            return dogleg().hops(start, end, .automobile)
        }
    }

    private static func near(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 0.0002 && abs(a.longitude - b.longitude) < 0.0002
    }

    func route(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transport: MKDirectionsTransportType
    ) async throws -> [CLLocationCoordinate2D] {
        hops(start, end, transport)
    }
}
