import Foundation
import LuxShared
import Network
import Observation
import CoreLocation

struct LuxPairedSession: Codable, Sendable {
    var hostName: String
    var sessionToken: String
    var tlsFingerprint: String
    var deviceId: UUID
    /// Companion library ids Timeline should query for visit photos.
    var linkedLibraryIds: [String]
}

struct LuxVisitPhoto: Identifiable, Sendable {
    var id: String { "\(libraryId):\(item.id)" }
    let libraryId: String
    let libraryName: String
    let item: QueriedMediaItem
    var thumbnail: Data?

    /// Cross-library duplicate key when content hashes aren’t on the wire.
    var duplicateKey: String {
        let time = item.capturedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        let lat = item.latitude.map { String(format: "%.5f", $0) } ?? "?"
        let lon = item.longitude.map { String(format: "%.5f", $0) } ?? "?"
        let name = item.filename.lowercased()
        return "\(name)|\(time)|\(lat)|\(lon)"
    }
}

/// Links Timeline to a running Lux Companion and loads visit-matched photos.
@Observable
@MainActor
final class LuxPhotoLink {
    static let shared = LuxPhotoLink()

    let browser = LuxBonjourBrowser()

    private(set) var paired: LuxPairedSession?
    private(set) var libraries: [CompanionLibrary] = []
    private(set) var statusMessage: String = "Looking for Lux…"
    private(set) var isBusy = false
    private(set) var pendingPairingId: String?
    private(set) var pendingHost: LuxDiscoveredHost?
    var confirmationCode: String = ""

    /// Photos keyed by visit id for the current selection.
    private(set) var photosByVisitID: [String: [LuxVisitPhoto]] = [:]
    private(set) var isLoadingPhotos = false

    /// Window-level photo viewer (so outside-tap / Esc can dismiss).
    private(set) var viewerPhotos: [LuxVisitPhoto]?
    var viewerIndex: Int = 0

    private var client: LuxCompanionClient?
    private var photoTask: Task<Void, Never>?
    /// Instant reopen: last successful strip set per day + linked libraries.
    private var dayStripCache: [String: [String: [LuxVisitPhoto]]] = [:]
    private static let defaultsKey = "lux.paired.session"
    private static let dayStripDefaultsPrefix = "lux.dayStrip.v6."
    /// Query / assign radius — large enough for airports & campuses; exclusive nearest-visit keeps neighbors clean.
    private nonisolated static let defaultRadiusMeters: Double = 800
    private nonisolated static let assignRadiusMeters: Double = 800
    /// Pad stays so arrival/departure shots still attach (airports especially).
    private nonisolated static let timePadSeconds: TimeInterval = 30 * 60
    private nonisolated static let maxPhotosPerVisit = 24

    private init() {
        paired = Self.loadSession()
    }

    var isPaired: Bool { paired != nil }
    var isConnected: Bool { client != nil }
    var isViewerPresented: Bool { viewerPhotos != nil }

    func presentViewer(photos: [LuxVisitPhoto], index: Int) {
        guard !photos.isEmpty else { return }
        viewerIndex = min(max(index, 0), photos.count - 1)
        viewerPhotos = photos
    }

    func dismissViewer() {
        viewerPhotos = nil
        viewerIndex = 0
    }

    var linkedLibraries: [CompanionLibrary] {
        guard let paired else { return [] }
        let linked = Set(paired.linkedLibraryIds)
        return libraries.filter { linked.contains($0.id) }
    }

    func start() {
        browser.start()
        Task { await reconnectIfPossible() }
    }

    func stop() {
        browser.stop()
        photoTask?.cancel()
    }

