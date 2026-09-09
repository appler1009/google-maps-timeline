import MapKit

/// Lateral display offsets so different travel kinds don’t share one centerline.
enum PathOffset {
    /// Separation between adjacent kind lanes on the map.
    static let laneWidthMeters: Double = 8
    /// Softly pull the first/last vertices back toward the true endpoints (visit pins).
    private static let endpointTaperVertices = 2

    /// Lane index relative to the road centerline. Automobile stays centered.
    static func lane(for kind: TravelKind) -> Double {
        switch kind {
        case .automobile, .raw: return 0
        case .cycling: return 1
        case .walking: return -1
        }
    }

    /// Points to draw for `kind` given the other kinds shown that day.
    static func displayPoints(
        _ points: [CLLocationCoordinate2D],
        kind: TravelKind,
        amongKinds: Set<TravelKind>
    ) -> [CLLocationCoordinate2D] {
        let laneKinds: Set<TravelKind> = [.automobile, .cycling, .walking]
        let present = amongKinds.intersection(laneKinds)
        guard present.count > 1, present.contains(kind) else { return points }

        let meters = lane(for: kind) * laneWidthMeters
        guard abs(meters) > 0.01 else { return points }
        return offset(points, meters: meters)
    }

    /// Shift a polyline left/right in map space by `meters` (positive = left of travel).
    static func offset(_ points: [CLLocationCoordinate2D], meters: Double) -> [CLLocationCoordinate2D] {
        guard points.count >= 2, abs(meters) > 0.01 else { return points }

        let mapPoints = points.map { MKMapPoint($0) }
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(points.count)

        for index in mapPoints.indices {
            guard let tangent = tangent(at: index, in: mapPoints) else {
                result.append(points[index])
                continue
            }
            // Geographic left-of-travel. MKMapPoint.y increases south, so the
            // usual CCW screen normal would point the wrong way.
            let normalX = tangent.y
            let normalY = -tangent.x
            let metersPerPoint = MKMetersPerMapPointAtLatitude(points[index].latitude)
            guard metersPerPoint > 0 else {
                result.append(points[index])
                continue
            }
            let scale = taper(at: index, count: mapPoints.count) * meters / metersPerPoint
            let shifted = MKMapPoint(
                x: mapPoints[index].x + normalX * scale,
                y: mapPoints[index].y + normalY * scale
            )
            result.append(shifted.coordinate)
        }
        return result
    }

    private static func taper(at index: Int, count: Int) -> Double {
        if index == 0 || index == count - 1 { return 0 }
        let edge = endpointTaperVertices
        guard count > edge * 2 else { return 1 }
        if index < edge {
            return Double(index) / Double(edge)
        }
        if index >= count - edge {
            return Double(count - 1 - index) / Double(edge)
        }
        return 1
    }

    private static func tangent(at index: Int, in points: [MKMapPoint]) -> (x: Double, y: Double)? {
        if index == 0 {
            return unit(from: points[0], to: points[1])
        }
        if index == points.count - 1 {
            return unit(from: points[index - 1], to: points[index])
        }
        let inbound = unit(from: points[index - 1], to: points[index])
        let outbound = unit(from: points[index], to: points[index + 1])
        switch (inbound, outbound) {
        case let (left?, right?):
            return unit(x: left.x + right.x, y: left.y + right.y) ?? left
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    private static func unit(from a: MKMapPoint, to b: MKMapPoint) -> (x: Double, y: Double)? {
        unit(x: b.x - a.x, y: b.y - a.y)
    }

    private static func unit(x: Double, y: Double) -> (x: Double, y: Double)? {
        let length = hypot(x, y)
        guard length > 1e-9 else { return nil }
        return (x / length, y / length)
    }
}
