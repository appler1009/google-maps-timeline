import Foundation
import CoreLocation
import MapKit

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
        assemble(try extract(data), sourceName: sourceName)
    }

    static func extract(_ data: Data) throws -> TimelineBatch {
        let object = try JSONSerialization.jsonObject(with: data)
        let segments: [[String: Any]]
        if let array = object as? [[String: Any]] {
            segments = array
        } else if let dict = object as? [String: Any] {
            if let nested = dict["semanticSegments"] as? [[String: Any]] {
                segments = nested
            } else if let nested = dict["timelineObjects"] as? [[String: Any]] {
                return collect(segments: try legacySegments(nested))
            } else {
                throw TimelineParseError.unrecognized
            }
        } else {
            throw TimelineParseError.unrecognized
        }
        let batch = collect(segments: segments)
        if batch.visits.isEmpty, batch.activities.isEmpty, batch.paths.isEmpty {
            throw TimelineParseError.unrecognized
        }
        return batch
    }

    static func assemble(_ batch: TimelineBatch, sourceName: String) -> ParsedTimeline {
        let calendar = Calendar.current
        var daysMap: [Date: DayBucket] = [:]

        func dayKey(_ date: Date) -> Date {
            calendar.startOfDay(for: date)
        }

        var typeByPlace: [String: String] = [:]
        for visit in batch.visits {
            guard let type = visit.semanticType, !type.isEmpty, type.lowercased() != "unknown" else { continue }
            let current = typeByPlace[visit.placeKey]
            if current == nil || type == "Home" || type == "Work" {
                typeByPlace[visit.placeKey] = type
            }
        }

        for visit in batch.visits {
            let resolved = typeByPlace[visit.placeKey] ?? visit.semanticType
            var day = dayKey(visit.start)
            let lastDay = dayKey(visit.end)
            let lastInclusive: Date
            if visit.end == lastDay, visit.end > visit.start {
                lastInclusive = calendar.date(byAdding: .day, value: -1, to: lastDay) ?? day
            } else {
                lastInclusive = lastDay
            }
            while day <= lastInclusive {
                var bucket = daysMap[day] ?? DayBucket()
                bucket.visits.append(visit.appearing(on: day, calendar: calendar, semanticType: resolved))
                daysMap[day] = bucket
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        for activity in batch.activities {
            let key = dayKey(activity.start)
            var bucket = daysMap[key] ?? DayBucket()
            bucket.travelMeters += activity.distance
            bucket.kinds.append((activity.start, activity.kind))
            if let startC = activity.startCoordinate, let endC = activity.endCoordinate {
                bucket.lines.append(ActivityLine(id: activity.id, at: activity.start, until: activity.end, start: startC, end: endC, kind: activity.kind))
            }
            daysMap[key] = bucket
        }
        for path in batch.paths {
            let key = dayKey(path.start)
            var bucket = daysMap[key] ?? DayBucket()
            let kind = nearestKind(path.start, in: bucket.kinds)
            bucket.paths.append(TimelinePath(id: path.id, start: path.start, end: path.end, points: path.points, kind: kind))
            daysMap[key] = bucket
        }

        let fallback = CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12)
        let days = daysMap.keys.sorted(by: >).map { day -> DayRecord in
            let bucket = daysMap[day]!
            let visitsSorted = bucket.visits.sorted { $0.start < $1.start }
            let pathsSorted = bucket.paths
            let lines = bucket.lines
            var coords = visitsSorted.compactMap(\.coordinate)
            for path in pathsSorted { coords.append(contentsOf: path.points) }
            if coords.isEmpty {
                for line in lines {
                    coords.append(line.start)
                    coords.append(line.end)
                }
            }
            return DayRecord(
                day: day,
                visits: visitsSorted,
                paths: pathsSorted,
                activityLines: lines,
                travelMeters: bucket.travelMeters,
                region: region(covering: coords, fallback: fallback)
            )
        }

        var placeMap: [String: [TimelineVisit]] = [:]
        placeMap.reserveCapacity(min(batch.visits.count, 4096))
        for visit in batch.visits {
            var grouped = placeMap[visit.placeKey] ?? []
            grouped.append(visit)
            placeMap[visit.placeKey] = grouped
        }

        let places = placeMap.map { key, grouped -> PlaceRecord in
            let sorted = grouped.sorted { $0.start > $1.start }
            let named = sorted.first { semanticTitle($0.semanticType) != nil }
            let representative = named ?? sorted[0]
            return PlaceRecord(
                id: key,
                coordinate: representative.coordinate,
                semanticType: representative.semanticType,
                visitCount: sorted.count,
                firstVisit: sorted.last?.start,
                lastVisit: sorted.first?.end,
                recentVisits: Array(sorted.prefix(20))
            )
        }
        .sorted { lhs, rhs in
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            return (lhs.lastVisit ?? .distantPast) > (rhs.lastVisit ?? .distantPast)
        }

        return ParsedTimeline(sourceName: sourceName, days: days, places: places)
    }

    private static func collect(segments: [[String: Any]]) -> TimelineBatch {
        var visits: [TimelineVisit] = []
        var activities: [TimelineActivity] = []
        var paths: [TimelinePath] = []
        visits.reserveCapacity(segments.count / 2)
        activities.reserveCapacity(segments.count / 2)

        for segment in segments {
            let start = parseDate(segment["startTime"] as? String)
            let end = parseDate(segment["endTime"] as? String)
            guard let start, let end else { continue }

            if let visit = segment["visit"] as? [String: Any] {
                let candidate = visit["topCandidate"] as? [String: Any]
                let coord = Geo.coordinate(from: candidate?["placeLocation"] as? String)
                let placeID = candidate?["placeID"] as? String
                let placeKey = Geo.placeKey(id: placeID, coordinate: coord)
                visits.append(
                    TimelineVisit(
                        id: Geo.segmentID("v", Geo.millis(start), Geo.millis(end), placeKey),
                        start: start,
                        end: end,
                        coordinate: coord,
                        semanticType: candidate?["semanticType"] as? String,
                        placeKey: placeKey
                    )
                )
            }

            if let activity = segment["activity"] as? [String: Any] {
                let type = (activity["topCandidate"] as? [String: Any])?["type"] as? String
                let startC = Geo.coordinate(from: activity["start"] as? String)
                let endC = Geo.coordinate(from: activity["end"] as? String)
                activities.append(
                    TimelineActivity(
                        id: Geo.segmentID(
                            "a",
                            Geo.millis(start),
                            Geo.millis(end),
                            startC.map { String(format: "%.7f,%.7f", $0.latitude, $0.longitude) } ?? "",
                            endC.map { String(format: "%.7f,%.7f", $0.latitude, $0.longitude) } ?? ""
                        ),
                        start: start,
                        end: end,
                        distance: doubleValue(activity["distanceMeters"]) ?? 0,
                        startCoordinate: startC,
                        endCoordinate: endC,
                        kind: TravelKind(googleType: type)
                    )
                )
            }

            if let pathPoints = segment["timelinePath"] as? [[String: Any]] {
                let coords = pathPoints.compactMap { Geo.coordinate(from: $0["point"] as? String) }
                let simplified = PathSimplifier.simplify(coords, epsilonMeters: 12)
                if simplified.count >= 2 {
                    paths.append(
                        TimelinePath(
                            id: Geo.segmentID("p", Geo.millis(start), Geo.millis(end)),
                            start: start,
                            end: end,
                            points: simplified,
                            kind: .automobile
                        )
                    )
                }
            }
        }
        return TimelineBatch(visits: visits, activities: activities, paths: paths)
    }

    private static func legacySegments(_ objects: [[String: Any]]) throws -> [[String: Any]] {
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
        return segments
    }

    static func semanticTitle(_ type: String?) -> String? {
        guard let type else { return nil }
        switch type {
        case "Unknown", "unknown", "": return nil
        case "Searched Address": return "Searched address"
        default: return type
        }
    }

    static func symbolName(_ type: String?) -> String? {
        switch type {
        case "Home": return "house.fill"
        case "Work": return "briefcase.fill"
        default: return nil
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

    /// Parses `2024-11-19T11:50:02.112-08:00` / `...Z` without ISO8601DateFormatter or Calendar.
    private static func parseCivilISO8601(_ string: String) -> Date? {
        let u = Array(string.utf8)
        guard u.count >= 19 else { return nil }
        func int(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            var i = start
            let end = start + length
            guard end <= u.count else { return nil }
            while i < end {
                let c = u[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
                i += 1
            }
            return value
        }
        guard let year = int(0, 4), let month = int(5, 2), let day = int(8, 2),
              let hour = int(11, 2), let minute = int(14, 2), let second = int(17, 2)
        else { return nil }

        var offset = 19
        var nanosecond = 0
        if offset < u.count, u[offset] == 46 {
            offset += 1
            var frac = 0
            var digits = 0
            while offset < u.count, u[offset] >= 48, u[offset] <= 57 {
                if digits < 9 {
                    frac = frac * 10 + Int(u[offset] - 48)
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

        var secondsFromGMT = 0
        if offset < u.count {
            let tz = u[offset]
            if tz == 90 {
                secondsFromGMT = 0
            } else if tz == 43 || tz == 45 {
                guard let tzHour = int(offset + 1, 2), let tzMinute = int(offset + 4, 2) else { return nil }
                secondsFromGMT = (tz == 43 ? 1 : -1) * (tzHour * 3600 + tzMinute * 60)
            }
        }

        let days = daysFromCivil(year, month, day)
        let utc = Double(days * 86_400 + hour * 3_600 + minute * 60 + second - secondsFromGMT)
            + Double(nanosecond) / 1_000_000_000
        return Date(timeIntervalSince1970: utc)
    }

    /// Howard Hinnant civil-from-days; unix epoch is 1970-01-01.
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        var y = year
        let m = month
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func nearestKind(_ date: Date, in kinds: [(Date, TravelKind)]) -> TravelKind {
        guard !kinds.isEmpty else { return .automobile }
        return kinds.min(by: { abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date)) })?.1 ?? .automobile
    }

    private static func region(covering coordinates: [CLLocationCoordinate2D], fallback: CLLocationCoordinate2D) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(center: fallback, span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))
        }
        var minLat = coordinates[0].latitude
        var maxLat = minLat
        var minLon = coordinates[0].longitude
        var maxLon = minLon
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.008),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.008)
            )
        )
    }
}