    func reconnectIfPossible() async {
        guard let paired else {
            statusMessage = browser.discovered.isEmpty ? "Looking for Lux…" : "Select Lux to pair"
            return
        }
        guard let host = browser.discovered.first(where: { $0.name == paired.hostName })
                ?? browser.discovered.first
        else {
            statusMessage = "Waiting for Lux (\(paired.hostName))…"
            client = nil
            return
        }
        let next = LuxCompanionClient(
            endpoint: host.endpoint,
            sessionToken: paired.sessionToken,
            pinnedFingerprint: paired.tlsFingerprint
        )
        do {
            _ = try await next.fetchInfo()
            let libs = try await next.fetchLibraries()
            client = next
            libraries = libs
            TimelineLog.info("lux libraries loaded", [
                "count": "\(libs.count)",
                "detail": libs.map {
                    "\($0.displayName):protected=\($0.isProtected),unlocked=\($0.isUnlocked)"
                }.joined(separator: "; "),
            ])
            if paired.linkedLibraryIds.isEmpty, let first = libs.first {
                var updated = paired
                updated.linkedLibraryIds = [first.id]
                self.paired = updated
                Self.saveSession(updated)
            }
            // Drop linked ids that are no longer open.
            if var updated = self.paired {
                let open = Set(libs.map(\.id))
                let kept = updated.linkedLibraryIds.filter { open.contains($0) }
                if kept != updated.linkedLibraryIds {
                    updated.linkedLibraryIds = kept.isEmpty ? (libs.first.map { [$0.id] } ?? []) : kept
                    self.paired = updated
                    Self.saveSession(updated)
                }
            }
            statusMessage = "Connected to \(host.name)"
            TimelineLog.info("lux connected", ["host": host.name, "libraries": "\(libs.count)"])
        } catch {
            client = nil
            statusMessage = error.localizedDescription
            TimelineLog.warning("lux reconnect failed", ["error": error.localizedDescription])
        }
    }

    func beginPairing(with host: LuxDiscoveredHost) async {
        isBusy = true
        defer { isBusy = false }
        pendingHost = host
        confirmationCode = ""
        let deviceId = paired?.deviceId ?? UUID()
        let client = LuxCompanionClient(endpoint: host.endpoint, sessionToken: nil, pinnedFingerprint: nil)
        do {
            let started = try await client.pairBegin(deviceId: deviceId, deviceName: "Timeline")
            pendingPairingId = started.pairingId
            statusMessage = "Enter the code shown in Lux"
        } catch {
            pendingPairingId = nil
            statusMessage = error.localizedDescription
        }
    }

