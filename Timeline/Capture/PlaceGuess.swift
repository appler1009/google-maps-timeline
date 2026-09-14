import Foundation
import CoreLocation
import MapKit

/// Name guesses for a coordinate. Behind a protocol so the recorder can be
/// exercised without MapKit — the notification path is worth testing, and it is
/// not worth a network round trip to do it.
protocol PlaceGuessing: Sendable {
    func pointsOfInterest(around coordinate: CLLocationCoordinate2D) async -> [PlaceNameSuggestion]
    func address(at coordinate: CLLocationCoordinate2D) async -> PlaceNameSuggestion?
    func guesses(
        around coordinate: CLLocationCoordinate2D,
        visited: [PlaceNameSuggestion],
        limit: Int
    ) async -> [PlaceNameSuggestion]
}

/// Name guesses for a coordinate, with no UI attached.
///
/// `PlaceNameSuggester` drives the rename sheet and is built around typing, so it
/// is `@MainActor` and owns an `MKLocalSearchCompleter`. The recorder needs the
/// same answers on a background wake with nobody typing, so the lookup and the
/// ranking live here and both front ends share them — which is the only way the
/// notification's guesses and the rename sheet's history tab can never disagree.
/// New places sit on a second tab, so a long history cannot hide them.
struct PlaceGuessService: PlaceGuessing {
    var searchRadius: CLLocationDistance = 450

    /// Nearby points of interest, nearest first.
    func pointsOfInterest(around coordinate: CLLocationCoordinate2D) async -> [PlaceNameSuggestion] {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: searchRadius)
        request.pointOfInterestFilter = .includingAll
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { item -> PlaceNameSuggestion? in
                let title = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { return nil }
                let itemCoordinate = item.placemark.coordinate
                let distance = RoutePlanner.meters(coordinate, itemCoordinate)
                let category = item.pointOfInterestCategory?.rawValue
                    .replacingOccurrences(of: "MKPOICategory", with: "")
                let subtitleParts = [category, PlaceGuessRanker.distanceLabel(distance)].compactMap { $0 }
                return PlaceNameSuggestion(
                    id: "poi:\(itemCoordinate.latitude),\(itemCoordinate.longitude):\(title)",
                    title: title,
                    subtitle: subtitleParts.isEmpty ? "Nearby place" : subtitleParts.joined(separator: " · "),
                    source: .map,
                    visitCount: 0,
                    distanceMeters: distance,
                    targetPlaceID: nil,
                    category: category,
                    latitude: itemCoordinate.latitude,
                    longitude: itemCoordinate.longitude
                )
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
        } catch {
            return []
        }
    }

    /// What was typed, looked up around each of several places at once.
    ///
    /// The completer takes a single region, and a day's stops are rarely in one:
    /// asked around the middle of a day spent at both ends of a city, it offered
    /// the branch of a chain in the middle and neither of the ones at the ends.
    func search(
        _ query: String,
        near anchors: [CLLocationCoordinate2D],
        radius: CLLocationDistance = 2_000
    ) async -> [PlaceNameSuggestion] {
        await withTaskGroup(of: [PlaceNameSuggestion].self) { group in
            for anchor in anchors {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = query
                    request.resultTypes = [.pointOfInterest, .address]
                    request.region = MKCoordinateRegion(
                        center: anchor,
                        latitudinalMeters: radius * 2,
                        longitudinalMeters: radius * 2
                    )
                    guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
                    return response.mapItems.compactMap { item in
                        Self.suggestion(for: item, near: anchors)
                    }
                }
            }
            var found: [PlaceNameSuggestion] = []
            for await rows in group { found.append(contentsOf: rows) }
            return found.sorted { $0.distanceMeters < $1.distanceMeters }
        }
    }

    private static func suggestion(for item: MKMapItem, near anchors: [CLLocationCoordinate2D]) -> PlaceNameSuggestion? {
        let title = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let distance = anchors.map { RoutePlanner.meters($0, coordinate) }.min() ?? .infinity
        let category = item.pointOfInterestCategory?.rawValue
            .replacingOccurrences(of: "MKPOICategory", with: "")
        let address = [item.placemark.subThoroughfare, item.placemark.thoroughfare, item.placemark.locality]
            .compactMap { $0 }
            .joined(separator: " ")
        let subtitle = [address.isEmpty ? nil : address, PlaceGuessRanker.distanceLabel(distance) + " from that day's stops"]
            .compactMap { $0 }
            .joined(separator: " · ")
        return PlaceNameSuggestion(
            id: "search:\(coordinate.latitude),\(coordinate.longitude):\(title)",
            title: title,
            subtitle: subtitle,
            source: .map,
            visitCount: 0,
            distanceMeters: distance,
            targetPlaceID: nil,
            category: category,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    /// The street address, used as a fallback name when no POI fits.
    func address(at coordinate: CLLocationCoordinate2D) async -> PlaceNameSuggestion? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let mark = marks.first else { return nil }
            let title = [
                mark.name,
                mark.thoroughfare.map { street in
                    if let number = mark.subThoroughfare { return "\(number) \(street)" }
                    return street
                },
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            guard let title, !title.isEmpty else { return nil }
            let subtitle = [mark.locality, mark.administrativeArea]
                .compactMap { $0 }
                .joined(separator: ", ")
            return PlaceNameSuggestion(
                id: "address:\(title)",
                title: title,
                subtitle: subtitle.isEmpty ? "Address" : subtitle,
                source: .address,
                visitCount: 0,
                distanceMeters: 0,
                targetPlaceID: nil,
                latitude: mark.location?.coordinate.latitude ?? coordinate.latitude,
                longitude: mark.location?.coordinate.longitude ?? coordinate.longitude
            )
        } catch {
            return nil
        }
    }

    /// What the notification offers as tappable answers: visited places you
    /// already named win over anything the map knows.
    func guesses(
        around coordinate: CLLocationCoordinate2D,
        visited: [PlaceNameSuggestion],
        limit: Int = 2
    ) async -> [PlaceNameSuggestion] {
        async let pois = pointsOfInterest(around: coordinate)
        async let hint = address(at: coordinate)
        let (nearby, addressHint) = await (pois, hint)
        var map = nearby
        if let addressHint { map.insert(addressHint, at: 0) }
        return Array(PlaceGuessRanker.merge(visited: visited, map: map).prefix(limit))
    }
}

