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
/// notification's guesses and the rename sheet's list can never disagree.
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

    /// Visited places first, then map and address rows, deduped by name.
    static func merge(
        visited: [PlaceNameSuggestion],
        map: [PlaceNameSuggestion],
        limit: Int = resultLimit
    ) -> [PlaceNameSuggestion] {
        var seen = Set<String>()
        var merged: [PlaceNameSuggestion] = []
        for row in visited + map {
            let key = row.title.lowercased()
            guard key != "unnamed place" else { continue }
            guard seen.insert(key).inserted else { continue }
            merged.append(row)
            if merged.count >= limit { break }
        }
        return merged
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
