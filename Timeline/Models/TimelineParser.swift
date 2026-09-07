import Foundation
import CoreLocation

enum TimelineParseError: LocalizedError {
    case unreadable
    case unrecognized

    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file could not be read as JSON."
        case .unrecognized: return "This JSON is not a Google Maps Timeline export."
        }
    }
}

enum TimelineParser {
    static func parse(data: Data, sourceName: String) throws -> ParsedTimeline {
        let object = try JSONSerialization.jsonObject(with: data)
        let segments: [[String: Any]]
        if let array = object as? [[String: Any]] {
            segments = array
        } else if let dict = object as? [String: Any] {
            if let nested = dict["semanticSegments"] as? [[String: Any]] {
                segments = nested
            } else if let nested = dict["timelineObjects"] as? [[String: Any]] {
                return try parseLegacyTimelineObjects(nested, sourceName: sourceName)
            } else {
                throw TimelineParseError.unrecognized
            }
        } else {
            throw TimelineParseError.unrecognized
        }

        return assemble(segments: segments, sourceName: sourceName)
    }

    private static func assemble(segments: [[String: Any]], sourceName: String) -> ParsedTimeline {
        var visits: [TimelineVisit] = []
        var activities: [TimelineActivity] = []
        var paths: [TimelinePath] = []
        visits.reserveCapacity(segments.count / 2)
        activities.reserveCapacity(segments.count / 2)

        for (index, segment) in segments.enumerated() {
            let start = parseDate(segment["startTime"] as? String)
            let end = parseDate(segment["endTime"] as? String)
            guard let start, let end else { continue }

            if let visit = segment["visit"] as? [String: Any] {
                let candidate = visit["topCandidate"] as? [String: Any]
                let coord = Geo.coordinate(from: candidate?["placeLocation"] as? String)
                let placeID = candidate?["placeID"] as? String
                visits.append(
                    TimelineVisit(
                        id: "visit-\(index)-\(start.timeIntervalSince1970)",
                        start: start,
                        end: end,
                        coordinate: coord,
                        placeID: placeID,
                        semanticType: candidate?["semanticType"] as? String,
                        probability: doubleValue(visit["probability"]),
                        placeKey: Geo.placeKey(id: placeID, coordinate: coord)
                    )
                )
            }

            if let activity = segment["activity"] as? [String: Any] {
                let candidate = activity["topCandidate"] as? [String: Any]
                activities.append(
                    TimelineActivity(
                        id: "activity-\(index)-\(start.timeIntervalSince1970)",
                        start: start,
                        end: end,
                        startCoordinate: Geo.coordinate(from: activity["start"] as? String),
                        endCoordinate: Geo.coordinate(from: activity["end"] as? String),
                        type: candidate?["type"] as? String,
                        distanceMeters: doubleValue(activity["distanceMeters"])
                    )
                )
            }

            if let pathPoints = segment["timelinePath"] as? [[String: Any]] {
                let coords = pathPoints.compactMap { Geo.coordinate(from: $0["point"] as? String) }
                if !coords.isEmpty {
                    paths.append(
                        TimelinePath(
                            id: "path-\(index)-\(start.timeIntervalSince1970)",
                            start: start,
                            end: end,
                            points: coords
                        )
                    )
                }
            }
        }

        let calendar = Calendar.current
        var daysMap: [Date: (visits: [TimelineVisit], activities: [TimelineActivity], paths: [TimelinePath])] = [:]

        func dayKey(_ date: Date) -> Date {
            calendar.startOfDay(for: date)
        }

        for visit in visits {
            let key = dayKey(visit.start)
            daysMap[key, default: ([], [], [])].visits.append(visit)
        }
        for activity in activities {
            let key = dayKey(activity.start)
            daysMap[key, default: ([], [], [])].activities.append(activity)
        }
        for path in paths {
            let key = dayKey(path.start)
            daysMap[key, default: ([], [], [])].paths.append(path)
        }

        let days = daysMap.keys.sorted(by: >).map { day in
            let bucket = daysMap[day]!
            return DayRecord(
                day: day,
                visits: bucket.visits.sorted { $0.start < $1.start },
                activities: bucket.activities.sorted { $0.start < $1.start },
                paths: bucket.paths.sorted { $0.start < $1.start }
            )
        }

        var placeMap: [String: [TimelineVisit]] = [:]
        for visit in visits {
            placeMap[visit.placeKey, default: []].append(visit)
        }

        let places = placeMap.map { key, grouped -> PlaceRecord in
            let sorted = grouped.sorted { $0.start > $1.start }
            let named = sorted.first { semanticTitle($0.semanticType) != nil }
            let representative = named ?? sorted[0]
            return PlaceRecord(
                id: key,
                placeID: representative.placeID,
                coordinate: representative.coordinate,
                semanticType: representative.semanticType,
                visits: sorted
            )
        }
        .sorted { lhs, rhs in
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            return (lhs.lastVisit ?? .distantPast) > (rhs.lastVisit ?? .distantPast)
        }

        return ParsedTimeline(sourceName: sourceName, days: days, places: places, visits: visits)
    }