    func confirmPairing() async {
        guard let host = pendingHost, let pairingId = pendingPairingId else { return }
        isBusy = true
        defer { isBusy = false }
        let capture = LuxCompanionTLS.FingerprintBox()
        let client = LuxCompanionClient(endpoint: host.endpoint, sessionToken: nil, pinnedFingerprint: nil)
        do {
            let session = try await client.pairConfirm(
                pairingId: pairingId,
                code: confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines),
                observedFingerprint: capture
            )
            let fingerprint = capture.fingerprint ?? session.tlsFingerprint
            let deviceId = paired?.deviceId ?? UUID()
            let linked = [session.library.id]
            let saved = LuxPairedSession(
                hostName: host.name,
                sessionToken: session.sessionToken,
                tlsFingerprint: fingerprint,
                deviceId: deviceId,
                linkedLibraryIds: linked
            )
            paired = saved
            Self.saveSession(saved)
            pendingPairingId = nil
            pendingHost = nil
            confirmationCode = ""
            await reconnectIfPossible()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func unpair() {
        paired = nil
        client = nil
        libraries = []
        photosByVisitID = [:]
        Self.clearSession()
        statusMessage = "Unpaired"
    }

    func setLibraryLinked(_ libraryId: String, linked: Bool) {
        guard var paired else { return }
        if linked {
            if !paired.linkedLibraryIds.contains(libraryId) {
                paired.linkedLibraryIds.append(libraryId)
            }
        } else {
            paired.linkedLibraryIds.removeAll { $0 == libraryId }
        }
        self.paired = paired
        Self.saveSession(paired)
    }

    func refreshPhotos(for day: DayRecord?) {
        photoTask?.cancel()
        guard let day else {
            photosByVisitID = [:]
            return
        }
        let cacheKey = dayCacheKey(for: day)
        let canQuery = client != nil && !(paired?.linkedLibraryIds.isEmpty ?? true)

        // Always paint cache synchronously first — don’t wait on Lux.
        if let cached = dayStripCache[cacheKey] {
            let painted = Self.withSyncThumbnails(cached)
            photosByVisitID = painted
            dayStripCache[cacheKey] = painted
            if canQuery {
                photoTask = Task { await loadPhotos(for: day, cacheKey: cacheKey) }
            }
            return
        }

        if let refs = Self.loadDayStripRefs(cacheKey) {
            let painted = Self.withSyncThumbnails(Self.photos(from: refs))
            photosByVisitID = painted
            dayStripCache[cacheKey] = painted
            TimelineLog.info("lux day strip disk hit", ["day": cacheKey, "visits": "\(painted.count)"])
            if canQuery {
                photoTask = Task { await loadPhotos(for: day, cacheKey: cacheKey) }
            }
            return
        }

        if !canQuery {
            photosByVisitID = [:]
            return
        }
        photosByVisitID = [:]
        photoTask = Task { await loadPhotos(for: day, cacheKey: cacheKey) }
    }

    private func dayCacheKey(for day: DayRecord) -> String {
        let libs = (paired?.linkedLibraryIds ?? []).sorted().joined(separator: ",")
        // Stable integer seconds — avoids float formatting mismatches across launches.
        return "\(Int(day.day.timeIntervalSince1970))|\(libs)"
    }

    private nonisolated static func photos(
        from refs: [String: [LuxStripPhotoRef]]
    ) -> [String: [LuxVisitPhoto]] {
        var result: [String: [LuxVisitPhoto]] = [:]
        for (visitID, list) in refs {
            result[visitID] = list.map { ref in
                LuxVisitPhoto(
                    libraryId: ref.libraryId,
                    libraryName: ref.libraryName,
                    item: ref.item,
                    thumbnail: nil
                )
            }
        }
        return result
    }

    private nonisolated static func withSyncThumbnails(
        _ photosByVisit: [String: [LuxVisitPhoto]]
    ) -> [String: [LuxVisitPhoto]] {
        var keys: [String] = []
        for photos in photosByVisit.values {
            for photo in photos {
                keys.append(photo.id)
            }
        }
        let displays = LuxMediaCache.syncDisplayThumbnails(forKeys: keys)
        guard !displays.isEmpty else { return photosByVisit }

        var result: [String: [LuxVisitPhoto]] = [:]
        for (visitID, photos) in photosByVisit {
            var list = photos
            for index in list.indices {
                if let data = displays[list[index].id] {
                    list[index].thumbnail = data
                }
            }
            result[visitID] = list
        }
        return result
    }

    private func loadPhotos(for day: DayRecord, cacheKey: String) async {
        guard let client, let paired else { return }
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }

        let runs = PlaceVisitRun.coalesced(from: day.visits)
        let libraryIds = paired.linkedLibraryIds
        let libraryNames = Dictionary(uniqueKeysWithValues: libraries.map { ($0.id, $0.displayName) })

        struct RunQuery: Sendable {
            let visitIDs: [String]
            let start: Date
            let end: Date
            let coordinate: CLLocationCoordinate2D
        }

        var runQueries: [RunQuery] = []
        for run in runs {
            // Prefer the longest stay’s fix — first point is often an approach ping hundreds of metres out.
            guard let coordinate = Self.photoCoordinate(for: run) else { continue }
            let visit = run.representative
            let start = run.visits.map(\.start).min() ?? visit.start
            let end = run.visits.map(\.end).max() ?? visit.end
            runQueries.append(
                RunQuery(
                    visitIDs: run.visits.map(\.id),
                    start: start,
                    end: end,
                    coordinate: coordinate
                )
            )
        }

        // Query every place in parallel (keep-alive pool under the client).
        let runResults = await withTaskGroup(
            of: (index: Int, photos: [LuxVisitPhoto]).self
        ) { group in
            for (index, run) in runQueries.enumerated() {
                group.addTask {
                    let photos = await Self.queryPlacePhotos(
                        client: client,
                        libraryIds: libraryIds,
                        libraryNames: libraryNames,
                        coordinate: run.coordinate,
                        windowStart: run.start.addingTimeInterval(-Self.timePadSeconds),
                        windowEnd: run.end.addingTimeInterval(Self.timePadSeconds)
                    )
                    return (index, photos)
                }
            }
            var collected: [(index: Int, photos: [LuxVisitPhoto])] = []
            for await item in group {
                collected.append(item)
            }
            return collected.sorted { $0.index < $1.index }
        }

        guard !Task.isCancelled else { return }

        // One photo → one visit: nearest place whose stay window contains the capture time.
        var next = Self.assignPhotosExclusively(
            runResults: runResults,
            runs: runQueries.map {
                (
                    visitIDs: $0.visitIDs,
                    start: $0.start,
                    end: $0.end,
                    coordinate: $0.coordinate
                )
            }
        )

        // Attach any disk/memory thumbs we already have (sync — no actor wait on the hot path).
        next = Self.withSyncThumbnails(next)

        // Skip publishing if this background refresh matches what the user already sees.
        if !Self.samePhotoIDs(next, photosByVisitID) || !Self.sameThumbPresence(next, photosByVisitID) {
            photosByVisitID = next
            dayStripCache[cacheKey] = next
            Self.saveDayStripRefs(cacheKey, from: next)
        } else {
            dayStripCache[cacheKey] = next
            Self.saveDayStripRefs(cacheKey, from: next)
        }

        var missingThumbs: [(cacheKey: String, itemId: String, libraryId: String)] = []
        for photos in next.values {
            for photo in photos where photo.thumbnail == nil && photo.item.hasThumbnail {
                missingThumbs.append((photo.id, photo.item.id, photo.libraryId))
            }
        }
        guard !missingThumbs.isEmpty else { return }

        let fetched = await fetchThumbnails(missingThumbs, client: client)
        guard !Task.isCancelled else { return }

        for visitID in next.keys {
            guard var list = next[visitID] else { continue }
            var changed = false
            for index in list.indices {
                let key = list[index].id
                if list[index].thumbnail == nil, let data = fetched[key] {
                    list[index].thumbnail = data
                    changed = true
                }
            }
            if changed {
                next[visitID] = list
            }
        }
        photosByVisitID = next
        dayStripCache[cacheKey] = next
        Self.saveDayStripRefs(cacheKey, from: next)
    }

