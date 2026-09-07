import Foundation
import SwiftUI
import MapKit
import Observation

@Observable
@MainActor
final class TimelineStore {
    var tab: SidebarTab = .dates
    var search: String = ""
    /// 0 means every year.
    var filterYear: Int = 0
    /// 0 means every month.
    var filterMonth: Int = 0
    var selectedDayID: Date?
    var selectedPlaceID: String?
    var hoveredVisitID: String?
    var parsed: ParsedTimeline?
    var isLoading = false
    var loadError: String?
    var sourceName: String?
    var placeDetails: [String: PlaceDetails] = [:]
    var focusRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    var focusGeneration: UInt64 = 0
    var focusAnimated = false

    private let names = PlaceNameCache()
    private var geocodeTask: Task<Void, Never>?
    private var daysByID: [Date: DayRecord] = [:]
    private var placesByID: [String: PlaceRecord] = [:]
    private(set) var monthGroups: [(month: Date, days: [DayRecord])] = []
    private(set) var yearOptions: [Int] = []
    private(set) var monthOptions: [Int] = []

    var selectedDay: DayRecord? {
        guard let selectedDayID else { return nil }
        return daysByID[selectedDayID]
    }

    var selectedPlace: PlaceRecord? {
        guard let selectedPlaceID else { return nil }
        return placesByID[selectedPlaceID]
    }

