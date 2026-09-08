import Foundation
import CoreLocation
import MapKit

actor RouteSnapper {
    private var hopCache: [String: [CLLocationCoordinate2D]] = [:]
    private let database: TimelineDatabase
    private let directions: MapDirectionsClient

    init(database: TimelineDatabase, directions: MapDirectionsClient = AppleMapDirectionsClient()) {
        self.database = database
        self.directions = directions
    }

    func cached(id: String, kind: TravelKind, points: [CLLocationCoordinate2D] = []) async -> [CLLocationCoordinate2D]? {
        let routeID = "\(id)|nt|\(kind.stored)"
        if let saved = try? await database.pathRoute(id: routeID), saved.count >= 2 {
            return saved
        }
        guard points.count >= 2 else { return nil }
        guard let transport = kind.directionsType else {
            return points
        }
        let waypoints = Self.sample(points, maxCount: 8, minMeters: 120)
        guard waypoints.count >= 2 else { return nil }
        var route: [CLLocationCoordinate2D] = []
        for index in 0..<(waypoints.count - 1) {
            let start = waypoints[index]
            let end = waypoints[index + 1]
            let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            let hop: [CLLocationCoordinate2D]
            if meters < 50 || meters > 180_000 {
                hop = [start, end]
            } else {
                let key = Self.cacheKey(from: start, to: end, transport: transport)
                if let memory = hopCache[key], memory.count >= 2 {
                    hop = memory
                } else if let disk = try? await database.hop(key: key), disk.count >= 2 {
                    hopCache[key] = disk
                    hop = disk
                } else {
                    return nil
                }
            }
            if route.isEmpty {
                route.append(contentsOf: hop)
            } else {
                route.append(contentsOf: hop.dropFirst())
            }
        }
        guard route.count >= 2 else { return nil }
        try? await database.savePathRoute(id: routeID, points: route)
        return route
    }

    func snap(id: String, points: [CLLocationCoordinate2D], kind: TravelKind, fresh: Bool = false) async -> [CLLocationCoordinate2D] {
        guard points.count >= 2 else { return points }
        let routeID = "\(id)|nt|\(kind.stored)"
        if !fresh, let saved = try? await database.pathRoute(id: routeID), saved.count >= 2 {
            return saved
        }
        guard let transport = kind.directionsType else {
            try? await database.savePathRoute(id: routeID, points: points)
            return points
        }
        let waypoints = Self.sample(points, maxCount: 8, minMeters: 120)
        guard waypoints.count >= 2 else { return points }

        var route: [CLLocationCoordinate2D] = []
        for index in 0..<(waypoints.count - 1) {
            if Task.isCancelled { return points }
            let hop = await direction(from: waypoints[index], to: waypoints[index + 1], transport: transport, fresh: fresh)
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
        let result = route.count >= 2 ? route : points
        try? await database.savePathRoute(id: routeID, points: result)
        return result
    }

    private func direction(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transport: MKDirectionsTransportType,
        fresh: Bool
    ) async -> [CLLocationCoordinate2D] {
        let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        if meters < 50 { return [start, end] }
        if meters > 180_000 { return [start, end] }

        let key = Self.cacheKey(from: start, to: end, transport: transport)
        if !fresh, let cached = hopCache[key] { return cached }
        if !fresh, let disk = try? await database.hop(key: key), disk.count >= 2 {
            hopCache[key] = disk
            return disk
        }

        do {
            let valid = try await directions.route(from: start, to: end, transport: transport)
            if valid.count >= 2 {
                if hopCache.count > 1500 { hopCache.removeAll(keepingCapacity: true) }
                hopCache[key] = valid
                try? await database.saveHop(key: key, points: valid)
                return valid
            }
        } catch {
            return [start, end]
        }
        return [start, end]
    }

    static func cacheKey(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, transport: MKDirectionsTransportType) -> String {
        String(
            format: "%.4f,%.4f-%.4f,%.4f-%u-nt",
            start.latitude, start.longitude, end.latitude, end.longitude, transport.rawValue
        )
    }

    static func sample(_ points: [CLLocationCoordinate2D], maxCount: Int, minMeters: Double) -> [CLLocationCoordinate2D] {
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