    /// Coordinate for Lux geo queries: longest segment, else duration-weighted centroid.
    private nonisolated static func photoCoordinate(for run: PlaceVisitRun) -> CLLocationCoordinate2D? {
        let weighted: [(CLLocationCoordinate2D, TimeInterval)] = run.visits.compactMap { visit in
            guard let coordinate = visit.coordinate else { return nil }
            return (coordinate, max(visit.duration, 1))
        }
        guard !weighted.isEmpty else { return nil }
        if let best = weighted.max(by: { $0.1 < $1.1 }) {
            // If the longest segment is clearly dominant, use it (avoids approach-ping bias).
            let total = weighted.reduce(0) { $0 + $1.1 }
            if best.1 >= total * 0.4 || weighted.count == 1 {
                return best.0
            }
        }
        var lat = 0.0
        var lon = 0.0
        var weight = 0.0
        for (coordinate, duration) in weighted {
            lat += coordinate.latitude * duration
            lon += coordinate.longitude * duration
            weight += duration
        }
        guard weight > 0 else { return weighted[0].0 }
        return CLLocationCoordinate2D(latitude: lat / weight, longitude: lon / weight)
    }

    /// Each unique photo is claimed by the closest visit whose time window fits.
    private nonisolated static func assignPhotosExclusively(
        runResults: [(index: Int, photos: [LuxVisitPhoto])],
        runs: [(visitIDs: [String], start: Date, end: Date, coordinate: CLLocationCoordinate2D)]
    ) -> [String: [LuxVisitPhoto]] {
        struct Claim {
            var photo: LuxVisitPhoto
            var runIndex: Int
            var distance: Double
            var duplicateKey: String
        }

        // Dedupe candidates across place queries first.
        var candidates: [String: LuxVisitPhoto] = [:]
        for result in runResults {
            for photo in result.photos {
                if let existing = candidates[photo.id] {
                    let existingDist = existing.item.distanceMeters ?? .greatestFiniteMagnitude
                    let nextDist = photo.item.distanceMeters ?? .greatestFiniteMagnitude
                    if nextDist + 0.5 < existingDist {
                        candidates[photo.id] = photo
                    }
                } else {
                    candidates[photo.id] = photo
                }
            }
        }

        var bestByPhotoID: [String: Claim] = [:]
        var bestByDuplicate: [String: Claim] = [:]

        for photo in candidates.values {
            let lat = photo.item.latitude
            let lon = photo.item.longitude
            let captured = photo.item.capturedAt

            for (runIndex, run) in runs.enumerated() {
                let distance: Double
                if let lat, let lon {
                    distance = haversineMeters(
                        lat1: run.coordinate.latitude,
                        lon1: run.coordinate.longitude,
                        lat2: lat,
                        lon2: lon
                    )
                } else if let reported = photo.item.distanceMeters, runResults.contains(where: {
                    $0.index == runIndex && $0.photos.contains(where: { $0.id == photo.id })
                }) {
                    // No GPS on item — only allow the run(s) that Lux returned it for.
                    distance = reported
                } else {
                    continue
                }
                guard distance <= assignRadiusMeters else { continue }

                var score = distance
                if let captured {
                    let padStart = run.start.addingTimeInterval(-timePadSeconds)
                    let padEnd = run.end.addingTimeInterval(timePadSeconds)
                    guard captured >= padStart, captured < padEnd else { continue }
                    let strict = captured >= run.start && captured < run.end
                    if !strict { score += 40 }
                } else {
                    // No capture time — only keep if this run’s query actually returned it.
                    guard runResults.contains(where: {
                        $0.index == runIndex && $0.photos.contains(where: { $0.id == photo.id })
                    }) else { continue }
                    score += 80
                }

                let claim = Claim(
                    photo: photo,
                    runIndex: runIndex,
                    distance: score,
                    duplicateKey: photo.duplicateKey
                )
                if let existing = bestByPhotoID[photo.id], existing.distance <= score {
                    // keep existing
                } else {
                    bestByPhotoID[photo.id] = claim
                }
                if let existing = bestByDuplicate[photo.duplicateKey], existing.distance <= score {
                    // keep existing
                } else {
                    bestByDuplicate[photo.duplicateKey] = claim
                }
            }
        }

        // Prefer duplicate-key winners (cross-library), keyed by photo id from that claim.
        var winners: [String: Claim] = [:]
        for claim in bestByDuplicate.values {
            winners[claim.photo.id] = claim
        }
        for (id, claim) in bestByPhotoID where winners[id] == nil {
            if winners.values.contains(where: { $0.duplicateKey == claim.duplicateKey }) {
                continue
            }
            winners[id] = claim
        }

        var next: [String: [LuxVisitPhoto]] = [:]
        for run in runs {
            for visitID in run.visitIDs {
                next[visitID] = []
            }
        }
        for claim in winners.values {
            let visitIDs = runs[claim.runIndex].visitIDs
            var list = next[visitIDs[0]] ?? []
            // Recompute display distance to the winning place for stable sorting.
            var photo = claim.photo
            if let lat = photo.item.latitude, let lon = photo.item.longitude {
                let run = runs[claim.runIndex]
                let meters = haversineMeters(
                    lat1: run.coordinate.latitude,
                    lon1: run.coordinate.longitude,
                    lat2: lat,
                    lon2: lon
                )
                photo = LuxVisitPhoto(
                    libraryId: photo.libraryId,
                    libraryName: photo.libraryName,
                    item: QueriedMediaItem(
                        id: photo.item.id,
                        filename: photo.item.filename,
                        capturedAt: photo.item.capturedAt,
                        mediaType: photo.item.mediaType,
                        latitude: photo.item.latitude,
                        longitude: photo.item.longitude,
                        distanceMeters: meters,
                        geocode: photo.item.geocode,
                        hasThumbnail: photo.item.hasThumbnail
                    ),
                    thumbnail: photo.thumbnail
                )
            }
            list.append(photo)
            list.sort {
                ($0.item.distanceMeters ?? .greatestFiniteMagnitude)
                    < ($1.item.distanceMeters ?? .greatestFiniteMagnitude)
            }
            if list.count > maxPhotosPerVisit {
                list = Array(list.prefix(maxPhotosPerVisit))
            }
            for visitID in visitIDs {
                next[visitID] = list
            }
        }
        return next
    }

