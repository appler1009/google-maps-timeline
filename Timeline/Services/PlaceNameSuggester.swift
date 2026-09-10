import Foundation
import MapKit
import CoreLocation
import Observation

struct PlaceNameSuggestion: Identifiable, Hashable {
    enum Source: Hashable {
        case visited
        case map
        case address
    }

    let id: String
    let title: String
    let subtitle: String?
    let source: Source
    let visitCount: Int
    let distanceMeters: Double
    /// When set, choosing this suggestion merges into that place instead of only renaming.
    let targetPlaceID: String?

    var accessibilityLabel: String {
        if let subtitle, !subtitle.isEmpty {
            return "\(title), \(subtitle)"
        }
        return title
    }
}

/// Reverse-geocode / autocomplete suggestions biased to a stay, with visited places ranked first.
@MainActor
@Observable
final class PlaceNameSuggester: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var suggestions: [PlaceNameSuggestion] = []
    private(set) var isLoading = false

    private let completer = MKLocalSearchCompleter()
    private var coordinate = CLLocationCoordinate2D()
    private var excludingPlaceID = ""
    private var visited: [VisitedCandidate] = []
    private var nearbyMap: [PlaceNameSuggestion] = []
    private var addressHint: PlaceNameSuggestion?
    private var query = ""
    private var completerResults: [PlaceNameSuggestion] = []
    private var searchTask: Task<Void, Never>?
    private var requestID = UUID()

    private struct VisitedCandidate {
        let id: String
        let title: String
        let visitCount: Int
        let coordinate: CLLocationCoordinate2D
        let distanceMeters: Double
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func configure(
        around coordinate: CLLocationCoordinate2D,
        excludingPlaceID: String,
        visitedPlaces: [(id: String, title: String, visitCount: Int, coordinate: CLLocationCoordinate2D)]
    ) {
        self.coordinate = coordinate
        self.excludingPlaceID = excludingPlaceID
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 2_400,
            longitudinalMeters: 2_400
        )
        completer.region = region

        visited = visitedPlaces.compactMap { place in
            guard place.id != excludingPlaceID else { return nil }
            let distance = RoutePlanner.meters(coordinate, place.coordinate)
            guard distance <= 1_500 else { return nil }
            let title = place.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != "Unnamed place", title != "Place" else { return nil }
            return VisitedCandidate(
                id: place.id,
                title: title,
                visitCount: place.visitCount,
                coordinate: place.coordinate,
                distanceMeters: distance
            )
        }
        .sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return $0.distanceMeters < $1.distanceMeters
        }

        requestID = UUID()
        let token = requestID
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.loadSeedSuggestions(token: token)
        }
        updateQuery("")
    }

    func updateQuery(_ raw: String) {
        query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuild()
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let mapped = completer.results.prefix(12).map { completion in
            PlaceNameSuggestion(
                id: "completer:\(completion.title)|\(completion.subtitle)",
                title: completion.title,
                subtitle: completion.subtitle.isEmpty ? "Map suggestion" : completion.subtitle,
                source: .map,
                visitCount: 0,
                distanceMeters: .infinity,
                targetPlaceID: nil
            )
        }
        Task { @MainActor in
            self.completerResults = mapped
            self.rebuild()
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.completerResults = []
            self.rebuild()
        }
    }

    private func loadSeedSuggestions(token: UUID) async {
        isLoading = true
        defer {
            if token == requestID { isLoading = false }
        }

        async let pois = fetchNearbyPointsOfInterest()
        async let address = fetchReverseGeocode()
        let (poiSuggestions, reverse) = await (pois, address)
        guard token == requestID else { return }
        nearbyMap = poiSuggestions
        addressHint = reverse
        rebuild()
    }

    private func fetchNearbyPointsOfInterest() async -> [PlaceNameSuggestion] {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 450)
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
                let subtitleParts = [
                    category,
                    distance < .infinity ? Self.distanceLabel(distance) : nil,
                ].compactMap { $0 }
                return PlaceNameSuggestion(
                    id: "poi:\(item.placemark.coordinate.latitude),\(item.placemark.coordinate.longitude):\(title)",
                    title: title,
                    subtitle: subtitleParts.isEmpty ? "Nearby place" : subtitleParts.joined(separator: " · "),
                    source: .map,
                    visitCount: 0,
                    distanceMeters: distance,
                    targetPlaceID: nil
                )
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
        } catch {
            return []
        }
    }

    private func fetchReverseGeocode() async -> PlaceNameSuggestion? {
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
                targetPlaceID: nil
            )
        } catch {
            return nil
        }
    }

    private func rebuild() {
        let needle = query.lowercased()
        var visitedRows = visited.map { candidate in
            PlaceNameSuggestion(
                id: "visited:\(candidate.id)",
                title: candidate.title,
                subtitle: "\(candidate.visitCount) visit\(candidate.visitCount == 1 ? "" : "s") · \(Self.distanceLabel(candidate.distanceMeters)) · Merge",
                source: .visited,
                visitCount: candidate.visitCount,
                distanceMeters: candidate.distanceMeters,
                targetPlaceID: candidate.id
            )
        }
        if !needle.isEmpty {
            visitedRows = visitedRows.filter {
                $0.title.lowercased().contains(needle)
            }
        }

        var mapRows: [PlaceNameSuggestion]
        if needle.isEmpty {
            mapRows = nearbyMap
            if let addressHint {
                mapRows.insert(addressHint, at: 0)
            }
        } else {
            mapRows = completerResults.filter {
                $0.title.lowercased().contains(needle) || ($0.subtitle?.lowercased().contains(needle) ?? false)
            }
            if mapRows.isEmpty {
                mapRows = completerResults
            }
            // Keep nearby POIs that still match while typing short queries.
            let matchingNearby = nearbyMap.filter { $0.title.lowercased().contains(needle) }
            mapRows = matchingNearby + mapRows
        }

        var seen = Set<String>()
        var merged: [PlaceNameSuggestion] = []
        // Visited stays first, then map / address.
        for row in visitedRows + mapRows {
            let key = row.title.lowercased()
            guard seen.insert(key).inserted else { continue }
            guard row.title.lowercased() != "unnamed place" else { continue }
            merged.append(row)
            if merged.count >= 20 { break }
        }
        suggestions = merged
    }

    private static func distanceLabel(_ meters: Double) -> String {
        if meters < 1_000 {
            return String(format: "%.0f m", meters)
        }
        return String(format: "%.1f km", meters / 1_000)
    }
}
