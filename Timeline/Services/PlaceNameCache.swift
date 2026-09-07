import Foundation
import CoreLocation
import MapKit
import Contacts

struct PlaceDetails: Codable, Hashable {
    var title: String
    var address: String?
    var category: String?
    var isBusiness: Bool
}

actor PlaceNameCache {
    private var memory: [String: PlaceDetails] = [:]
    private let fileURL: URL
    private var geocoder = CLGeocoder()
    private var inflight: Set<String> = []

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Timeline", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("place-details.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: PlaceDetails].self, from: data) {
            memory = decoded
        }
    }

    func details(for key: String) -> PlaceDetails? {
        memory[key]
    }

    func snapshot() -> [String: PlaceDetails] {
        memory
    }

    func resolve(key: String, coordinate: CLLocationCoordinate2D) async -> PlaceDetails? {
        if let cached = memory[key] { return cached }
        guard !inflight.contains(key) else { return nil }
        inflight.insert(key)
        defer { inflight.remove(key) }

        if let poi = await nearestPOI(to: coordinate) {
            memory[key] = poi
            persist()
            return poi
        }

        if let geocoded = await reverseDetails(coordinate) {
            memory[key] = geocoded
            persist()
            return geocoded
        }
        return nil
    }

    private func nearestPOI(to coordinate: CLLocationCoordinate2D) async -> PlaceDetails? {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 90)
        request.pointOfInterestFilter = .includingAll
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let ranked = response.mapItems.compactMap { item -> (MKMapItem, CLLocationDistance)? in
                let location = item.placemark.location ?? CLLocation(
                    latitude: item.placemark.coordinate.latitude,
                    longitude: item.placemark.coordinate.longitude
                )
                let distance = origin.distance(from: location)
                guard distance <= 85 else { return nil }
                guard let name = item.name, !name.isEmpty, !Self.looksLikeStreet(name, placemark: item.placemark) else {
                    return nil
                }
                return (item, distance)
            }
            .sorted { $0.1 < $1.1 }

            guard let item = ranked.first?.0 else { return nil }
            return PlaceDetails(
                title: item.name ?? "Place",
                address: Self.address(from: item.placemark),
                category: Self.categoryLabel(item.pointOfInterestCategory),
                isBusiness: true
            )
        } catch {
            return nil
        }
    }

    private func reverseDetails(_ coordinate: CLLocationCoordinate2D) async -> PlaceDetails? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let marks = try await reverseGeocode(location)
            guard let mark = marks.first else { return nil }
            let address = Self.address(from: mark)
            if let area = mark.areasOfInterest?.first, !area.isEmpty {
                return PlaceDetails(title: area, address: address, category: nil, isBusiness: true)
            }
            if let address {
                return PlaceDetails(title: address, address: address, category: nil, isBusiness: false)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> [CLPlacemark] {
        try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { marks, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: marks ?? [])
                }
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(memory) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func looksLikeStreet(_ name: String, placemark: MKPlacemark) -> Bool {
        if let street = placemark.thoroughfare, name.caseInsensitiveCompare(street) == .orderedSame {
            return true
        }
        if let number = placemark.subThoroughfare, let street = placemark.thoroughfare {
            let composed = "\(number) \(street)"
            if name.caseInsensitiveCompare(composed) == .orderedSame { return true }
        }
        return name.range(of: #"^\d+\s"#, options: .regularExpression) != nil
    }

    private static func address(from mark: MKPlacemark) -> String? {
        if let postal = mark.postalAddress {
            return CNPostalAddressFormatter.string(from: postal, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", ")
        }
        return address(from: mark as CLPlacemark)
    }

    private static func address(from mark: CLPlacemark) -> String? {
        var line: [String] = []
        if let number = mark.subThoroughfare, let street = mark.thoroughfare {
            line.append("\(number) \(street)")
        } else if let street = mark.thoroughfare {
            line.append(street)
        }
        if let city = mark.locality { line.append(city) }
        if let region = mark.administrativeArea { line.append(region) }
        if line.isEmpty { return nil }
        return line.joined(separator: ", ")
    }

    private static func categoryLabel(_ category: MKPointOfInterestCategory?) -> String? {
        guard let category else { return nil }
        var raw = category.rawValue
        if let range = raw.range(of: "MKPOICategory") {
            raw.removeSubrange(range)
        }
        let spaced = raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced
    }
}
