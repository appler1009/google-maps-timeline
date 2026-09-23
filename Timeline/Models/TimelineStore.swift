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
    /// False until the library has actually been read. The empty-library prompt
    /// is a claim that there is nothing here, and it should not be made while we
    /// are still finding out.
    private(set) var hasCheckedLibrary = false
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
    /// Opening straight onto today's map is a launch behaviour, not something to
    /// redo every time a merge or a recorded stay reloads the library.
    private var hasOpenedOnLaunch = false
    private(set) var monthGroups: [(month: Date, days: [DayRecord])] = []
    /// Which days the Dates list holds, as one value. The macOS sidebar list
    /// failed to draw a day inserted at the top of a month it already showed —
    /// today arrived, was selected and put on the map, and its row never
    /// appeared — so the list is rebuilt whenever this changes.
    private(set) var dateListIdentity = 0
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

    /// Marks the library as read without loading anything — for launches that
    /// deliberately skip the loaders, so the sidebar can settle on an answer.
    func markLibraryChecked() {
        hasCheckedLibrary = true
    }

    func loadBundledFixture() {
        guard let url = Bundle.main.url(forResource: "eiffel-tower-day", withExtension: "json") else {
            loadError = "Missing bundled test fixture."
            hasCheckedLibrary = true
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
    /// Every place can at least be given its real location, so every place has
    /// a menu. Home and Work cannot be renamed, which used to hide the menu from
    /// them entirely.
    func showsPlaceActions(_ place: PlaceRecord) -> Bool {
        true
    }

    /// Tell listeners the library on disk changed. Cloud sync enqueues uploads
    /// from this; the sidebar reloads from it. A local write that only refreshes
    /// the store leaves the change log sitting until the next recorded stay.
    private func noteLibraryChanged() {
        NotificationCenter.default.post(name: .timelineLibraryChanged, object: nil)
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
            noteLibraryChanged()
            await pushPlaceIdentityToCloud()
        }
    }

    /// Put a place where it really is.
    ///
    /// Google ships one coordinate per Place ID and it is sometimes the wrong end
    /// of the block; a recorded stay sits wherever the fix landed. Neither is
    /// something the user can argue with today, so this overrides both.
    func setPlaceLocation(_ placeID: String, to coordinate: CLLocationCoordinate2D) {
        isLoading = true
        Task {
            do {
                try await database.setPlaceLocation(placeKey: placeID, coordinate: coordinate)
                TimelineLog.info(
                    "place location corrected",
                    ["placeKey": placeID, "lat": String(format: "%.5f", coordinate.latitude)]
                )
            } catch {
                loadError = error.localizedDescription
                TimelineLog.error("place location failed", ["error": error.localizedDescription])
            }
            isLoading = false
            noteLibraryChanged()
            refreshFromLibrary()
        }
    }

    /// Put it back where the data said it was.
    func clearPlaceLocation(_ placeID: String) {
        isLoading = true
        Task {
            do {
                try await database.clearPlaceLocation(placeKey: placeID)
            } catch {
                loadError = error.localizedDescription
                TimelineLog.error("place location reset failed", ["error": error.localizedDescription])
            }
            isLoading = false
            noteLibraryChanged()
            refreshFromLibrary()
        }
    }

    /// True when this place has been moved by hand, so the menu can offer to undo it.
    func hasCorrectedLocation(_ placeID: String) -> Bool {
        correctedLocations.contains(placeID)
    }

    private var correctedLocations: Set<String> = []
    /// Where each place is, from the place rows themselves.
    private var placeCoordinates: [String: CLLocationCoordinate2D] = [:]

    func refreshCorrectedLocations() async {
        correctedLocations = Set((try? await database.loadPlaceLocations().keys).map(Array.init) ?? [])
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
            noteLibraryChanged()
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
    ///
    /// Read from where the stays say they came from, rather than from the alias
    /// table — a merge moves stays now, and the alias survives only for devices
    /// still on the old sync format.
    func sourcesMerged(into placeID: String) -> [(id: String, title: String)] {
        mergedOrigins[placeID, default: []]
            .map { (id: $0, title: mergeSourceTitle($0)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Cached per place, refreshed with the rest of the place identity.
    private var mergedOrigins: [String: [String]] = [:]

    /// Split `sourceID` back out of whatever it was merged into.
    func unmergePlace(from sourceID: String) {
        guard placeMerges[sourceID] != nil else { return }
        isLoading = true
        Task {
            try? await database.unmergePlace(from: sourceID)
            await refreshPlaceIdentity()
            await pushPlaceIdentityToCloud()
            noteLibraryChanged()
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

    /// Where each visible place is, so a pin goes to the place rather than to
    /// whichever fix happened to be recorded there.
    ///
    /// From the place rows, not from the day's stays. A `PlaceRecord` takes its
    /// coordinate from the most recent stay at that place, which for a music
    /// school visited twice was the evening fix that landed two hundred metres
    /// west — so consolidating the pins onto that put the single pin somewhere
    /// worse than either of the two it replaced.
    func mapAnnotationCoordinates() -> [String: CLLocationCoordinate2D] {
        var coordinates = placeCoordinates
        // Anything with no row yet keeps the old behaviour rather than no pin.
        for place in parsed?.places ?? [] where coordinates[place.id] == nil {
            guard let coordinate = place.coordinate else { continue }
            coordinates[place.id] = coordinate
        }
        return coordinates
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
            // Every exit path has to settle `hasCheckedLibrary`, or the sidebar
            // sits on a spinner forever.
            defer { hasCheckedLibrary = true }
            if isLoading { return }
            await refreshPlaceNames()
            await pullPlaceIdentityFromCloud()
            // A stay that ends before it starts is never legitimate, and one
            // already written would otherwise keep coming back from the server.
            if let purged = try? await database.purgeInvalidVisits(), purged > 0 {
                TimelineLog.info("invalid stays removed", ["count": "\(purged)"])
            }
            if let collapsed = try? await database.collapseDuplicateVisits(), collapsed > 0 {
                TimelineLog.info("duplicate stays collapsed", ["count": "\(collapsed)"])
            }
            if let migrated = try? await database.migrateToPlaceEntities(), migrated.visitsLinked > 0 {
                TimelineLog.info(
                    "places migrated",
                    ["places": "\(migrated.placesCreated)", "stays": "\(migrated.visitsLinked)"]
                )
            }
            if let merged = try? await database.collapseDuplicateStays(), merged > 0 {
                TimelineLog.info("same stay under two places collapsed", ["count": "\(merged)"])
            }
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
                let (batch, report) = try await Task.detached {
                    var report = TimelineParser.ImportReport()
                    let batch = try TimelineParser.extract(data, report: &report)
                    return (batch, report)
                }.value
                // Logged rather than held: nothing reads it back yet, and an
                // unread property is a promise the app has not made.
                TimelineLog.info("timeline imported", [
                    "file": name,
                    "summary": report.summary,
                    "unrecognised": "\(report.unrecognised)",
                    "undatable": "\(report.undatable)"
                ])
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
                hasCheckedLibrary = true
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
    ///
    /// Do not gate on `isLoading`. A cloud fetch that lands while a local write
    /// still has the flag set used to return here and never come back, so the
    /// Mac kept yesterday's sidebar for hours after today was already on disk.
    func refreshFromLibrary() {
        reloadWanted = true
        guard reloadTask == nil else { return }
        reloadTask = Task { await drainLibraryReloads() }
    }

    /// Reassemble only when the library on disk has a day newer than the
    /// sidebar. Used on battery / Low Power Mode where a full redraw every five
    /// minutes is not worth it, but sitting on yesterday after today's rows
    /// already landed still is.
    func reloadFromLibraryIfBehind(now: Date = Date()) async {
        let moment = now
        let diskDay = try? await database.newestDayStart(now: moment)
        let shown = parsed?.days.first?.day
        if let diskDay, shown == nil || diskDay > shown! {
            TimelineLog.info(
                "sidebar behind library",
                [
                    "disk": ISO8601DateFormatter().string(from: diskDay),
                    "shown": shown.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
                ]
            )
            await reloadFromLibrary(now: moment)
            return
        }
        refreshIfStale(now: moment)
    }

    /// The body of `refreshFromLibrary`, awaitable so a test can see it land.
    ///
    /// The day the user is looking at stays selected. `apply` frames the newest
    /// day on the Mac, which is right for opening a library and wrong for every
    /// reload after it: the selection came back but the map did not, and the
    /// day's routes were dropped for a day nobody was looking at. When that
    /// day's own pins change — a stay arriving from the other device — the
    /// framing is refit so the new stay is not left off the edge of a camera
    /// that was right before it arrived.
    ///
    /// One at a time. Waking the app asks both the clock and iCloud for a
    /// reload, and two reading side by side finish in whatever order they
    /// finish — so the one that read before the sync could land last and put
    /// the rows that just arrived back out of sight. A reload asked for while
    /// one is under way is folded into it: that one reads again rather than
    /// showing what it read before the write.
    func reloadFromLibrary(now: Date? = nil) async {
        reloadWanted = true
        while reloadWanted || reloadTask != nil {
            if reloadTask == nil {
                reloadTask = Task { await drainLibraryReloads(now: now) }
            }
            await reloadTask?.value
            if !reloadWanted { return }
        }
    }

    /// Drain every folded reload request. The previous boolean gate could leave
    /// `reloadAgain` set after an early return (empty read / error) with no
    /// worker left to honour it — the Mac then kept yesterday's sidebar until
    /// relaunch even though refresh kept being asked for.
    private func drainLibraryReloads(now: Date? = nil) async {
        defer { reloadTask = nil }
        while reloadWanted {
            reloadWanted = false
            let moment = now ?? Date()
            let batch: TimelineBatch
            do {
                guard let loaded = try await database.loadBatch(
                    includingShadowed: showsShadowedImports,
                    now: moment
                ) else {
                    continue
                }
                batch = loaded
            } catch {
                TimelineLog.error("library reload failed", ["error": error.localizedDescription])
                continue
            }
            await refreshPlaceIdentity()
            let name = (try? await database.latestSourceName()) ?? sourceName ?? "This device"
            // Another ask landed while we read — fold it into a fresh pass so
            // we never paint a snapshot taken before the write.
            if reloadWanted { continue }
            let timeline = TimelineParser.assemble(batch, sourceName: name, now: moment)
            layOut(timeline, at: moment)
            if let newest = timeline.days.first?.day {
                TimelineLog.info(
                    "library relaid",
                    ["newest": ISO8601DateFormatter().string(from: newest), "days": "\(timeline.days.count)"]
                )
            }
        }
    }

    private var reloadWanted = false
    private var reloadTask: Task<Void, Never>?

    private func layOut(_ timeline: ParsedTimeline, at moment: Date) {
        let keptDay = selectedDayID
        let keptPlace = selectedPlaceID
        let keptVisit = selectedVisitID
        let keptTab = tab
        let keptYear = filterYear
        let keptMonth = filterMonth
        let keptSearch = search
        let previousDay = selectedDay
        // Whether the day on screen was the newest the library had. Someone
        // parked there is watching the front of the timeline, not a day they
        // navigated back to.
        let wasAtFront = keptDay != nil && keptDay == parsed?.days.first?.day
        let previousRoutes = (day: snappedDayID, hops: snappedRoutes, cached: keptDay.flatMap { routesByDay[$0] })
        let isFirstLoad = parsed == nil
        apply(timeline, reframing: isFirstLoad)
        laidOutAt = moment
        tab = keptTab
        search = keptSearch
        filterYear = keptYear
        filterMonth = keptMonth
        clampDateFilters()
        if let keptDay, daysByID[keptDay] != nil {
            selectedDayID = keptDay
            #if os(macOS)
            // Midnight, or a stay from the phone opening a day newer than the
            // one on screen. Watching the front of the timeline means being
            // carried forward to it: a Mac left open since yesterday held on to
            // yesterday, and showed no today until someone clicked one. A day
            // navigated back to is nobody's to move, and neither is the Places
            // tab's camera, which is on a place rather than a day. The filters
            // come along, or the sidebar would list a month without it.
            if wasAtFront, tab == .dates, let newest = parsed?.days.first, newest.day > keptDay {
                filterYear = Calendar.current.component(.year, from: newest.day)
                filterMonth = 0
                rebuildDateIndexes()
                select(day: newest)
            }
            #endif
        } else if !isFirstLoad, keptDay != nil {
            // The day went away — its last stay was deleted or moved.
            #if os(macOS)
            if let newest = parsed?.days.first { select(day: newest) }
            #else
            selectedDayID = nil
            #endif
        }
        if let keptPlace, placesByID[keptPlace] != nil {
            selectedPlaceID = keptPlace
        }
        guard !isFirstLoad, let day = selectedDay else { return }
        if let keptVisit, day.visits.contains(where: { $0.id == keptVisit }) {
            selectedVisitID = keptVisit
        }
        guard let previousDay, previousDay.day == day.day else {
            requestRoutes(for: day)
            return
        }
        // A stay growing longer moves no pin and no route, and redrawing them
        // anyway fades the day's lines out and back every few minutes.
        if Self.hopSignature(previousDay) == Self.hopSignature(day) {
            if let cached = previousRoutes.cached { routesByDay[day.day] = cached }
            snappedRoutes = previousRoutes.hops
            snappedDayID = previousRoutes.day
        } else {
            requestRoutes(for: day)
        }
        if Self.pinSignature(previousDay) != Self.pinSignature(day) {
            dayContentGeneration &+= 1
            // New pins change how much ground the day covers. The rebuild
            // already draws them; refit so a stay from the other phone is not
            // left off a framing that was right before it arrived. Leave the
            // Places tab alone — its camera is on a place, not this day.
            if tab == .dates {
                focus(day: day)
            }
        }
    }

    /// Bumped when a reload changes the pins of the day already on screen —
    /// a stay arriving from the other device, or midnight handing the day a
    /// new one. The map rebuilds on a change of day, and this is the same day.
    /// The framing is refit in the same breath when Dates is showing.
    private(set) var dayContentGeneration: UInt64 = 0

    /// What the day's pins are drawn from: which places, where, in what order.
    /// Not how long anyone stayed, which is what changes while a stay runs.
    private static func pinSignature(_ day: DayRecord) -> [String] {
        day.visits.map { visit in
            let where_ = visit.coordinate.map { "\($0.latitude),\($0.longitude)" } ?? "-"
            return "\(visit.id)|\(visit.placeKey)|\(where_)|\(visit.semanticType ?? "")"
        }
    }

    private static func hopSignature(_ day: DayRecord) -> [String] {
        RoutePlanner.plannedHops(for: day).map { hop in
            let line = hop.points.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
            return "\(hop.id)|\(hop.kind)|\(hop.at.timeIntervalSince1970)|\(hop.until.timeIntervalSince1970)|\(line)"
        }
    }

    /// When the days on screen were laid out. A stay still in progress is drawn
    /// up to this moment and no further, so the picture ages while the app sits
    /// open — and across midnight it loses the whole of today.
    private(set) var laidOutAt: Date?

    /// Whether what is on screen has fallen behind the clock.
    ///
    /// Only a stay still going on changes with time alone; everything else
    /// changes when something is written, and that already reloads. So a
    /// library with nothing open is never stale, and one with a stay open is
    /// stale once it has grown by `openStayRefreshInterval` or crossed into a
    /// day it has not been laid out on.
    ///
    /// Until the stay stops growing. Past `longestOpenStay` the library no
    /// longer extends it — the departure was missed — so the clock has nothing
    /// left to add, and reassembling every few minutes would change nothing.
    func isStale(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let laidOutAt, let growsUntil = openStayGrowsUntil else { return false }
        let reach = min(now, growsUntil)
        guard reach > laidOutAt else { return false }
        if !calendar.isDate(laidOutAt, inSameDayAs: reach) { return true }
        return reach.timeIntervalSince(laidOutAt) >= Self.openStayRefreshInterval
    }

    /// How far a stay in progress may fall behind before it is redrawn. Its
    /// length is shown in minutes, so this is about how long the number may
    /// sit wrong — not a sync interval, because nothing is fetched.
    static let openStayRefreshInterval: TimeInterval = 5 * 60

    var hasOpenStay: Bool { openStayGrowsUntil != nil }

    /// When the stay in progress stops being stretched to the present, or nil
    /// when nothing is in progress.
    private(set) var openStayGrowsUntil: Date?

    /// Read off the days rather than the rows, so every path into `apply`
    /// agrees. A stay is sliced across the days it covers; its arrival is the
    /// earliest slice, and none reaches back further than the cap allows.
    private static func openStayGrowsUntil(in days: [DayRecord]) -> Date? {
        let recent = days.prefix(Int(TimelineDatabase.longestOpenStay / 86_400) + 2)
        let openIDs = Set(recent.flatMap { $0.visits.filter(\.isOpen).map(\.id) })
        guard !openIDs.isEmpty else { return nil }
        let arrival = recent
            .flatMap(\.visits)
            .filter { openIDs.contains($0.id) }
            .map(\.start)
            .min()
        return arrival?.addingTimeInterval(TimelineDatabase.longestOpenStay)
    }

    /// Reload if the clock has moved past what is on screen.
    func refreshIfStale(now: Date = Date()) {
        guard isStale(now: now) else { return }
        TimelineLog.info("open stay redrawn")
        Task { await reloadFromLibrary() }
    }

    /// Suggest when a stay at `coordinate` happened, from the movement recorded
    /// on `day`. The school run is the case: a two-minute stop CLVisit will never
    /// report, inside a drive that was recorded.
    func suggestedTiming(
        for coordinate: CLLocationCoordinate2D,
        on day: Date
    ) async -> VisitTimingGuesser.Guess {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let fixes = (try? await database.fixes(from: dayStart, to: dayEnd)) ?? []
        let midpoint = VisitTimingGuesser.largestGapMidpoint(
            between: daysByID[dayStart]?.visits ?? [],
            on: dayStart,
            calendar: calendar
        )
        return VisitTimingGuesser.guess(
            placeCoordinate: coordinate,
            fixes: fixes,
            paths: daysByID[dayStart]?.paths ?? [],
            fallbackMidpoint: midpoint
        )
    }

    /// Record a stay the user added by hand.
    ///
    /// Written as `manual`, which reconciliation never shadows: a stay someone
    /// took the trouble to enter outranks anything inferred or imported.
    func addVisit(
        name: String,
        coordinate: CLLocationCoordinate2D,
        start: Date,
        end: Date,
        mergingInto targetPlaceID: String? = nil
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeKey = targetPlaceID ?? Geo.placeKey(id: nil, coordinate: coordinate)
        let visit = TimelineVisit(
            id: Geo.segmentID("mv", Geo.millis(start), placeKey),
            start: start,
            end: max(end, start.addingTimeInterval(60)),
            coordinate: coordinate,
            semanticType: nil,
            placeKey: placeKey
        )
        isLoading = true
        Task {
            try? await database.record(
                batch: TimelineBatch(visits: [visit], activities: [], paths: []),
                source: .manual
            )
            if !trimmed.isEmpty, targetPlaceID == nil {
                try? await database.setPlaceName(placeKey: placeKey, name: trimmed)
                await pushPlaceIdentityToCloud()
            }
            await refreshPlaceIdentity()
            TimelineLog.info(
                "visit added by hand",
                ["placeKey": placeKey, "minutes": "\(Int(visit.duration / 60))"]
            )
            isLoading = false
            noteLibraryChanged()
            refreshFromLibrary()
        }
    }

    /// Move one stay to a different place, leaving every other stay where it is.
    func moveVisit(
        _ visitID: String,
        toPlaceNamed name: String,
        coordinate: CLLocationCoordinate2D?,
        existingPlaceID: String?
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeKey: String
        if let existingPlaceID {
            placeKey = existingPlaceID
        } else if let coordinate {
            placeKey = Geo.placeKey(id: nil, coordinate: coordinate)
        } else {
            return
        }
        isLoading = true
        Task {
            try? await database.moveVisit(id: visitID, toPlaceKey: placeKey)
            if existingPlaceID == nil, !trimmed.isEmpty {
                try? await database.setPlaceName(placeKey: placeKey, name: trimmed)
                await pushPlaceIdentityToCloud()
            }
            await refreshPlaceIdentity()
            TimelineLog.info("stay moved", ["visit": visitID, "placeKey": placeKey])
            isLoading = false
            noteLibraryChanged()
            refreshFromLibrary()
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
            noteLibraryChanged()
            refreshFromLibrary()
        }
    }

    func apply(_ parsed: ParsedTimeline, reframing: Bool = true) {
        self.parsed = parsed
        laidOutAt = Date()
        openStayGrowsUntil = Self.openStayGrowsUntil(in: parsed.days)
        hasCheckedLibrary = true
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
        guard reframing else { return }
        #if os(iOS)
        selectedDayID = nil
        openTodayIfLaunching()
        #else
        selectedDayID = parsed.days.first?.day
        if let day = parsed.days.first {
            focus(day: day)
            requestRoutes(for: day)
        }
        #endif
    }

    #if os(iOS)
    /// Open on today, so a tracking app shows what it recorded rather than a list
    /// of months. Falls back to the newest day there is — after a fresh import
    /// that is usually a day in the past, which is still more useful than nothing.
    private func openTodayIfLaunching() {
        // One decision per process, taken whether or not it opens anything. iOS
        // relaunches a tracking app in the background for every visit, and each
        // of those loads the library too — without consuming the chance here, a
        // stay recorded while the app was open would reveal the map underneath
        // whatever the user was actually looking at.
        guard !hasOpenedOnLaunch else { return }
        hasOpenedOnLaunch = true
        guard TimelineLaunch.opensOnToday else { return }
        // A launch the user cannot see is not a launch to open a map for.
        guard UIApplication.shared.applicationState != .background else { return }
        let today = Calendar.current.startOfDay(for: Date())
        guard let day = daysByID[today] ?? newestDay() else { return }
        // Match the filters to the day being shown, or the sidebar would come
        // back to a month that does not contain it.
        filterYear = Calendar.current.component(.year, from: day.day)
        filterMonth = 0
        rebuildDateIndexes()
        select(day: day)
    }

    private func newestDay() -> DayRecord? {
        daysByID.values.max { $0.day < $1.day }
    }
    #endif

    private func refreshPlaceIdentity() async {
        placeNames = (try? await database.loadPlaceNames()) ?? placeNames
        placeMerges = (try? await database.loadPlaceMerges()) ?? placeMerges
        mergedOrigins = (try? await database.mergedOriginsByPlace()) ?? mergedOrigins
        if let rows = try? await database.loadPlaces() {
            placeCoordinates = rows.compactMapValues(\.coordinate)
        }
        await refreshCorrectedLocations()
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

    /// Waits for the routes being fetched for the selected day, if any.
    func routesSettled() async {
        await routeTask?.value
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
        var hasher = Hasher()
        for group in groups {
            for day in group.days { hasher.combine(day.day) }
        }
        let identity = hasher.finalize()
        if identity != dateListIdentity { dateListIdentity = identity }
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
