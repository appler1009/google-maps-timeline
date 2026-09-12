import Foundation
import CoreLocation
import MapKit

struct RouteSnapOutcome: Sendable {
    var points: [CLLocationCoordinate2D]
    var throttled: Bool
}

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
        let anchor = Self.anchor(for: points)
        if let saved = try? await database.pathRoute(id: routeID, anchor: anchor), saved.count >= 2 {
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
        try? await database.savePathRoute(id: routeID, anchor: anchor, points: route)
        return route
    }

    func snap(id: String, points: [CLLocationCoordinate2D], kind: TravelKind, fresh: Bool = false) async -> RouteSnapOutcome {
        guard points.count >= 2 else { return RouteSnapOutcome(points: points, throttled: false) }
        let routeID = "\(id)|nt|\(kind.stored)"
        let anchor = Self.anchor(for: points)
        let previous = try? await database.pathRoute(id: routeID, anchor: anchor)
        if !fresh, let previous, previous.count >= 2 {
            return RouteSnapOutcome(points: previous, throttled: false)
        }
        guard let transport = kind.directionsType else {
            return RouteSnapOutcome(
                points: await keepRicher(id: routeID, anchor: anchor, previous: previous, candidate: points),
                throttled: false
            )
        }
        let waypoints = Self.sample(points, maxCount: 8, minMeters: 120)
        guard waypoints.count >= 2 else {
            return RouteSnapOutcome(
                points: await keepRicher(id: routeID, anchor: anchor, previous: previous, candidate: points),
                throttled: false
            )
        }

        var route: [CLLocationCoordinate2D] = []
        var throttled = false
        for index in 0..<(waypoints.count - 1) {
            if Task.isCancelled {
                if let previous, previous.count >= 2 {
                    return RouteSnapOutcome(points: previous, throttled: throttled)
                }
                return RouteSnapOutcome(points: points, throttled: throttled)
            }
            let hop = await direction(from: waypoints[index], to: waypoints[index + 1], transport: transport, fresh: fresh)
            throttled = throttled || hop.throttled
            if hop.points.count >= 2 {
                if route.isEmpty {
                    route.append(contentsOf: hop.points)
                } else {
                    route.append(contentsOf: hop.points.dropFirst())
                }
            } else {
                if route.isEmpty { route.append(waypoints[index]) }
                route.append(waypoints[index + 1])
            }
        }
        let result = route.count >= 2 ? route : points
        return RouteSnapOutcome(
            points: await keepRicher(id: routeID, anchor: anchor, previous: previous, candidate: result),
            throttled: throttled
        )
    }

    private func direction(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transport: MKDirectionsTransportType,
        fresh: Bool
    ) async -> RouteSnapOutcome {
        let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        if meters < 50 { return RouteSnapOutcome(points: [start, end], throttled: false) }
        if meters > 180_000 { return RouteSnapOutcome(points: [start, end], throttled: false) }

        let key = Self.cacheKey(from: start, to: end, transport: transport)
        let previous = await cachedHop(key: key)
        if !fresh, let previous { return RouteSnapOutcome(points: previous, throttled: false) }

        do {
            let valid = try await directions.route(from: start, to: end, transport: transport)
            if valid.count >= 2, previous.map({ valid.count > $0.count }) ?? true {
                return RouteSnapOutcome(points: await saveHop(key: key, points: valid), throttled: false)
            }
        } catch {
            return RouteSnapOutcome(
                points: previous ?? [start, end],
                throttled: MapDirectionsThrottle.isThrottled(error)
            )
        }
        return RouteSnapOutcome(points: previous ?? [start, end], throttled: false)
    }

    private func cachedHop(key: String) async -> [CLLocationCoordinate2D]? {
        if let cached = hopCache[key], cached.count >= 2 { return cached }
        if let disk = try? await database.hop(key: key), disk.count >= 2 {
            hopCache[key] = disk
            return disk
        }
        return nil
    }

    private func saveHop(key: String, points: [CLLocationCoordinate2D]) async -> [CLLocationCoordinate2D] {
        if hopCache.count > 1500 { hopCache.removeAll(keepingCapacity: true) }
        hopCache[key] = points
        try? await database.saveHop(key: key, points: points)
        return points
    }

    /// Keep a previously snapped polyline unless the latest call produced more points.
    /// Rate-limited MapKit responses are typically a 2-point straight line; those must not replace a real route.
    private func keepRicher(
        id: String,
        anchor: String,
        previous: [CLLocationCoordinate2D]?,
        candidate: [CLLocationCoordinate2D]
    ) async -> [CLLocationCoordinate2D] {
        if let previous, previous.count >= 2, candidate.count <= previous.count {
            return previous
        }
        try? await database.savePathRoute(id: id, anchor: anchor, points: candidate)
        return candidate
    }

    /// What a route runs between. Rounded, so a metre of jitter is not a miss.
    static func anchor(for points: [CLLocationCoordinate2D]) -> String {
        guard let first = points.first, let last = points.last else { return "-" }
        return String(
            format: "%.4f,%.4f-%.4f,%.4f",
            first.latitude, first.longitude, last.latitude, last.longitude
        )
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