/// The one ranking both the rename sheet and the notification use.
enum PlaceGuessRanker {
    static let resultLimit = 20
    /// Two results of one name closer than this are the same branch.
    static let sameBranch: CLLocationDistance = 150

    /// Map and address rows that are not already a place in `visited`.
    ///
    /// The rename sheet shows these on their own tab. Folding them into the
    /// visited list and then keeping the first twenty meant a dense history
    /// used up every row, and a new place next door never appeared.
    static func neverVisited(
        map: [PlaceNameSuggestion],
        visited: [PlaceNameSuggestion],
        limit: Int = resultLimit
    ) -> [PlaceNameSuggestion] {
        let been = Set(visited.map { $0.title.lowercased() })
        var seen = Set<String>()
        var rows: [PlaceNameSuggestion] = []
        for row in map {
            let name = row.title.lowercased()
            guard !name.isEmpty, name != "unnamed place", name != "place" else { continue }
            guard !been.contains(name), seen.insert(name).inserted else { continue }
            rows.append(row)
            if rows.count >= limit { break }
        }
        return rows
    }

    /// Visited places first, then map and address rows, deduped by name.
    ///
    /// `keepingBranches` dedupes by name *and* place instead, for adding a stay:
    /// a chain has a branch near home and another an hour away, and which one
    /// you stopped at is the whole question. A row with no position — a typed
    /// completion — is dropped when a positioned row of the same name is there,
    /// since it cannot say which branch it is.
    static func merge(
        visited: [PlaceNameSuggestion],
        map: [PlaceNameSuggestion],
        keepingBranches: Bool = false,
        limit: Int = resultLimit
    ) -> [PlaceNameSuggestion] {
        let positionedTitles = Set((visited + map).filter { $0.coordinate != nil }.map { $0.title.lowercased() })
        var seen = Set<String>()
        var branches: [String: [CLLocationCoordinate2D]] = [:]
        var merged: [PlaceNameSuggestion] = []
        for row in visited + map {
            let name = row.title.lowercased()
            guard name != "unnamed place" else { continue }
            if keepingBranches, let coordinate = row.coordinate {
                // One branch, however each source happens to have placed it.
                let known = branches[name, default: []]
                guard !known.contains(where: { RoutePlanner.meters($0, coordinate) < Self.sameBranch }) else { continue }
                branches[name] = known + [coordinate]
            } else if keepingBranches {
                guard !positionedTitles.contains(name), seen.insert(name).inserted else { continue }
            } else {
                guard seen.insert(name).inserted else { continue }
            }
            merged.append(row)
            if merged.count >= limit { break }
        }
        return merged
    }