private struct DayBucket {
    var visits: [TimelineVisit] = []
    var paths: [TimelinePath] = []
    var lines: [ActivityLine] = []
    var travelMeters: Double = 0
    var kinds: [(Date, TravelKind)] = []
}

private enum PathSimplifier {
    static func simplify(_ points: [CLLocationCoordinate2D], epsilonMeters: Double) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }
        let epsilon = epsilonMeters / 111_320
        return douglas(points, epsilon: epsilon)
    }

    private static func douglas(_ points: [CLLocationCoordinate2D], epsilon: Double) -> [CLLocationCoordinate2D] {
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            var maxDist = 0.0
            var index = start
            for i in (start + 1)..<end {
                let dist = perpendicularDistance(points[i], a: points[start], b: points[end])
                if dist > maxDist {
                    maxDist = dist
                    index = i
                }
            }
            if maxDist > epsilon {
                keep[index] = true
                if index - start > 1 { stack.append((start, index)) }
                if end - index > 1 { stack.append((index, end)) }
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func perpendicularDistance(_ p: CLLocationCoordinate2D, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> Double {
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        if dx == 0, dy == 0 {
            let x = p.longitude - a.longitude
            let y = p.latitude - a.latitude
            return (x * x + y * y).squareRoot()
        }
        let t = ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) / (dx * dx + dy * dy)
        let clamped = min(1, max(0, t))
        let x = p.longitude - (a.longitude + clamped * dx)
        let y = p.latitude - (a.latitude + clamped * dy)
        return (x * x + y * y).squareRoot()
    }
}