    private static func parseLegacyTimelineObjects(_ objects: [[String: Any]], sourceName: String) throws -> ParsedTimeline {
        var segments: [[String: Any]] = []
        for object in objects {
            if let visit = object["placeVisit"] as? [String: Any] {
                let location = visit["location"] as? [String: Any]
                let duration = visit["duration"] as? [String: Any]
                var top: [String: Any] = [:]
                if let id = location?["placeId"] { top["placeID"] = id }
                if let name = location?["name"] as? String { top["semanticType"] = name }
                if let lat = doubleValue(location?["latitudeE7"]), let lon = doubleValue(location?["longitudeE7"]) {
                    top["placeLocation"] = String(format: "geo:%.7f,%.7f", lat / 1e7, lon / 1e7)
                }
                segments.append([
                    "startTime": duration?["startTimestamp"] as? String ?? duration?["startTimestampMs"] as? String ?? "",
                    "endTime": duration?["endTimestamp"] as? String ?? duration?["endTimestampMs"] as? String ?? "",
                    "visit": ["topCandidate": top, "probability": visit["placeConfidence"] as Any]
                ])
            }
            if let activity = object["activitySegment"] as? [String: Any] {
                let duration = activity["duration"] as? [String: Any]
                let startLoc = activity["startLocation"] as? [String: Any]
                let endLoc = activity["endLocation"] as? [String: Any]
                func geo(_ loc: [String: Any]?) -> String? {
                    guard let lat = doubleValue(loc?["latitudeE7"]), let lon = doubleValue(loc?["longitudeE7"]) else { return nil }
                    return String(format: "geo:%.7f,%.7f", lat / 1e7, lon / 1e7)
                }
                var pathPoints: [[String: Any]] = []
                if let waypoints = activity["waypointPath"] as? [String: Any],
                   let points = waypoints["waypoints"] as? [[String: Any]] {
                    pathPoints = points.compactMap { point in
                        guard let lat = doubleValue(point["latE7"]), let lon = doubleValue(point["lngE7"]) else { return nil }
                        return ["point": String(format: "geo:%.7f,%.7f", lat / 1e7, lon / 1e7)]
                    }
                }
                var segment: [String: Any] = [
                    "startTime": duration?["startTimestamp"] as? String ?? "",
                    "endTime": duration?["endTimestamp"] as? String ?? "",
                    "activity": [
                        "start": geo(startLoc) as Any,
                        "end": geo(endLoc) as Any,
                        "distanceMeters": activity["distance"] as Any,
                        "topCandidate": ["type": (activity["activityType"] as? String) as Any]
                    ]
                ]
                if !pathPoints.isEmpty { segment["timelinePath"] = pathPoints }
                segments.append(segment)
            }
        }
        if segments.isEmpty { throw TimelineParseError.unrecognized }
        return assemble(segments: segments, sourceName: sourceName)
    }

    static func semanticTitle(_ type: String?) -> String? {
        guard let type else { return nil }
        switch type {
        case "Unknown", "unknown", "": return nil
        case "Searched Address": return "Searched address"
        default: return type
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string, string.count >= 19 else {
            if let string, let ms = Double(string) { return Date(timeIntervalSince1970: ms / 1000) }
            return nil
        }
        if let date = parseCivilISO8601(string) { return date }
        if let ms = Double(string) { return Date(timeIntervalSince1970: ms / 1000) }
        return nil
    }

    /// Parses `2024-11-19T11:50:02.112-08:00` / `...Z` without ISO8601DateFormatter.
    private static func parseCivilISO8601(_ string: String) -> Date? {
        let utf8 = string.utf8
        let count = utf8.count
        guard count >= 19 else { return nil }
        func int(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            var i = utf8.index(utf8.startIndex, offsetBy: start)
            for _ in 0..<length {
                guard i < utf8.endIndex else { return nil }
                let c = utf8[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
                i = utf8.index(after: i)
            }
            return value
        }
        guard let year = int(0, 4), let month = int(5, 2), let day = int(8, 2),
              let hour = int(11, 2), let minute = int(14, 2), let second = int(17, 2)
        else { return nil }

        var offset = 19
        var nanosecond = 0
        if offset < count {
            let fracIndex = utf8.index(utf8.startIndex, offsetBy: offset)
            if utf8[fracIndex] == 46 { // '.'
                offset += 1
                var frac = 0
                var digits = 0
                while offset < count {
                    let c = utf8[utf8.index(utf8.startIndex, offsetBy: offset)]
                    guard c >= 48, c <= 57 else { break }
                    if digits < 9 {
                        frac = frac * 10 + Int(c - 48)
                        digits += 1
                    }
                    offset += 1
                }
                while digits < 9 {
                    frac *= 10
                    digits += 1
                }
                nanosecond = frac
            }
        }

        var secondsFromGMT = 0
        if offset < count {
            let tzIndex = utf8.index(utf8.startIndex, offsetBy: offset)
            let tz = utf8[tzIndex]
            if tz == 90 { // Z
                secondsFromGMT = 0
            } else if tz == 43 || tz == 45 { // + or -
                guard let tzHour = int(offset + 1, 2), let tzMinute = int(offset + 4, 2) else { return nil }
                let sign = tz == 43 ? 1 : -1
                secondsFromGMT = sign * (tzHour * 3600 + tzMinute * 60)
            }
        }

        var components = DateComponents()
        components.calendar = gregorian
        components.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        return components.date
    }

    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