    /// Places you have been whose name matches what was typed, however far away.
    ///
    /// Adding a stay is mostly adding one at somewhere you already go, and the
    /// day's map is no guide to where that is: a coffee pick-up near home, added
    /// from an hour's drive away, was filtered out for being far from the middle
    /// of the day. Most visited first, then nearest to any of the day's stops.
    static func visitedMatches(
        _ query: String,
        places: [(id: String, title: String, visitCount: Int, coordinate: CLLocationCoordinate2D)],
        near stops: [CLLocationCoordinate2D]
    ) -> [PlaceNameSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return places.compactMap { place -> (PlaceNameSuggestion, Double)? in
            let title = place.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != "Unnamed place", title != "Place" else { return nil }
            guard title.lowercased().contains(needle) else { return nil }
            let distance = stops.map { RoutePlanner.meters($0, place.coordinate) }.min() ?? .infinity
            let plural = place.visitCount == 1 ? "" : "s"
            let whereabouts = distance.isFinite ? " · \(distanceLabel(distance)) from that day's stops" : ""
            return (
                PlaceNameSuggestion(
                    id: "visited:\(place.id)",
                    title: title,
                    subtitle: "\(place.visitCount) visit\(plural)\(whereabouts)",
                    source: .visited,
                    visitCount: place.visitCount,
                    distanceMeters: distance,
                    targetPlaceID: place.id,
                    latitude: place.coordinate.latitude,
                    longitude: place.coordinate.longitude
                ),
                distance
            )
        }
        .sorted {
            if $0.0.visitCount != $1.0.visitCount { return $0.0.visitCount > $1.0.visitCount }
            return $0.1 < $1.1
        }
        .map(\.0)
    }

    /// The places worth searching around for a stay added to a day: where the
    /// day's stays were, one per neighbourhood, at most `limit` of them.
    ///
    /// Neighbourhoods rather than stops, because each search already covers a
    /// couple of kilometres — home and the coffee shop down the road are one
    /// search, and the budget goes on the far end of the day instead.
    static func searchAnchors(
        _ coordinates: [CLLocationCoordinate2D],
        apart: CLLocationDistance = 3_000,
        limit: Int = 5
    ) -> [CLLocationCoordinate2D] {
        var anchors: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            guard !anchors.contains(where: { RoutePlanner.meters($0, coordinate) < apart }) else { continue }
            anchors.append(coordinate)
            if anchors.count == limit { break }
        }
        return anchors
    }

    /// Visited stays ranked the way the sheet ranks them: most visited, then nearest.
    static func visitedRows(
        near coordinate: CLLocationCoordinate2D,
        places: [(id: String, title: String, visitCount: Int, coordinate: CLLocationCoordinate2D)],
        excluding placeID: String,
        within meters: CLLocationDistance = 1_500
    ) -> [PlaceNameSuggestion] {
        places.compactMap { place -> (PlaceNameSuggestion, Double)? in
            guard place.id != placeID else { return nil }
            let distance = RoutePlanner.meters(coordinate, place.coordinate)
            guard distance <= reach(visitCount: place.visitCount, base: meters) else { return nil }
            let title = place.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != "Unnamed place", title != "Place" else { return nil }
            let plural = place.visitCount == 1 ? "" : "s"
            return (
                PlaceNameSuggestion(
                    id: "visited:\(place.id)",
                    title: title,
                    subtitle: "\(place.visitCount) visit\(plural) · \(distanceLabel(distance)) · Merge",
                    source: .visited,
                    visitCount: place.visitCount,
                    distanceMeters: distance,
                    targetPlaceID: place.id,
                    latitude: place.coordinate.latitude,
                    longitude: place.coordinate.longitude
                ),
                distance
            )
        }
        .sorted {
            if $0.0.visitCount != $1.0.visitCount { return $0.0.visitCount > $1.0.visitCount }
            return $0.1 < $1.1
        }
        .map(\.0)
    }

    /// Would folding one place into another throw away the greater history?
    ///
    /// A merge names the survivor and discards the other place's identity. Doing
    /// that to the place holding most of the visits is almost always a mis-tap:
    /// seventy-nine stays at a supermarket went into an insurance office twelve
    /// doors down because the two sat side by side in a suggestion list, and
    /// until the unmerge was repaired there was no way back. Small places folding
    /// into big ones is the ordinary case and stays silent.
    static func foldsAwayTheLargerHistory(source: Int, target: Int) -> Bool {
        source >= 10 && source >= target * 3
    }

    /// How far away a place can be and still be worth offering.
    ///
    /// A flat radius throws away the strongest evidence there is. Adding a stay
    /// is centred on the middle of the day's movement, which on a day with any
    /// driving in it is a point you were never at — so a music school visited
    /// four hundred times fell outside the circle and was not offered at all,
    /// while one-off places beside that meaningless midpoint were. Familiarity
    /// earns reach: somewhere you went once has to be right here, somewhere you
    /// go every week is worth offering across town.
    static func reach(visitCount: Int, base: CLLocationDistance) -> CLLocationDistance {
        base * min(8, (Double(max(visitCount, 1))).squareRoot())
    }

    static func distanceLabel(_ meters: Double) -> String {
        guard meters.isFinite else { return "nearby" }
        if meters < 1_000 { return String(format: "%.0f m", meters) }
        return String(format: "%.1f km", meters / 1_000)
    }
}