    private nonisolated static func haversineMeters(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double
    ) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    private nonisolated static func samePhotoIDs(
        _ a: [String: [LuxVisitPhoto]],
        _ b: [String: [LuxVisitPhoto]]
    ) -> Bool {
        guard a.count == b.count else { return false }
        for (key, listA) in a {
            guard let listB = b[key], listA.count == listB.count else { return false }
            for i in listA.indices where listA[i].id != listB[i].id {
                return false
            }
        }
        return true
    }

    private nonisolated static func sameThumbPresence(
        _ a: [String: [LuxVisitPhoto]],
        _ b: [String: [LuxVisitPhoto]]
    ) -> Bool {
        guard a.count == b.count else { return false }
        for (key, listA) in a {
            guard let listB = b[key], listA.count == listB.count else { return false }
            for i in listA.indices {
                let aHas = listA[i].thumbnail != nil
                let bHas = listB[i].thumbnail != nil
                if aHas != bHas { return false }
            }
        }
        return true
    }

    /// Off-MainActor place query — only touches Lux + local media cache.
    private nonisolated static func queryPlacePhotos(
        client: LuxCompanionClient,
        libraryIds: [String],
        libraryNames: [String: String],
        coordinate: CLLocationCoordinate2D,
        windowStart: Date,
        windowEnd: Date
    ) async -> [LuxVisitPhoto] {
        var collected: [LuxVisitPhoto] = []
        var seenItemKeys = Set<String>()

        for libraryId in libraryIds {
            if Task.isCancelled { return collected }
            var cursor: String?
            repeat {
                let request = MediaQueryRequest(
                    start: windowStart,
                    end: max(windowEnd, windowStart.addingTimeInterval(1)),
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    radiusMeters: defaultRadiusMeters,
                    limit: maxPhotosPerVisit,
                    cursor: cursor,
                    mediaTypes: ["photo", "livePhoto", "rawPhoto"]
                )
                do {
                    let page = try await client.queryItems(libraryId: libraryId, request: request)
                    for item in page.items {
                        let itemKey = "\(libraryId):\(item.id)"
                        guard seenItemKeys.insert(itemKey).inserted else { continue }
                        let photo = LuxVisitPhoto(
                            libraryId: libraryId,
                            libraryName: libraryNames[libraryId] ?? libraryId,
                            item: item,
                            thumbnail: nil
                        )
                        if let existingIndex = collected.firstIndex(where: { $0.duplicateKey == photo.duplicateKey }) {
                            let existing = collected[existingIndex]
                            let existingDist = existing.item.distanceMeters ?? .greatestFiniteMagnitude
                            let nextDist = item.distanceMeters ?? .greatestFiniteMagnitude
                            if nextDist + 0.5 < existingDist {
                                collected[existingIndex] = photo
                            }
                            continue
                        }
                        collected.append(photo)
                        if collected.count >= maxPhotosPerVisit { break }
                    }
                    cursor = page.nextCursor
                    if collected.count >= maxPhotosPerVisit { cursor = nil }
                } catch {
                    TimelineLog.warning("lux query failed", [
                        "library": libraryId,
                        "error": error.localizedDescription,
                    ])
                    cursor = nil
                }
            } while cursor != nil
        }
        return collected
    }

