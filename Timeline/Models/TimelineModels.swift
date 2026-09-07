import Foundation
import CoreLocation
import MapKit

enum SidebarTab: String, CaseIterable, Identifiable {
    case dates = "Dates"
    case places = "Places"
    var id: String { rawValue }
}

enum Geo {
    static func coordinate(from geoURI: String?) -> CLLocationCoordinate2D? {
        guard let geoURI else { return nil }
        var body = geoURI
        if let prefix = body.range(of: "geo:", options: .caseInsensitive) {
            body = String(body[prefix.upperBound...])
        }
        if let q = body.firstIndex(of: "?") {
            body = String(body[..<q])
        }
        let parts = body.split(separator: ",")
        guard parts.count >= 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lon))
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func placeKey(id: String?, coordinate: CLLocationCoordinate2D?) -> String {
        if let id, !id.isEmpty { return id }
        guard let coordinate else { return UUID().uuidString }
        return String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }
}

struct TimelineVisit: Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date
    let coordinate: CLLocationCoordinate2D?
    let placeID: String?
    let semanticType: String?
    let probability: Double?
    let placeKey: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TimelineVisit, rhs: TimelineVisit) -> Bool { lhs.id == rhs.id }

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct TimelineActivity: Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date
    let startCoordinate: CLLocationCoordinate2D?
    let endCoordinate: CLLocationCoordinate2D?
    let type: String?
    let distanceMeters: Double?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TimelineActivity, rhs: TimelineActivity) -> Bool { lhs.id == rhs.id }
}

struct TimelinePath: Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date
    let points: [CLLocationCoordinate2D]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TimelinePath, rhs: TimelinePath) -> Bool { lhs.id == rhs.id }
}

struct DayRecord: Identifiable, Hashable {
    var id: Date { day }
    let day: Date
    let visits: [TimelineVisit]
    let activities: [TimelineActivity]
    let paths: [TimelinePath]

    var visitCount: Int { visits.count }
    var travelMeters: Double {
        activities.compactMap(\.distanceMeters).reduce(0, +)
    }

    var allCoordinates: [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        coords.append(contentsOf: visits.compactMap(\.coordinate))
        for path in paths { coords.append(contentsOf: path.points) }
        for activity in activities {
            if let s = activity.startCoordinate { coords.append(s) }
            if let e = activity.endCoordinate { coords.append(e) }
        }
        return coords
    }
}

struct PlaceRecord: Identifiable, Hashable {
    let id: String
    let placeID: String?
    let coordinate: CLLocationCoordinate2D?
    let semanticType: String?
    let visits: [TimelineVisit]

    var visitCount: Int { visits.count }

    var lastVisit: Date? { visits.map(\.end).max() }
    var firstVisit: Date? { visits.map(\.start).min() }

    var totalDuration: TimeInterval {
        visits.reduce(0) { $0 + $1.duration }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: PlaceRecord, rhs: PlaceRecord) -> Bool { lhs.id == rhs.id }
}

struct ParsedTimeline {
    let sourceName: String
    let days: [DayRecord]
    let places: [PlaceRecord]
    let visits: [TimelineVisit]
}

