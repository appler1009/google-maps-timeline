import Foundation
import SwiftUI
import MapKit

@MainActor
final class TimelineStore: ObservableObject {
    @Published var tab: SidebarTab = .dates
    @Published var search: String = ""
    /// 0 means every year.
    @Published var filterYear: Int = 0
    /// 0 means every month.
    @Published var filterMonth: Int = 0
    @Published var selectedDayID: Date?
    @Published var selectedPlaceID: String?
    @Published var hoveredVisitID: String?
    @Published var parsed: ParsedTimeline?
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var sourceName: String?
    @Published var placeNames: [String: String] = [:]
    @Published var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
        )
    )

    private let names = PlaceNameCache()
    private var geocodeTask: Task<Void, Never>?

    var selectedDay: DayRecord? {
        guard let selectedDayID, let parsed else { return nil }
        return parsed.days.first { $0.day == selectedDayID }
    }

    var selectedPlace: PlaceRecord? {
        guard let selectedPlaceID, let parsed else { return nil }
        return parsed.places.first { $0.id == selectedPlaceID }
    }

    var hoveredVisit: TimelineVisit? {
        guard let hoveredVisitID else { return nil }
        if let visit = selectedDay?.visits.first(where: { $0.id == hoveredVisitID }) {
            return visit
        }
        return selectedPlace?.visits.first(where: { $0.id == hoveredVisitID })
    }

    var windowSubtitle: String {
        if let day = selectedDay {
            return Self.dayTitle(day.day)
        }
        if let place = selectedPlace {
            return displayName(for: place)
        }
        return sourceName ?? ""
    }

    var filteredDays: [DayRecord] {
        guard let parsed else { return [] }
        let calendar = Calendar.current
        return parsed.days.filter { day in
            let parts = calendar.dateComponents([.year, .month], from: day.day)
            if filterYear != 0, parts.year != filterYear { return false }
            if filterMonth != 0, parts.month != filterMonth { return false }
            return true
        }
    }

    var availableYears: [Int] {
        let calendar = Calendar.current
        let years = Set((parsed?.days ?? []).compactMap { calendar.dateComponents([.year], from: $0.day).year })
        return years.sorted(by: >)
    }

    var availableMonths: [Int] {
        let calendar = Calendar.current
        let months = Set((parsed?.days ?? []).compactMap { day -> Int? in
            let parts = calendar.dateComponents([.year, .month], from: day.day)
            if filterYear != 0, parts.year != filterYear { return nil }
            return parts.month
        })
        return months.sorted()
    }

    func clampDateFilters() {
        if filterYear != 0, !availableYears.contains(filterYear) {
            filterYear = 0
        }
        if filterMonth != 0, !availableMonths.contains(filterMonth) {
            filterMonth = 0
        }
        if let selected = selectedDay, !filteredDays.contains(where: { $0.day == selected.day }) {
            if let first = filteredDays.first {
                select(day: first)
            }
        }
    }

    var daysByMonth: [(month: Date, days: [DayRecord])] {
        let calendar = Calendar.current
        var groups: [(Date, [DayRecord])] = []
        var current: (Date, [DayRecord])?
        for day in filteredDays {
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: day.day)) ?? day.day
            if let existing = current, calendar.isDate(existing.0, equalTo: month, toGranularity: .month) {
                current = (existing.0, existing.1 + [day])
            } else {
                if let existing = current { groups.append(existing) }
                current = (month, [day])
            }
        }
        if let existing = current { groups.append(existing) }
        return groups.map { (month: $0.0, days: $0.1) }
    }

    /// Full bar ≈ 90th percentile of daily travel, so typical days stay readable next to a rare long trip.
    var distanceScaleMeters: Double {
        let distances = (parsed?.days ?? []).map(\.travelMeters).filter { $0 > 1 }.sorted()
        guard !distances.isEmpty else { return 50_000 }
        let index = Int((Double(distances.count - 1) * 0.90).rounded(.towardZero))
        return max(distances[index], 10_000)
    }

    var filteredPlaces: [PlaceRecord] {
        guard let parsed else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return parsed.places }
        return parsed.places.filter { place in
            displayName(for: place).localizedCaseInsensitiveContains(query)
                || (place.semanticType?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func displayName(for place: PlaceRecord) -> String {
        if let semantic = TimelineParser.semanticTitle(place.semanticType) {
            return semantic
        }
        if let named = placeNames[place.id], !named.isEmpty {
            return named
        }
        return "Unnamed place"
    }

    func subtitle(for place: PlaceRecord) -> String {
        let visits = "\(place.visitCount) visit\(place.visitCount == 1 ? "" : "s")"
        if TimelineParser.semanticTitle(place.semanticType) != nil, let named = placeNames[place.id] {
            return "\(named) · \(visits)"
        }
        return visits
    }

    func restoreLastOpenedFile() {
        if restoreBookmark() { return }
        tryOpenDownloadsExample()
    }

    func tryOpenDownloadsExample() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let url = downloads?.appendingPathComponent("Timeline.json")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        open(url: url)
    }

    func open(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        isLoading = true
        loadError = nil
        Task {
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                saveBookmark(url)
                let name = url.lastPathComponent
                let parsed = try await Task.detached {
                    try TimelineParser.parse(data: data, sourceName: name)
                }.value
                apply(parsed)
            } catch {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private static let bookmarkKey = "lastTimelineBookmark"

    private func saveBookmark(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    private func restoreBookmark() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return false }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }
        if isStale { saveBookmark(url) }
        open(url: url)
        return true
    }

    func apply(_ parsed: ParsedTimeline) {
        self.parsed = parsed
        sourceName = parsed.sourceName
        isLoading = false
        selectedPlaceID = nil
        selectedDayID = parsed.days.first?.day
        tab = .dates
        search = ""
        filterYear = 0
        filterMonth = 0
        geocodeTask?.cancel()
        Task { placeNames = await names.namesSnapshot() }
        if let day = parsed.days.first {
            focus(day: day)
        }
        geocodeVisiblePlaces(parsed.places)
    }

    func select(day: DayRecord) {
        hoveredVisitID = nil
        selectedDayID = day.day
        selectedPlaceID = nil
        tab = .dates
        focus(day: day)
    }

    func select(place: PlaceRecord) {
        hoveredVisitID = nil
        selectedPlaceID = place.id
        selectedDayID = nil
        tab = .places
        focus(place: place)
        if let coordinate = place.coordinate {
            geocodeTask?.cancel()
            let key = place.id
            Task {
                if let label = await names.resolve(key: key, coordinate: coordinate) {
                    placeNames[key] = label
                }
            }
        }
    }

    func focus(day: DayRecord) {
        cameraPosition = .region(Self.region(covering: day.allCoordinates, fallback: defaultCenter(from: parsed)))
    }

    func focus(place: PlaceRecord) {
        guard let coordinate = place.coordinate else { return }
        cameraPosition = .region(
            MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012))
        )
    }

    private func geocodeVisiblePlaces(_ places: [PlaceRecord]) {
        geocodeTask?.cancel()
        geocodeTask = Task {
            let prioritized = Array(places.prefix(80))
            for place in prioritized {
                if Task.isCancelled { return }
                if placeNames[place.id] != nil { continue }
                if TimelineParser.semanticTitle(place.semanticType) != nil { continue }
                guard let coordinate = place.coordinate else { continue }
                if let label = await names.resolve(key: place.id, coordinate: coordinate) {
                    placeNames[place.id] = label
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func defaultCenter(from parsed: ParsedTimeline?) -> CLLocationCoordinate2D {
        parsed?.places.first(where: { $0.coordinate != nil })?.coordinate
            ?? CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12)
    }

    static func region(covering coordinates: [CLLocationCoordinate2D], fallback: CLLocationCoordinate2D) -> MKCoordinateRegion {
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
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let latDelta = max((maxLat - minLat) * 1.4, 0.008)
        let lonDelta = max((maxLon - minLon) * 1.4, 0.008)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }

    static func dayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    static func shortDayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }
}
