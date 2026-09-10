import Foundation
import CoreLocation
import MapKit
import CryptoKit

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

    static func segmentID(_ parts: String...) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return Data(hasher.finalize()).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func millis(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
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

    func appearing(on dayStart: Date, calendar: Calendar, semanticType: String?) -> TimelineVisit {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return TimelineVisit(
            id: id,
            start: max(start, dayStart),
            end: min(end, dayEnd),
            coordinate: coordinate,
            semanticType: semanticType ?? self.semanticType,
            placeKey: placeKey
        )
    }
}

/// Consecutive same-placeKey visits in chronological order (legend rows + map pins).
struct PlaceVisitRun: Identifiable {
    var visits: [TimelineVisit]

    var id: String { visits.first?.id ?? UUID().uuidString }
    var placeKey: String { visits[0].placeKey }
    var representative: TimelineVisit { visits[0] }

    /// Union of stay intervals so duplicate/overlapping segments aren’t double-counted.
    var totalDuration: TimeInterval {
        let ordered = visits.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var total: TimeInterval = 0
        var coveredThrough: Date?
        for visit in ordered {
            if let covered = coveredThrough, visit.start < covered {
                if visit.end > covered {
                    total += visit.end.timeIntervalSince(covered)
                    coveredThrough = visit.end
                }
            } else {
                total += max(visit.duration, 0)
                coveredThrough = visit.end
            }
        }
        return total
    }

    static func coalesced(from visits: [TimelineVisit]) -> [PlaceVisitRun] {
        let ordered = visits.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.placeKey < $1.placeKey
        }
        var runs: [PlaceVisitRun] = []
        for visit in ordered {
            if var last = runs.last, last.placeKey == visit.placeKey {
                last.visits.append(visit)
                runs[runs.count - 1] = last
            } else {
                runs.append(PlaceVisitRun(visits: [visit]))
            }
        }
        return runs
    }
}

struct TimelineActivity: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let distance: Double
    let startCoordinate: CLLocationCoordinate2D?
    let endCoordinate: CLLocationCoordinate2D?
    let kind: TravelKind
}

enum TravelKind {
    case automobile
    case walking
    case cycling
    case raw

    init(googleType: String?) {
        let type = googleType?.lowercased() ?? ""
        if type.contains("walk") || type.contains("run") || type.contains("hik") || type.contains("foot") {
            self = .walking
        } else if type.contains("cycl") || type.contains("bik") {
            self = .cycling
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
        case .cycling: return .cycling
        case .raw: return nil
        }
    }

    var stored: String {
        switch self {
        case .automobile: return "automobile"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .raw: return "raw"
        }
    }

    init(stored: String) {
        switch stored {
        case "walking": self = .walking
        case "cycling": self = .cycling
        case "raw": self = .raw
        default: self = .automobile
        }
    }
}

struct TimelinePath: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let points: [CLLocationCoordinate2D]
    let kind: TravelKind
}

struct ActivityLine: Identifiable {
    let id: String
    let at: Date
    let until: Date
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let kind: TravelKind
}

struct RoutedHop: Identifiable {
    let id: String
    let points: [CLLocationCoordinate2D]
    let kind: TravelKind
    let at: Date
    let until: Date
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

struct TimelineBatch {
    var visits: [TimelineVisit]
    var activities: [TimelineActivity]
    var paths: [TimelinePath]
}

struct ParsedTimeline {
    let sourceName: String
    let days: [DayRecord]
    let places: [PlaceRecord]
}