    private func fetchThumbnails(
        _ pending: [(cacheKey: String, itemId: String, libraryId: String)],
        client: LuxCompanionClient
    ) async -> [String: Data] {
        var unique: [String: (itemId: String, libraryId: String)] = [:]
        for item in pending {
            if unique[item.cacheKey] == nil {
                unique[item.cacheKey] = (item.itemId, item.libraryId)
            }
        }
        return await withTaskGroup(of: (String, Data)?.self, returning: [String: Data].self) { group in
            for (key, ids) in unique {
                group.addTask {
                    if let preview = await LuxMediaCache.shared.displayThumbnail(forKey: key) {
                        return (key, preview)
                    }
                    guard let data = try? await client.fetchThumbnail(
                        itemId: ids.itemId,
                        libraryId: ids.libraryId
                    ) else { return nil }
                    await LuxMediaCache.shared.storeThumbnail(data, forKey: key)
                    return (key, data)
                }
            }
            var result: [String: Data] = [:]
            for await item in group {
                if let (key, data) = item {
                    result[key] = data
                }
            }
            return result
        }
    }

    func cachedOriginal(for photo: LuxVisitPhoto) async -> Data? {
        await LuxMediaCache.shared.original(forKey: photo.id)
    }

    func fetchOriginal(for photo: LuxVisitPhoto) async throws -> Data? {
        let key = photo.id
        if let cached = await LuxMediaCache.shared.original(forKey: key) {
            return cached
        }
        guard let client else { throw LuxCompanionError.notConnected }
        guard let data = try await client.fetchOriginal(itemId: photo.item.id, libraryId: photo.libraryId) else {
            return nil
        }
        await LuxMediaCache.shared.storeOriginal(data, forKey: key)
        if let preview = await LuxMediaCache.shared.preview(forKey: key) {
            applyThumbnail(preview, cacheKey: key)
        }
        return data
    }

