import Foundation
import CoreLocation
import MapKit

actor RouteSnapper {
    private var hopCache: [String: [CLLocationCoordinate2D]] = [:]

    func snap(points: [CLLocationCoordinate2D], kind: TravelKind) async -> [CLLocationCoordinate2D] {
        guard points.count >= 2 else { return points }
        guard let transport = kind.directionsType else { return points }
        let waypoints = Self.sample(points, maxCount: 8, minMeters: 120)
        guard waypoints.count >= 2 else { return points }

        var route: [CLLocationCoordinate2D] = []
        for index in 0..<(waypoints.count - 1) {
            if Task.isCancelled { return points }
            let hop = await direction(from: waypoints[index], to: waypoints[index + 1], transport: transport)
            if hop.count >= 2 {
                if route.isEmpty {
                    route.append(contentsOf: hop)
                } else {
                    route.append(contentsOf: hop.dropFirst())
                }
            } else {
                if route.isEmpty { route.append(waypoints[index]) }
                route.append(waypoints[index + 1])
            }
        }
        return route.count >= 2 ? route : points
    }

    private func direction(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transport: MKDirectionsTransportType
    ) async -> [CLLocationCoordinate2D] {
        let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        if meters < 50 { return [start, end] }
        if meters > 180_000 { return [start, end] }

        let key = Self.cacheKey(from: start, to: end, transport: transport)
        if let cached = hopCache[key] { return cached }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = transport
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let polyline = response.routes.first?.polyline else { return [start, end] }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
            let valid = coords.filter { CLLocationCoordinate2DIsValid($0) }
            if valid.count >= 2 {
                if hopCache.count > 1500 { hopCache.removeAll(keepingCapacity: true) }
                hopCache[key] = valid
                return valid
            }
        } catch {
            return [start, end]
        }
        return [start, end]
    }

    private static func cacheKey(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, transport: MKDirectionsTransportType) -> String {
        String(
            format: "%.4f,%.4f-%.4f,%.4f-%u",
            start.latitude, start.longitude, end.latitude, end.longitude, transport.rawValue
        )
    }

    private static func sample(_ points: [CLLocationCoordinate2D], maxCount: Int, minMeters: Double) -> [CLLocationCoordinate2D] {
        guard points.count > maxCount else { return points }
        var sampled: [CLLocationCoordinate2D] = [points[0]]
        var last = points[0]
        let remainingSlots = maxCount - 1
        for point in points.dropFirst().dropLast() {
            let distance = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            if distance >= minMeters {
                sampled.append(point)
                last = point
                if sampled.count == remainingSlots { break }
            }
        }
        sampled.append(points[points.count - 1])
        return sampled
    }
}
