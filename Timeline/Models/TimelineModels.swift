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
        let utf8 = Array(geoURI.utf8)
        var i = 0
        if utf8.count > 4, utf8[0] == 103, utf8[1] == 101, utf8[2] == 111, utf8[3] == 58 { // geo:
            i = 4
        }
        func readDouble() -> Double? {
            let start = i
            if i < utf8.count, utf8[i] == 45 || utf8[i] == 43 { i += 1 }
            var sawDigit = false
            while i < utf8.count {
                let c = utf8[i]
                if c >= 48, c <= 57 { sawDigit = true; i += 1; continue }
                if c == 46 { i += 1; continue }
                break
            }
            guard sawDigit, start < i else { return nil }
            return Double(String(decoding: utf8[start..<i], as: UTF8.self))
        }
        guard let lat = readDouble() else { return nil }
        if i < utf8.count, utf8[i] == 44 { i += 1 }
        guard let lon = readDouble() else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return coordinate
    }

    static func placeKey(id: String?, coordinate: CLLocationCoordinate2D?) -> String {
        if let id, !id.isEmpty { return id }
        guard let coordinate else { return UUID().uuidString }
        return String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }
}

struct TimelineVisit: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let coordinate: CLLocationCoordinate2D?
    let semanticType: String?
    let placeKey: String

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum TravelKind {
    case automobile
    case walking
    case raw

    init(googleType: String?) {
        let type = googleType?.lowercased() ?? ""
        if type.contains("walk") || type.contains("run") || type.contains("hik") || type.contains("cycl") || type.contains("bik") {
            self = .walking
        } else if type.contains("fly") || type.contains("air") || type.contains("train") || type.contains("subway")
                    || type.contains("tram") || type.contains("metro") || type.contains("ferry") || type.contains("boat") {
            self = .raw
        } else {
            self = .automobile
        }
    }

    var directionsType: MKDirectionsTransportType? {
        switch self {
        case .automobile: return .automobile
        case .walking: return .walking
        case .raw: return nil
        }
    }
}

struct TimelinePath: Identifiable {
    let id: String
    let start: Date
    let points: [CLLocationCoordinate2D]
    let kind: TravelKind
}

struct ActivityLine: Identifiable {
    let id: String
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let kind: TravelKind
}

struct DayRecord: Identifiable {
    var id: Date { day }
    let day: Date
    let visits: [TimelineVisit]
    let paths: [TimelinePath]
    let activityLines: [ActivityLine]
    let travelMeters: Double
    let region: MKCoordinateRegion
    var visitCount: Int { visits.count }
}

struct PlaceRecord: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D?
    let semanticType: String?
    let visitCount: Int
    let firstVisit: Date?
    let lastVisit: Date?
    let recentVisits: [TimelineVisit]
}

struct ParsedTimeline {
    let sourceName: String
    let days: [DayRecord]
    let places: [PlaceRecord]
}

