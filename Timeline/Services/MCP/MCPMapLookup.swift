import Foundation
import MapKit

/// Asking Apple's map where something is.
///
/// Correcting a place needs a coordinate, and an agent that has to invent one
/// will invent one wrong — this is how a school ended up two and a half
/// kilometres from itself. Better to ask.
enum MCPMapLookup {
    struct Result: Sendable {
        var name: String
        var address: String?
        var coordinate: CLLocationCoordinate2D
    }

    static func search(query: String, near centre: CLLocationCoordinate2D?, limit: Int = 5) async -> [Result] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let centre {
            request.region = MKCoordinateRegion(
                center: centre,
                latitudinalMeters: 20_000,
                longitudinalMeters: 20_000
            )
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.prefix(limit).compactMap { item in
            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return Result(
                name: item.name ?? query,
                address: item.placemark.title,
                coordinate: coordinate
            )
        }
    }
}
