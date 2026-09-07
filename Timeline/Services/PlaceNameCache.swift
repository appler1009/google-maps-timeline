import Foundation
import CoreLocation

actor PlaceNameCache {
    private var memory: [String: String] = [:]
    private let fileURL: URL
    private var geocoder = CLGeocoder()
    private var inflight: Set<String> = []

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Timeline", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("place-names.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            memory = decoded
        }
    }

    func name(for key: String) -> String? {
        memory[key]
    }

    func namesSnapshot() -> [String: String] {
        memory
    }

    func resolve(key: String, coordinate: CLLocationCoordinate2D) async -> String? {
        if let cached = memory[key] { return cached }
        guard !inflight.contains(key) else { return nil }
        inflight.insert(key)
        defer { inflight.remove(key) }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let marks = try await reverseGeocode(location)
            if let label = Self.label(from: marks.first) {
                memory[key] = label
                persist()
                return label
            }
        } catch {
            return nil
        }
        return nil
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

    private static func label(from mark: CLPlacemark?) -> String? {
        guard let mark else { return nil }
        if let name = mark.name, !name.isEmpty,
           mark.thoroughfare == nil || name != mark.thoroughfare {
            if let locality = mark.locality, !name.contains(locality) {
                return "\(name), \(locality)"
            }
            return name
        }
        let parts = [mark.thoroughfare, mark.subThoroughfare, mark.locality, mark.subLocality]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if parts.isEmpty {
            return [mark.locality, mark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        }
        if let street = mark.thoroughfare {
            if let number = mark.subThoroughfare {
                let city = mark.locality.map { ", \($0)" } ?? ""
                return "\(number) \(street)\(city)"
            }
            let city = mark.locality.map { ", \($0)" } ?? ""
            return "\(street)\(city)"
        }
        return parts.first
    }
}