    private func applyThumbnail(_ data: Data, cacheKey: String) {
        var updated = photosByVisitID
        var changed = false
        for (visitID, photos) in updated {
            var list = photos
            var listChanged = false
            for index in list.indices where list[index].id == cacheKey {
                if list[index].thumbnail == nil || (list[index].thumbnail?.count ?? 0) < data.count {
                    list[index].thumbnail = data
                    listChanged = true
                }
            }
            if listChanged {
                updated[visitID] = list
                changed = true
            }
        }
        if changed {
            photosByVisitID = updated
        }
    }

    private static func loadSession() -> LuxPairedSession? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LuxPairedSession.self, from: data)
    }

    private static func saveSession(_ session: LuxPairedSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func clearSession() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func loadDayStripRefs(_ cacheKey: String) -> [String: [LuxStripPhotoRef]]? {
        let key = dayStripDefaultsPrefix + cacheKey
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([String: [LuxStripPhotoRef]].self, from: data)
    }

    private static func saveDayStripRefs(_ cacheKey: String, from photos: [String: [LuxVisitPhoto]]) {
        let refs: [String: [LuxStripPhotoRef]] = photos.mapValues { list in
            list.map {
                LuxStripPhotoRef(libraryId: $0.libraryId, libraryName: $0.libraryName, item: $0.item)
            }
        }
        guard let data = try? JSONEncoder().encode(refs) else { return }
        UserDefaults.standard.set(data, forKey: dayStripDefaultsPrefix + cacheKey)
    }
}

/// Disk-friendly strip entry (thumbnails live in `LuxMediaCache`).
private struct LuxStripPhotoRef: Codable, Sendable {
    let libraryId: String
    let libraryName: String
    let item: QueriedMediaItem
}
