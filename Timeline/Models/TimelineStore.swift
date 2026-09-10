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
    var snappedRoutes: [RoutedHop] = []
    var snappedDayID: Date?
    var routeGeneration: UInt64 = 0
    var isRerouting = false
    var directionsThrottled = false
    /// Bumped when the user picks a day or place so compact iOS can show the map.
    var mapRevealGeneration: UInt64 = 0
    /// Points of map the iOS legend sheet hides at the bottom, so the map can
    /// frame a day inside the part that is still visible.
    var legendCoverage: CGFloat = 0

    private let database: TimelineDatabase
    private let snapper: RouteSnapper
    private var routeTask: Task<Void, Never>?
    private var throttleHideTask: Task<Void, Never>?
    private var routesByDay: [Date: [RoutedHop]] = [:]
    private var daysByID: [Date: DayRecord] = [:]
    private var placesByID: [String: PlaceRecord] = [:]
    /// Custom display names keyed by place id / placeKey; survive re-import.
    private var placeNames: [String: String] = [:]
    /// Bumped when a place is renamed so the map refreshes annotation titles.
    private(set) var placeNameGeneration: UInt64 = 0
    private(set) var monthGroups: [(month: Date, days: [DayRecord])] = []
    private(set) var yearOptions: [Int] = []
    private(set) var monthOptions: [Int] = []

    init(database: TimelineDatabase = TimelineDatabase(), snapper: RouteSnapper? = nil) {
        self.database = database
        self.snapper = snapper ?? RouteSnapper(database: database)
    }

    static func uiTesting() -> TimelineStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-ui-test.sqlite")
        try? FileManager.default.removeItem(at: url)
        let database = TimelineDatabase(fileURL: url)
        let snapper = RouteSnapper(database: database, directions: ScriptedMapDirectionsClient.alongRoads())
        return TimelineStore(database: database, snapper: snapper)
    }

    func loadBundledFixture() {
        guard let url = Bundle.main.url(forResource: "eiffel-tower-day", withExtension: "json") else {
            loadError = "Missing bundled test fixture."
            return
        }
        open(url: url)
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
            #if os(iOS)
            selectedDayID = nil
            #else
            if let first = monthGroups.first?.days.first {
                select(day: first)
            }
            #endif
        }
    }

    func day(for id: Date) -> DayRecord? { daysByID[id] }
    func place(for id: String) -> PlaceRecord? { placesByID[id] }

    var filteredDays: [DayRecord] {
        monthGroups.flatMap(\.days)
    }

    /// Newest-first list order: positive offset is older, negative is newer.
    func stepDay(by offset: Int) {
        let days = filteredDays
        guard let id = selectedDayID, let index = days.firstIndex(where: { $0.day == id }) else { return }
        let next = index + offset
        guard days.indices.contains(next) else { return }
        select(day: days[next])
    }

    var canStepToNewerDay: Bool {
        guard let id = selectedDayID, let index = filteredDays.firstIndex(where: { $0.day == id }) else { return false }
        return index > 0
    }

    var canStepToOlderDay: Bool {
        guard let id = selectedDayID, let index = filteredDays.firstIndex(where: { $0.day == id }) else { return false }
        return index + 1 < filteredDays.count
    }

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
        if let custom = placeNames[placeKey], !custom.isEmpty {
            return custom
        }
        return TimelineParser.semanticTitle(semanticType) ?? "Unnamed place"
    }

    func canRename(_ place: PlaceRecord) -> Bool {
        switch place.semanticType {
        case "Home", "Work": return false
        default: return true
        }
    }

    func renamePlace(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            placeNames.removeValue(forKey: id)
        } else {
            placeNames[id] = trimmed
        }
        // Reassign so Observation always notices dictionary edits.
        placeNames = placeNames
        placeNameGeneration &+= 1
        Task {
            try? await database.setPlaceName(placeKey: id, name: trimmed)
        }
    }

    /// Nearby rename suggestions prefer these frequently visited stays.
    func visitedPlaceNameCandidates(
        excluding placeID: String
    ) -> [(id: String, title: String, visitCount: Int, coordinate: CLLocationCoordinate2D)] {
        guard let parsed else { return [] }
        return parsed.places.compactMap { place in
            guard place.id != placeID, let coordinate = place.coordinate else { return nil }
            return (place.id, displayName(for: place), place.visitCount, coordinate)
        }
    }

    /// Titles for the currently visible map annotations (day visits and/or selected place).
    func mapAnnotationTitles() -> [String: String] {
        var titles: [String: String] = [:]
        if let day = selectedDay {
            for visit in day.visits {
                titles[visit.placeKey] = displayName(placeKey: visit.placeKey, semanticType: visit.semanticType)
            }
        }
        if let place = selectedPlace {
            titles[place.id] = displayName(for: place)
        }
        return titles
    }

    func selectTab(_ tab: SidebarTab) {
        self.tab = tab
        search = ""
        #if os(iOS)
        if tab == .dates, let day = selectedDay {
            focus(day: day)
        } else if tab == .places, let place = selectedPlace {
            focus(place: place)
        }
        #else
        if tab == .dates {
            if selectedDay == nil, let day = parsed?.days.first {
                select(day: day)
            } else if let day = selectedDay {
                focus(day: day)
            }
        } else {
            if selectedPlace == nil, let place = parsed?.places.first {
                select(place: place)
            } else if let place = selectedPlace {
                focus(place: place)
            }
        }
        #endif
    }

    func subtitle(for place: PlaceRecord) -> String {
        "\(place.visitCount) visit\(place.visitCount == 1 ? "" : "s")"
    }

    func restoreLastOpenedFile() {
        Task {
            if isLoading { return }
            await refreshPlaceNames()
            if let batch = try? await database.loadBatch() {
                if isLoading { return }
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
                await refreshPlaceNames()
                apply(TimelineParser.assemble(merged, sourceName: source))
            } catch {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private static let bookmarkKey = "lastTimelineBookmark"

    private func saveBookmark(_ url: URL) {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    private func restoreBookmark() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return false }
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: options,
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
        routesByDay = [:]
        #if os(iOS)
        selectedDayID = nil
        #else
        selectedDayID = parsed.days.first?.day
        if let day = parsed.days.first {
            focus(day: day)
            requestRoutes(for: day)
        }
        #endif
    }

    private func refreshPlaceNames() async {
        placeNames = (try? await database.loadPlaceNames()) ?? placeNames
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
        mapRevealGeneration &+= 1
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
        mapRevealGeneration &+= 1
        focus(place: place)
    }

    func focus(day: DayRecord) {
        focusRegion = day.region
        focusAnimated = true
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

    var routesForDisplay: [RoutedHop] {
        guard snappedDayID == selectedDayID else { return [] }
        return snappedRoutes
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
        requestRoutes(for: day, fresh: true)
    }

    private func requestRoutes(for day: DayRecord, fresh: Bool = false) {
        if !fresh, snappedDayID == day.day, !snappedRoutes.isEmpty { return }
        if !fresh, let ready = routesByDay[day.day], !ready.isEmpty {
            snappedRoutes = ready
            snappedDayID = day.day
            routeGeneration &+= 1
            return
        }
        routeTask?.cancel()
        isRerouting = fresh
        if fresh {
            directionsThrottled = false
            throttleHideTask?.cancel()
        }
        if snappedDayID != day.day {
            snappedRoutes = []
            snappedDayID = nil
        }
        let snapper = snapper
        let hops = RoutePlanner.plannedHops(for: day)
        routeTask = Task {
            defer {
                if !Task.isCancelled { isRerouting = false }
            }
            if !fresh, !hops.isEmpty {
                var cached: [RoutedHop] = []
                cached.reserveCapacity(hops.count)
                var complete = true
                for hop in hops {
                    if Task.isCancelled { return }
                    guard let points = await snapper.cached(id: hop.id, kind: hop.kind, points: hop.points) else {
                        complete = false
                        break
                    }
                    cached.append(RoutedHop(id: "\(hop.id):\(hop.kind.stored)", points: points, kind: hop.kind, at: hop.at, until: hop.until))
                }
                if complete, !Task.isCancelled {
                    routesByDay[day.day] = cached
                    snappedRoutes = cached
                    snappedDayID = day.day
                    routeGeneration &+= 1
                    return
                }
            }
            var lines: [RoutedHop] = []
            lines.reserveCapacity(hops.count)
            var throttled = false
            for hop in hops {
                if Task.isCancelled { return }
                let snapped = await snapper.snap(id: hop.id, points: hop.points, kind: hop.kind, fresh: fresh)
                throttled = throttled || snapped.throttled
                lines.append(RoutedHop(id: "\(hop.id):\(hop.kind.stored)", points: snapped.points, kind: hop.kind, at: hop.at, until: hop.until))
            }
            if Task.isCancelled { return }
            routesByDay[day.day] = lines
            snappedRoutes = lines
            snappedDayID = day.day
            routeGeneration &+= 1
            if fresh, throttled {
                flashDirectionsThrottle()
            }
        }
    }

    private func flashDirectionsThrottle() {
        directionsThrottled = true
        throttleHideTask?.cancel()
        throttleHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            directionsThrottled = false
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
