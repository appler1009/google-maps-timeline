import Foundation
import CoreLocation

/// Turns place *keys* into place *rows*.
///
/// The old model carried the place inside the stay: a stay's key was either a
/// Google Place ID or a rounded coordinate, and its own identity was hashed from
/// that key. Three problems fell out of it. Re-clustering a stay minted a new id
/// instead of updating the row, so the same stop appeared twice. Renaming hit one
/// stay or every stay at a place depending on which kind of key it happened to
/// have. And a place's location could not be corrected, because the coordinate
/// *was* the identity.
///
/// A place is now a row with its own id, name and location, and a stay points at
/// one. Everything the old model expressed — names, corrected locations, merges —
/// folds into that.
enum PlaceEntityMigration {
    /// What the migration produced, for logging and for the tests to assert on.
    struct Result: Equatable {
        var placesCreated = 0
        var visitsLinked = 0
        var mergesFolded = 0
        var namesCarried = 0
        var locationsCarried = 0
    }

    /// A place as it should exist after the migration.
    struct PlannedPlace: Equatable {
        var id: String
        var name: String?
        var coordinate: CLLocationCoordinate2D?
        var semanticType: String?
        /// Every old key that should now resolve to this place, merges included.
        var keys: Set<String>

        static func == (lhs: PlannedPlace, rhs: PlannedPlace) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.semanticType == rhs.semanticType
                && lhs.keys == rhs.keys
                && lhs.coordinate?.latitude == rhs.coordinate?.latitude
                && lhs.coordinate?.longitude == rhs.coordinate?.longitude
        }
    }

    /// Works out the places without touching the database, so the shape of the
    /// migration can be checked against a real library before it is run.
    static func plan(
        visitKeys: [String],
        names: [String: String],
        locations: [String: PlaceLocation],
        merges: [String: String],
        semanticTypes: [String: String],
        averageCoordinates: [String: CLLocationCoordinate2D]
    ) -> [PlannedPlace] {
        // A merged key is not a place of its own; it is another name for its target.
        func survivor(_ key: String) -> String {
            var current = key
            var seen: Set<String> = [key]
            while let next = merges[current], !next.isEmpty, !seen.contains(next) {
                seen.insert(next)
                current = next
            }
            return current
        }

        var keysByPlace: [String: Set<String>] = [:]
        for key in Set(visitKeys).union(names.keys).union(locations.keys).union(merges.keys) {
            guard !key.isEmpty else { continue }
            keysByPlace[survivor(key), default: []].insert(key)
        }

        return keysByPlace
            .map { placeKey, keys -> PlannedPlace in
                // The corrected location wins; otherwise where the stays actually were.
                let corrected = keys.compactMap { locations[$0] }.max { $0.updatedAt < $1.updatedAt }
                let coordinate = corrected?.coordinate ?? averageCoordinates[placeKey]
                    ?? keys.compactMap { averageCoordinates[$0] }.first
                let name = names[placeKey] ?? keys.compactMap { names[$0] }.first
                let semantic = semanticTypes[placeKey] ?? keys.compactMap { semanticTypes[$0] }.first
                return PlannedPlace(
                    id: placeKey,
                    name: name?.isEmpty == true ? nil : name,
                    coordinate: coordinate,
                    semanticType: semantic,
                    keys: keys
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// The place id every old key should resolve to.
    static func linkage(for places: [PlannedPlace]) -> [String: String] {
        var linkage: [String: String] = [:]
        for place in places {
            for key in place.keys {
                linkage[key] = place.id
            }
        }
        return linkage
    }
}
