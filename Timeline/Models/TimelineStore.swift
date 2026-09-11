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
    private let identitySync = PlaceIdentitySync.shared
    private var routeTask: Task<Void, Never>?
    private var throttleHideTask: Task<Void, Never>?
    private var routesByDay: [Date: [RoutedHop]] = [:]
    private var daysByID: [Date: DayRecord] = [:]
    private var placesByID: [String: PlaceRecord] = [:]
    /// Custom display names keyed by place id / placeKey; survive re-import.
    private var placeNames: [String: String] = [:]
    /// Active merge aliases `fromKey → toKey` (tombstones omitted).
    private var placeMerges: [String: String] = [:]
    /// Bumped when a place is renamed so the map refreshes annotation titles.
    private(set) var placeNameGeneration: UInt64 = 0
    /// Imported stays the recorder superseded are hidden. Showing them is the
    /// escape hatch if reconciliation ever gets a day wrong. Stored rather than
    /// read straight from UserDefaults so the settings toggle redraws.
    var showsShadowedImports: Bool = UserDefaults.standard.bool(forKey: TimelineStore.shadowedKey) {
        didSet {
            guard showsShadowedImports != oldValue else { return }
            UserDefaults.standard.set(showsShadowedImports, forKey: TimelineStore.shadowedKey)
            refreshFromLibrary()
        }
    }
    private static let shadowedKey = "showsShadowedImports"
    private var isApplyingCloudIdentity = false
    private(set) var monthGroups: [(month: Date, days: [DayRecord])] = []
    private(set) var yearOptions: [Int] = []
    private(set) var monthOptions: [Int] = []

    init(database: TimelineDatabase = TimelineDatabase(), snapper: RouteSnapper? = nil) {
        self.database = database
        self.snapper = snapper ?? RouteSnapper(database: database)
        if !TimelineLaunch.isUITesting {
            identitySync.start { [weak self] in
                Task { @MainActor in
                    await self?.pullPlaceIdentityFromCloud()
                }
            }
        }
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
        if let visit = activeDay?.visits.first(where: { $0.id == hoveredVisitID }) {
            return visit
        }
        return activePlace?.recentVisits.first(where: { $0.id == hoveredVisitID })
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
        if let title = TimelineParser.semanticTitle(semanticType) {
            return title
        }
        // Merged stays keep the target place key; inherit Home/Work (etc.) from that place.
        if let place = placesByID[placeKey],
           let title = TimelineParser.semanticTitle(place.semanticType)
        {
            return title
        }
        return "Unnamed place"
    }

    func canRename(_ place: PlaceRecord) -> Bool {
        switch place.semanticType {
        case "Home", "Work": return false
        default: return true
        }
    }

    /// Rename and/or unmerge overflow for a place.
    func showsPlaceActions(_ place: PlaceRecord) -> Bool {
        canRename(place) || !sourcesMerged(into: place.id).isEmpty
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
            TimelineLog.info("place renamed", ["placeKey": id, "name": trimmed])
            await pushPlaceIdentityToCloud()
        }
    }

    /// Fold `sourceID` into `targetID` so Places shows a single entry.
    func mergePlace(from sourceID: String, into targetID: String) {
        guard sourceID != targetID, let target = placesByID[targetID] else { return }
        placeNames.removeValue(forKey: sourceID)
        placeNames = placeNames
        isLoading = true
        Task {
            try? await database.mergePlace(
                from: sourceID,
                into: targetID,
                targetSemantic: target.semanticType
            )
            await refreshPlaceIdentity()
            await pushPlaceIdentityToCloud()
            if let batch = try? await database.loadBatch() {
                let name = (try? await database.latestSourceName()) ?? sourceName ?? "Library"
                let timeline = TimelineParser.assemble(batch, sourceName: name)
                apply(timeline)
                if let merged = placesByID[targetID] {
                    select(place: merged)
                }
            } else {
                isLoading = false
            }
            placeNameGeneration &+= 1
        }
    }

    /// Places previously folded into `placeID` (for Unmerge in the place menu).
    func sourcesMerged(into placeID: String) -> [(id: String, title: String)] {
        placeMerges.compactMap { fromKey, toKey -> (id: String, title: String)? in
            guard toKey == placeID else { return nil }
            return (fromKey, mergeSourceTitle(fromKey))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Split `sourceID` back out of whatever it was merged into.
    func unmergePlace(from sourceID: String) {
        guard placeMerges[sourceID] != nil else { return }
        isLoading = true
        Task {
            try? await database.unmergePlace(from: sourceID)
            await refreshPlaceIdentity()
            await pushPlaceIdentityToCloud()
            if let batch = try? await database.loadBatch() {
                let name = (try? await database.latestSourceName()) ?? sourceName ?? "Library"
                let keepPlaceID = selectedPlaceID
                apply(TimelineParser.assemble(batch, sourceName: name))
                if let id = keepPlaceID, let place = placesByID[id] {
                    select(place: place)
                } else if let restored = placesByID[sourceID] {
                    select(place: restored)
                }
            } else {
                isLoading = false
            }
            placeNameGeneration &+= 1
            TimelineLog.info("place unmerged", ["placeKey": sourceID])
        }
    }

    private func mergeSourceTitle(_ fromKey: String) -> String {
        if let custom = placeNames[fromKey], !custom.isEmpty {
            return custom
        }
        if let title = TimelineParser.semanticTitle(placesByID[fromKey]?.semanticType) {
            return title
        }
        if fromKey.contains(",") {
            return "Place at \(fromKey)"
        }
        if fromKey.count > 12 {
            return "Merged place (\(fromKey.prefix(8))…)"
        }
        return "Merged place"
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
        if let day = activeDay {
            for visit in day.visits {
                titles[visit.placeKey] = displayName(placeKey: visit.placeKey, semanticType: visit.semanticType)
            }
        }
        if let place = activePlace {
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
                // First launch into Dates with nothing remembered yet.
                selectedDayID = day.day
                focus(day: day)
                requestRoutes(for: day)
            } else if let day = selectedDay {
                focus(day: day)
            }
        } else {
            if selectedPlace == nil, let place = parsed?.places.first {
                selectedPlaceID = place.id
                focus(place: place)
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
            await pullPlaceIdentityFromCloud()
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
                // Fold the export into whatever the phone recorded before the
                // library is assembled, so the day view never shows both.
                _ = try? await database.reconcileSources()
                let merged = try await database.loadBatch(includingShadowed: showsShadowedImports) ?? batch
                let source = (try? await database.latestSourceName()) ?? name
                await refreshPlaceNames()
                await pullPlaceIdentityFromCloud()
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

    /// Re-run the merge of recorded and imported days, then reload.
    func reconcileLibrary() {
        Task {
            let plan = try? await database.reconcileSources()
            TimelineLog.info(
                "library reconciled",
                ["shadowed": "\(plan?.shadowedVisitIDs.count ?? 0)", "aliases": "\(plan?.placeAliases.count ?? 0)"]
            )
            await refreshPlaceIdentity()
            refreshFromLibrary()
        }
    }

    /// Reload after the recorder wrote something. Unlike `apply`, this keeps the
    /// day, place and filters the user is looking at — a stay recorded in the
    /// background must not yank the map out from under them.
    func refreshFromLibrary() {
        guard !isLoading else { return }
        Task {
            guard let batch = try? await database.loadBatch(includingShadowed: showsShadowedImports) else { return }
            await refreshPlaceIdentity()
            let name = (try? await database.latestSourceName()) ?? sourceName ?? "This device"
            let keptDay = selectedDayID
            let keptPlace = selectedPlaceID
            let keptTab = tab
            let keptYear = filterYear
            let keptMonth = filterMonth
            let keptSearch = search
            apply(TimelineParser.assemble(batch, sourceName: name))
            tab = keptTab
            search = keptSearch
            filterYear = keptYear
            filterMonth = keptMonth
            clampDateFilters()
            if let keptDay, daysByID[keptDay] != nil {
                selectedDayID = keptDay
            }
            if let keptPlace, placesByID[keptPlace] != nil {
                selectedPlaceID = keptPlace
            }
        }
    }

    /// Apply a name the user picked straight from a visit notification. The key
    /// may be a place the app has not assembled yet, so this writes through to the
    /// library and reloads rather than going via `placesByID`.
    func applyRecordedPlaceName(_ name: String, forPlaceKey placeKey: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        placeNames[placeKey] = trimmed
        placeNames = placeNames
        placeNameGeneration &+= 1
        Task {
            try? await database.setPlaceName(placeKey: placeKey, name: trimmed)
            await pushPlaceIdentityToCloud()
            TimelineLog.info("recorded place named", ["placeKey": placeKey, "name": trimmed])
            refreshFromLibrary()
        }
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

    private func refreshPlaceIdentity() async {
        placeNames = (try? await database.loadPlaceNames()) ?? placeNames
        placeMerges = (try? await database.loadPlaceMerges()) ?? placeMerges
    }

    private func refreshPlaceNames() async {
        await refreshPlaceIdentity()
    }

    private func pushPlaceIdentityToCloud() async {
        guard !TimelineLaunch.isUITesting, !isApplyingCloudIdentity else { return }
        let names = (try? await database.loadPlaceNameRecords()) ?? [:]
        let merges = (try? await database.loadPlaceMergeRecords()) ?? [:]
        TimelineLog.debug("place-identity store push", ["names": "\(names.count)", "merges": "\(merges.count)"])
        identitySync.push(PlaceIdentitySnapshot(names: names, merges: merges))
    }

    private func pullPlaceIdentityFromCloud() async {
        guard !TimelineLaunch.isUITesting else { return }
        guard !isApplyingCloudIdentity else { return }
        isApplyingCloudIdentity = true
        defer { isApplyingCloudIdentity = false }

        TimelineLog.publishIntakeForPeersIfNeeded()
        TimelineLog.refreshConfiguration()
        identitySync.synchronize()
        let remote = identitySync.pull()
        TimelineLog.info(
            "place-identity store pull",
            ["names": "\(remote.names.count)", "merges": "\(remote.merges.count)"]
        )
        var mergesChanged = false
        var namesApplied = 0
        var mergesApplied = 0

        for (key, record) in remote.names {
            if let changed = try? await database.applyPlaceNameIfNewer(
                placeKey: key,
                name: record.name,
                updatedAt: record.updatedAt
            ), changed {
                namesApplied += 1
            }
        }
        for (fromKey, record) in remote.merges {
            let semantic = placesByID[record.toKey]?.semanticType
            if let changed = try? await database.applyPlaceMergeIfNewer(
                from: fromKey,
                into: record.toKey,
                updatedAt: record.updatedAt,
                targetSemantic: semantic
            ), changed {
                mergesChanged = true
                mergesApplied += 1
            }
        }

        TimelineLog.info(
            "place-identity store applied",
            ["namesApplied": "\(namesApplied)", "mergesApplied": "\(mergesApplied)"]
        )

        await refreshPlaceNames()
        placeNameGeneration &+= 1

        if mergesChanged, let batch = try? await database.loadBatch() {
            let name = (try? await database.latestSourceName()) ?? sourceName ?? "Library"
            let keepPlaceID = selectedPlaceID
            let keepDayID = selectedDayID
            let keepTab = tab
            apply(TimelineParser.assemble(batch, sourceName: name))
            tab = keepTab
            if keepTab == .places, let id = keepPlaceID, let place = placesByID[id] {
                select(place: place)
            } else if keepTab == .dates, let id = keepDayID, let day = daysByID[id] {
                select(day: day)
            }
        }

        // Upload the merged local+remote snapshot so peers converge.
        let names = (try? await database.loadPlaceNameRecords()) ?? [:]
        let merges = (try? await database.loadPlaceMergeRecords()) ?? [:]
        identitySync.push(PlaceIdentitySnapshot(names: names, merges: merges))
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
        // Keep selectedPlaceID so returning to Places restores the last place.
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
        // Keep selectedDayID so returning to Dates restores the last day.
        mapRevealGeneration &+= 1
        focus(place: place)
    }

    /// Day shown on the map / legend for the Dates tab (nil while browsing Places).
    var activeDay: DayRecord? {
        tab == .dates ? selectedDay : nil
    }

    /// Place shown on the map / legend for the Places tab (nil while browsing Dates).
    var activePlace: PlaceRecord? {
        tab == .places ? selectedPlace : nil
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
        guard tab == .dates, snappedDayID == selectedDayID else { return [] }
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
