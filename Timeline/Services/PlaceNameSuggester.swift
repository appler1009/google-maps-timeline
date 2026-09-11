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
    private let guesses = PlaceGuessService()
    private var coordinate = CLLocationCoordinate2D()
    private var excludingPlaceID = ""
    private var visited: [PlaceNameSuggestion] = []
    private var nearbyMap: [PlaceNameSuggestion] = []
    private var addressHint: PlaceNameSuggestion?
    private var query = ""
    private var completerResults: [PlaceNameSuggestion] = []
    private var searchTask: Task<Void, Never>?
    private var requestID = UUID()

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

        visited = PlaceGuessRanker.visitedRows(
            near: coordinate,
            places: visitedPlaces,
            excluding: excludingPlaceID
        )

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

        async let pois = guesses.pointsOfInterest(around: coordinate)
        async let address = guesses.address(at: coordinate)
        let (poiSuggestions, reverse) = await (pois, address)
        guard token == requestID else { return }
        nearbyMap = poiSuggestions
        addressHint = reverse
        rebuild()
    }

    private func rebuild() {
        let needle = query.lowercased()
        var visitedRows = visited
        if !needle.isEmpty {
            visitedRows = visitedRows.filter { $0.title.lowercased().contains(needle) }
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

        // Visited stays first, then map / address — the same ranking the recorder
        // uses for notification guesses, so the two can never disagree.
        suggestions = PlaceGuessRanker.merge(visited: visitedRows, map: mapRows)
    }
}
