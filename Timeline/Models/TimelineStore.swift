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
    var selectedVisitID: String?
    var parsed: ParsedTimeline?
    var isLoading = false
    var loadError: String?
    var sourceName: String?
    var focusRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    var focusGeneration: UInt64 = 0
    var focusAnimated = false
    var snappedRoutes: [[CLLocationCoordinate2D]] = []
    var snappedDayID: Date?
    var routeGeneration: UInt64 = 0
    var isRerouting = false

    private let database: TimelineDatabase
    private let snapper: RouteSnapper
    private var routeTask: Task<Void, Never>?
    private var daysByID: [Date: DayRecord] = [:]
    private var placesByID: [String: PlaceRecord] = [:]
    private(set) var monthGroups: [(month: Date, days: [DayRecord])] = []
    private(set) var yearOptions: [Int] = []
    private(set) var monthOptions: [Int] = []

    init() {
        let database = TimelineDatabase()
        self.database = database
        self.snapper = RouteSnapper(database: database)
    }

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
        }
    }

    func displayName(for place: PlaceRecord) -> String {
        displayName(placeKey: place.id, semanticType: place.semanticType)
    }

    func displayName(placeKey: String, semanticType: String?) -> String {
        TimelineParser.semanticTitle(semanticType) ?? "Unnamed place"
    }

    func subtitle(for place: PlaceRecord) -> String {
        "\(place.visitCount) visit\(place.visitCount == 1 ? "" : "s")"
    }

    func restoreLastOpenedFile() {
        Task {
            if let batch = try? await database.loadBatch() {
                let name = (try? await database.latestSourceName()) ?? "Library"
                apply(TimelineParser.assemble(batch, sourceName: name))
                return
            }
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
                let batch = try await Task.detached {
                    try TimelineParser.extract(data)
                }.value
                try await database.upsert(batch: batch, sourceName: name)
                let merged = try await database.loadBatch() ?? batch
                let source = (try? await database.latestSourceName()) ?? name
                apply(TimelineParser.assemble(merged, sourceName: source))
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
        selectedVisitID = nil
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
        snappedRoutes = []
        snappedDayID = nil
        if let day = parsed.days.first {
            focus(day: day)
            requestRoutes(for: day)
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
        if selectedVisitID != nil { selectedVisitID = nil }
        if selectedPlaceID != nil { selectedPlaceID = nil }
        focus(day: day)
        requestRoutes(for: day)
    }

    func select(place: PlaceRecord) {
        selectedPlaceID = place.id
        tab = .places
        handlePlaceSelectionChange()
    }

    func handlePlaceSelectionChange() {
        guard let place = selectedPlace else { return }
        if hoveredVisitID != nil { hoveredVisitID = nil }
        if selectedVisitID != nil { selectedVisitID = nil }
        if selectedDayID != nil { selectedDayID = nil }
        focus(place: place)
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
        selectedVisitID = visit.id
        hoveredVisitID = visit.id
        guard let coordinate = visit.coordinate else { return }
        focus(coordinate: coordinate)
    }

    func focusVisit(id: String) {
        guard let visit = selectedDay?.visits.first(where: { $0.id == id }) else { return }
        focus(visit: visit)
    }

    func clearVisitFocus() {
        if selectedVisitID != nil { selectedVisitID = nil }
        if hoveredVisitID != nil { hoveredVisitID = nil }
        if let day = selectedDay {
            focus(day: day)
        }
    }

    var routesForDisplay: [[CLLocationCoordinate2D]] {
        guard snappedDayID == selectedDayID else { return [] }
        guard let day = selectedDay, let visitID = selectedVisitID else { return snappedRoutes }
        let spots = day.visits.filter { $0.coordinate != nil }
        guard let index = spots.firstIndex(where: { $0.id == visitID }) else { return snappedRoutes }
        var lines: [[CLLocationCoordinate2D]] = []
        if index > 0, snappedRoutes.indices.contains(index - 1) {
            lines.append(snappedRoutes[index - 1])
        }
        if index < spots.count - 1, snappedRoutes.indices.contains(index) {
            lines.append(snappedRoutes[index])
        }
        return lines
    }

    private func focus(coordinate: CLLocationCoordinate2D) {
        focusRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.0028, longitudeDelta: 0.0028)
        )
        focusAnimated = true
        focusGeneration &+= 1
    }

    func rerouteSelectedDay() {
        guard let day = selectedDay else { return }
        snappedRoutes = []
        snappedDayID = nil
        requestRoutes(for: day, fresh: true)
    }

    private func requestRoutes(for day: DayRecord, fresh: Bool = false) {
        if !fresh, snappedDayID == day.day, !snappedRoutes.isEmpty { return }
        routeTask?.cancel()
        isRerouting = fresh
        let snapper = snapper
        routeTask = Task {
            defer {
                if !Task.isCancelled { isRerouting = false }
            }
            var lines: [[CLLocationCoordinate2D]] = []
            let spots = day.visits.compactMap { visit -> (TimelineVisit, CLLocationCoordinate2D)? in
                guard let coordinate = visit.coordinate else { return nil }
                return (visit, coordinate)
            }
            if spots.count >= 2 {
                for index in 0..<(spots.count - 1) {
                    if Task.isCancelled { return }
                    let from = spots[index]
                    let to = spots[index + 1]
                    let kind = Self.kind(from: from.0, to: to.0, activities: day.activityLines)
                    lines.append(
                        await snapper.snap(
                            id: "hop:\(from.0.id):\(to.0.id)",
                            points: [from.1, to.1],
                            kind: kind,
                            fresh: fresh
                        )
                    )
                }
            } else if !day.paths.isEmpty {
                for path in day.paths where path.points.count >= 2 {
                    if Task.isCancelled { return }
                    lines.append(await snapper.snap(id: path.id, points: path.points, kind: path.kind, fresh: fresh))
                }
            } else {
                for line in day.activityLines {
                    if Task.isCancelled { return }
                    lines.append(await snapper.snap(id: line.id, points: [line.start, line.end], kind: line.kind, fresh: fresh))
                }
            }
            if Task.isCancelled { return }
            snappedRoutes = lines
            snappedDayID = day.day
            routeGeneration &+= 1
        }
    }

    private static func kind(from: TimelineVisit, to: TimelineVisit, activities: [ActivityLine]) -> TravelKind {
        let midpoint = from.end.addingTimeInterval(to.start.timeIntervalSince(from.end) / 2)
        return activities.min(by: {
            abs($0.at.timeIntervalSince(midpoint)) < abs($1.at.timeIntervalSince(midpoint))
        })?.kind ?? .automobile
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