    var hoveredVisit: TimelineVisit? {
        guard let hoveredVisitID else { return nil }
        if let visit = selectedDay?.visits.first(where: { $0.id == hoveredVisitID }) {
            return visit
        }
        return selectedPlace?.recentVisits.first(where: { $0.id == hoveredVisitID })
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

    var availableYears: [Int] { yearOptions }

    var availableMonths: [Int] { monthOptions }

    func clampDateFilters() {
        rebuildDateIndexes()
        if filterYear != 0, !yearOptions.contains(filterYear) {
            filterYear = 0
        }
        if filterMonth != 0, !monthOptions.contains(filterMonth) {
            filterMonth = 0
        }
        rebuildDateIndexes()
        if let selected = selectedDay, !monthGroups.contains(where: { group in group.days.contains(where: { $0.day == selected.day }) }) {
            if let first = monthGroups.first?.days.first {
                select(day: first)
            }
        }
    }

    func day(for id: Date) -> DayRecord? { daysByID[id] }
    func place(for id: String) -> PlaceRecord? { placesByID[id] }

    var distanceScaleMeters: Double = 50_000

    var filteredPlaces: [PlaceRecord] {
        guard let parsed else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return parsed.places }
        return parsed.places.filter { place in
            displayName(for: place).localizedCaseInsensitiveContains(query)
                || (place.semanticType?.localizedCaseInsensitiveContains(query) ?? false)
                || (placeDetails[place.id]?.address?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func displayName(for place: PlaceRecord) -> String {
        displayName(placeKey: place.id, semanticType: place.semanticType)
    }

    func displayName(placeKey: String, semanticType: String?) -> String {
        if let semantic = TimelineParser.semanticTitle(semanticType) {
            return semantic
        }
        if let details = placeDetails[placeKey], !details.title.isEmpty {
            return details.title
        }
        return "Unnamed place"
    }

    func subtitle(for place: PlaceRecord) -> String {
        let visits = "\(place.visitCount) visit\(place.visitCount == 1 ? "" : "s")"
        if let details = placeDetails[place.id], details.isBusiness,
           TimelineParser.semanticTitle(place.semanticType) != nil {
            return "\(details.title) · \(visits)"
        }
        return visits
    }

    func details(for placeKey: String) -> PlaceDetails? {
        placeDetails[placeKey]
    }

    func restoreLastOpenedFile() {
        Task {
            placeDetails = await names.snapshot()
            if restoreBookmark() { return }
            tryOpenDownloadsExample()
        }
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
        filterYear = parsed.days.first.map { Calendar.current.component(.year, from: $0.day) } ?? 0
        filterMonth = 0
        distanceScaleMeters = Self.scale(for: parsed.days)
        daysByID = Dictionary(uniqueKeysWithValues: parsed.days.map { ($0.day, $0) })
        placesByID = Dictionary(uniqueKeysWithValues: parsed.places.map { ($0.id, $0) })
        yearOptions = Set(parsed.days.map { Calendar.current.component(.year, from: $0.day) }).sorted(by: >)
        rebuildDateIndexes()
        Task { placeDetails = await names.snapshot() }
        if let day = parsed.days.first {
            focus(day: day)
            resolveDetails(for: day.visits)
        }
    }

    func select(day: DayRecord) {
        selectedDayID = day.day
        tab = .dates
        handleDaySelectionChange()
    }

    func handleDaySelectionChange() {
        guard let day = selectedDay else { return }
        if hoveredVisitID != nil { hoveredVisitID = nil }
        if selectedPlaceID != nil { selectedPlaceID = nil }
        focus(day: day)
        resolveDetails(for: day.visits)
    }

    func prefetchPlaceCatalog() {
        guard let parsed else { return }
        resolveDetails(for: Array(parsed.places.prefix(50)))
    }

    func select(place: PlaceRecord) {
        selectedPlaceID = place.id
        tab = .places
        handlePlaceSelectionChange()
    }

    func handlePlaceSelectionChange() {
        guard let place = selectedPlace else { return }
        if hoveredVisitID != nil { hoveredVisitID = nil }
        if selectedDayID != nil { selectedDayID = nil }
        focus(place: place)
        resolveDetails(for: [place])
    }

    func focus(day: DayRecord) {
        focusRegion = day.region
        focusAnimated = false
        focusGeneration &+= 1
    }

    func focus(place: PlaceRecord) {
        guard let coordinate = place.coordinate ?? place.recentVisits.compactMap(\.coordinate).first else { return }
        focus(coordinate: coordinate)
    }

    func focus(visit: TimelineVisit) {
        guard let coordinate = visit.coordinate else { return }
        focus(coordinate: coordinate)
    }

    private func focus(coordinate: CLLocationCoordinate2D) {
        focusRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.0028, longitudeDelta: 0.0028)
        )
        focusAnimated = true
        focusGeneration &+= 1
    }

    private func resolveDetails(for visits: [TimelineVisit]) {
        let jobs = visits.compactMap { visit -> (String, CLLocationCoordinate2D)? in
            guard let coordinate = visit.coordinate else { return nil }
            return (visit.placeKey, coordinate)
        }
        resolveDetails(jobs)
    }

    private func resolveDetails(for places: [PlaceRecord]) {
        let jobs = places.compactMap { place -> (String, CLLocationCoordinate2D)? in
            guard let coordinate = place.coordinate else { return nil }
            return (place.id, coordinate)
        }
        resolveDetails(jobs)
    }

    private func resolveDetails(_ jobs: [(String, CLLocationCoordinate2D)]) {
        geocodeTask?.cancel()
        geocodeTask = Task {
            var seen = Set<String>()
            for (key, coordinate) in jobs {
                if Task.isCancelled { return }
                if seen.contains(key) { continue }
                seen.insert(key)
                if placeDetails[key] != nil { continue }
                if let details = await names.resolve(key: key, coordinate: coordinate) {
                    placeDetails[key] = details
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    private func rebuildDateIndexes() {
        let calendar = Calendar.current
        let days = parsed?.days ?? []
        monthOptions = Set(days.compactMap { day -> Int? in
            let parts = calendar.dateComponents([.year, .month], from: day.day)
            if filterYear != 0, parts.year != filterYear { return nil }
            return parts.month
        }).sorted()

        var groups: [(month: Date, days: [DayRecord])] = []
        for day in days {
            let parts = calendar.dateComponents([.year, .month], from: day.day)
            if filterYear != 0, parts.year != filterYear { continue }
            if filterMonth != 0, parts.month != filterMonth { continue }
            let month = calendar.date(from: DateComponents(year: parts.year, month: parts.month)) ?? day.day
            if var last = groups.last, calendar.isDate(last.month, equalTo: month, toGranularity: .month) {
                last.days.append(day)
                groups[groups.count - 1] = last
            } else {
                groups.append((month: month, days: [day]))
            }
        }
        monthGroups = groups
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

    private static func scale(for days: [DayRecord]) -> Double {
        let distances = days.map(\.travelMeters).filter { $0 > 1 }.sorted()
        guard !distances.isEmpty else { return 50_000 }
        let index = Int((Double(distances.count - 1) * 0.90).rounded(.towardZero))
        return max(distances[index], 10_000)
    }
}
