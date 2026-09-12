import Foundation
import CoreLocation
import SQLite3

enum TimelineDatabaseError: LocalizedError {
    case open
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open: return "Could not open the local timeline library."
        case .execute(let message): return message
        }
    }
}

actor TimelineDatabase {
    private var db: OpaquePointer?

    init(fileURL: URL? = nil) {
        let url: URL
        if let fileURL {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            url = fileURL
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Timeline", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent("library.sqlite")
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK || handle == nil {
            sqlite3_close(handle)
            handle = nil
            sqlite3_open_v2(":memory:", &handle, flags, nil)
        }
        db = handle
        try? Self.exec(handle, "PRAGMA journal_mode=WAL")
        try? Self.exec(handle, "PRAGMA foreign_keys=ON")
        try? Self.migrate(handle)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func isEmpty() throws -> Bool {
        try scalar("SELECT COUNT(*) FROM visits") == 0
            && scalar("SELECT COUNT(*) FROM activities") == 0
            && scalar("SELECT COUNT(*) FROM paths") == 0
    }

    func latestSourceName() throws -> String? {
        try string("SELECT source_name FROM imports ORDER BY imported_at DESC LIMIT 1")
    }

    func loadBatch(includingShadowed: Bool = false, now: Date = Date()) throws -> TimelineBatch? {
        // A library holding nothing but the stay you are currently inside is not
        // empty — that is exactly the first day of a fresh install.
        let open = try openStay(now: now)
        if open == nil, try isEmpty() { return nil }
        // Merges are materialised in place_id now, so nothing is resolved here.
        let locations = Self.resolved(try loadPlaceLocations(), merges: try loadPlaceMerges())
        var visits = try loadVisits(includingShadowed: includingShadowed)
            .map { Self.relocated($0, locations: locations) }
            .map { Self.extendedIfOpen($0, now: now) }
        // Older libraries kept the open stay only in open_visit, with no row
        // behind it. Read it from there until the next one opens as a row.
        if let open, !visits.contains(where: { $0.id == open.id }) {
            visits.append(Self.relocated(open, locations: locations))
        }
        return TimelineBatch(
            visits: visits,
            activities: try loadActivities(),
            paths: try loadPaths()
        )
    }

    /// How long an unclosed stay stays believable. Working from home for a week
    /// is ordinary; a month means the departure was missed, or the app has not
    /// run since, and drawing it is asserting something nobody witnessed.
    static let longestOpenStay: TimeInterval = 7 * 24 * 3_600

    /// A stay still going on runs up to the present, not up to the moment it
    /// began. The row is written once and left alone; this is where it grows.
    ///
    /// Capped, because an unclosed stay outlives its own credibility: past a
    /// week it means the departure was missed or the app has not run, and
    /// stretching it further asserts something nobody witnessed.
    private static func extendedIfOpen(_ visit: TimelineVisit, now: Date) -> TimelineVisit {
        guard visit.isOpen else { return visit }
        let cap = visit.start.addingTimeInterval(longestOpenStay)
        let end = max(visit.end, min(now, cap))
        guard end > visit.end else { return visit }
        return TimelineVisit(
            id: visit.id,
            start: visit.start,
            end: end,
            coordinate: visit.coordinate,
            semanticType: visit.semanticType,
            placeKey: visit.placeKey,
            isDerived: visit.isDerived,
            isOpen: true
        )
    }

    /// The in-progress stay as a visit ending now, or nil when there isn't one.
    ///
    /// Refused when the arrival is not a time anybody saw. Core Location reports
    /// an arrival it missed as `.distantPast` — it knows you are somewhere but
    /// not since when — and `open_visit` does not carry the flag that says so,
    /// only the timestamp, so the timestamp is what has to be judged.
    func openStay(now: Date = Date()) throws -> TimelineVisit? {
        guard let open = try openStop() else { return nil }
        guard !open.placeKey.isEmpty else { return nil }
        let since = now.timeIntervalSince(open.stop.start)
        guard since >= 0, since <= Self.longestOpenStay else { return nil }
        return TimelineVisit(
            id: PlaceClusterer.visitID(placeKey: open.placeKey, start: open.stop.start),
            start: open.stop.start,
            end: now,
            coordinate: open.stop.coordinate,
            semanticType: nil,
            placeKey: open.placeKey,
            // No row behind it, so it cannot be edited or moved — the same
            // contract a gap-filled stay has.
            isDerived: true,
            isOpen: true
        )
    }

    func upsert(batch: TimelineBatch, sourceName: String) throws {
        guard let db else { throw TimelineDatabaseError.open }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec(
                """
                INSERT INTO imports (source_name, imported_at, visit_count, activity_count, path_count)
                VALUES (\(quote(sourceName)), \(Date().timeIntervalSince1970), \(batch.visits.count), \(batch.activities.count), \(batch.paths.count))
                """
            )
            try upsertVisits(batch.visits, db: db, source: .google)
            try upsertActivities(batch.activities, db: db, source: .google)
            try upsertPaths(batch.paths, db: db, source: .google)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// What the phone recorded. No `imports` row: this is not an import, and the
    /// sidebar's source name should keep naming the last export the user opened.
    func record(batch: TimelineBatch, source: RecordSource = .device) throws {
        guard let db else { throw TimelineDatabaseError.open }
        guard !batch.visits.isEmpty || !batch.activities.isEmpty || !batch.paths.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try upsertVisits(batch.visits, db: db, source: source)
            try upsertActivities(batch.activities, db: db, source: source)
            try upsertPaths(batch.paths, db: db, source: source)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Fold recorded days and imported days into one library.
    ///
    /// Runs after every import and once a day in the background — not on every
    /// write, since it reads the whole visit table.
    @discardableResult
    func reconcileSources(calendar: Calendar = .current) throws -> ReconciliationPlan {
        let device = try loadVisits(source: .device)
        let imported = try loadVisits(source: .google)
        let plan = TimelineReconciler.plan(device: device, imported: imported, calendar: calendar)

        try setShadowed(plan.shadowedVisitIDs)
        let stamp = Date().timeIntervalSince1970
        for (from, to) in plan.placeAliases {
            let semantic = imported.first { $0.placeKey == to }?.semanticType
            _ = try applyPlaceMergeIfNewer(from: from, into: to, updatedAt: stamp, targetSemantic: semantic)
        }
        return plan
    }

    /// Exactly the given imported visits are hidden; everything else is shown, so
    /// a re-run after a device visit is deleted puts the import back.
    private func setShadowed(_ ids: Set<String>) throws {
        try exec("UPDATE visits SET shadowed = 0 WHERE shadowed = 1")
        guard !ids.isEmpty, let db else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "UPDATE visits SET shadowed = 1 WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, id, -1, Self.transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
        }
    }

    /// Stays this device recorded on or after `date`. Read from the library
    /// rather than counted in memory, so a background relaunch does not reset it.
    func recordedVisitCount(since date: Date) throws -> Int {
        try scalar(
            """
            SELECT COUNT(*) FROM visits
            WHERE source = '\(RecordSource.device.rawValue)' AND start >= \(date.timeIntervalSince1970)
            """
        )
    }

    /// Stays inside a window, for the naming context's routine and the trip that
    /// led here.
    func visits(from: Date, to: Date) throws -> [TimelineVisit] {
        try loadVisits(includingShadowed: false)
            .filter { $0.end >= from && $0.start <= to }
            .sorted { $0.start < $1.start }
    }

    /// Earlier stays at one place — the strongest evidence there is about what a
    /// place is, and usually empty, since we only ask about unnamed ones.
    func visits(placeKey: String, since: Date, limit: Int = 20) throws -> [TimelineVisit] {
        let merges = try loadPlaceMerges()
        return try loadVisits(includingShadowed: false)
            .map { Self.remapped($0, merges: merges) }
            .filter { $0.placeKey == placeKey && $0.start >= since }
            .sorted { $0.start > $1.start }
            .prefix(limit)
            .map { $0 }
    }

    /// Raw fixes on hand, for the diagnostics readout.
    func fixCount(since date: Date? = nil) throws -> Int {
        guard let date else { return try scalar("SELECT COUNT(*) FROM fixes") }
        return try scalar("SELECT COUNT(*) FROM fixes WHERE t >= \(date.timeIntervalSince1970)")
    }

    /// Which source each visit came from, for the rows about to be sent. The
    /// source is a property of the row, not of the device sending it — a stay
    /// added by hand stays manual wherever it lands.
    func visitSources(ids: [String]) throws -> [String: RecordSource] {
        guard let db, !ids.isEmpty else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id, source FROM visits", -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        let wanted = Set(ids)
        var found: [String: RecordSource] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), wanted.contains(id) else { continue }
            found[id] = RecordSource(rawValue: text(statement, 1) ?? "") ?? .device
        }
        return found
    }

    func shadowedVisitCount() throws -> Int {
        try scalar("SELECT COUNT(*) FROM visits WHERE shadowed = 1")
    }

    /// Remove stays that end before they start. Such a row is never legitimate —
    /// it came from an arrival that was guessed rather than observed — and it
    /// sorts into the wrong part of the day, making everything around it read as
    /// nonsense.
    ///
    /// The deletion is logged so it reaches the other devices too. Deleting only
    /// locally would leave the bad row on the server to be fetched straight back.
    @discardableResult
    func purgeInvalidVisits() throws -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // A stay still going on is written ending where it starts, and grows on
        // being read — so zero length is what it correctly looks like until you
        // leave. Purging it destroyed the row on the very launch that created
        // it, which made the whole thing invisible while appearing to work.
        guard sqlite3_prepare_v2(
            db,
            "SELECT id FROM visits WHERE end <= start AND is_open = 0",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return 0
        }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = text(statement, 0) { ids.append(id) }
        }
        guard !ids.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try exec("DELETE FROM visits WHERE id = \(quote(id))")
                try logChange(.visit, id, .delete)
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return ids.count
    }

    /// Collapse a stay that was imported more than once.
    ///
    /// A visit id hashes the start *and* the end, so an export taken while a stay
    /// was still running mints a new row every time the end grows — the same
    /// evening at home arriving as three overlapping rows with three ids. Keep the
    /// longest and drop the rest, within one source: deciding between sources is
    /// reconciliation's job, not this.
    @discardableResult
    func collapseDuplicateVisits() throws -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT id FROM visits WHERE id NOT IN (
                SELECT id FROM visits v WHERE end = (
                    SELECT MAX(end) FROM visits w
                    WHERE w.start = v.start AND w.place_key = v.place_key AND w.source = v.source
                )
                GROUP BY start, place_key, source
            )
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = text(statement, 0) { ids.append(id) }
        }
        guard !ids.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try exec("DELETE FROM visits WHERE id = \(quote(id))")
                try logChange(.visit, id, .delete)
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return ids.count
    }

    /// Re-attach one stay to a different place.
    ///
    /// Deliberately not a rename and not a merge: renaming would relabel every
    /// other stay at that place, and merging would fold the two places together
    /// for good. This is for the stay that simply landed on the wrong neighbour.
    /// A version of a stay that something replaced.
    struct VisitVersion: Sendable {
        /// What a stay is superseded by.
        enum Change: String, Sendable {
            case deleted
            case times
            case split
            case moved
        }

        var visit: TimelineVisit
        var changedAt: Date
        var change: Change
        var reason: String?
        var source: RecordSource
        /// True when the stay is not in the timeline at all any more.
        var isGone: Bool
    }

    /// Write down a stay as it stands, before something changes it.
    ///
    /// Called before every edit that would otherwise overwrite. A correction is
    /// usually right, but "usually" is the reason to keep what it replaced.
    private func rememberVisit(
        id: String,
        change: VisitVersion.Change,
        reason: String?,
        now: Date,
        db: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO visit_history
                (id, start, end, lat, lon, place_key, place_id, semantic_type, source, changed_at, change, reason)
            SELECT id, start, end, lat, lon, place_key, place_id, semantic_type, source, ?1, ?2, ?3
            FROM visits WHERE id = ?4
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, change.rawValue, -1, Self.transient)
        if let reason, !reason.isEmpty {
            sqlite3_bind_text(statement, 3, reason, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
    }

    /// Take a stay out of the timeline without destroying it.
    @discardableResult
    func deleteVisit(id: String, reason: String? = nil, now: Date = Date()) throws -> Bool {
        guard let db, !id.isEmpty else { return false }
        try exec("BEGIN IMMEDIATE")
        do {
            try rememberVisit(id: id, change: .deleted, reason: reason, now: now, db: db)
            try exec("DELETE FROM visits WHERE id = \(quote(id))")
            let removed = sqlite3_changes(db) > 0
            if removed { try logChange(.visit, id, .delete) }
            try exec("COMMIT")
            return removed
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Every superseded version, most recent first. Narrow to one stay with
    /// `id`, or to deletions alone.
    func visitHistory(id: String? = nil, onlyDeleted: Bool = false, limit: Int = 50) throws -> [VisitVersion] {
        guard let db else { return [] }
        var clauses: [String] = []
        if let id, !id.isEmpty { clauses.append("h.id = \(quote(id))") }
        if onlyDeleted { clauses.append("h.change = 'deleted'") }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT h.id, h.start, h.end, h.lat, h.lon, COALESCE(h.place_id, h.place_key),
                   h.semantic_type, h.changed_at, h.change, h.reason, h.source,
                   (SELECT COUNT(*) FROM visits v WHERE v.id = h.id)
            FROM visit_history h\(filter)
            ORDER BY h.changed_at DESC, h.seq DESC LIMIT ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(statement, 1, Int64(max(limit, 1)))
        var rows: [VisitVersion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rowID = text(statement, 0) else { continue }
            rows.append(
                VisitVersion(
                    visit: TimelineVisit(
                        id: rowID,
                        start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                        coordinate: coordinate(statement, lat: 3, lon: 4),
                        semanticType: text(statement, 6),
                        placeKey: text(statement, 5) ?? ""
                    ),
                    changedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                    change: VisitVersion.Change(rawValue: text(statement, 8) ?? "") ?? .deleted,
                    reason: text(statement, 9),
                    source: RecordSource(rawValue: text(statement, 10) ?? "") ?? .device,
                    isGone: sqlite3_column_int64(statement, 11) == 0
                )
            )
        }
        return rows
    }

    /// Put a stay back as it was before the last thing that changed it.
    ///
    /// The same move whether it was deleted or merely edited: the most recent
    /// superseded version becomes the current one again.
    @discardableResult
    func restoreVisit(id: String, now: Date = Date()) throws -> TimelineVisit? {
        guard let db, !id.isEmpty else { return nil }
        guard let version = try visitHistory(id: id, limit: 1).first else { return nil }
        // Restoring is itself a change, so what it replaces is kept too — undo
        // that can be undone.
        try? rememberVisit(id: id, change: .times, reason: "replaced by a restore", now: now, db: db)
        try record(batch: TimelineBatch(visits: [version.visit], activities: [], paths: []), source: version.source)
        try exec(
            """
            DELETE FROM visit_history
            WHERE seq = (SELECT seq FROM visit_history WHERE id = \(quote(id))
                         ORDER BY changed_at DESC, seq DESC LIMIT 1)
            """
        )
        return version.visit
    }

    /// Correct when a stay began and ended.
    @discardableResult
    func setVisitTimes(id: String, start: Date, end: Date, now: Date = Date()) throws -> Bool {
        guard let db, !id.isEmpty, end > start else { return false }
        try rememberVisit(id: id, change: .times, reason: nil, now: now, db: db)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE visits SET start = ?, end = ?, is_open = 0 WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TimelineDatabaseError.execute(errmsg()) }
        guard sqlite3_changes(db) > 0 else { return false }
        try logChange(.visit, id)
        return true
    }

    /// Cut one stay in two at a moment inside it.
    ///
    /// The first half keeps the row and its id, because it is still the stay
    /// that began when it began; the second half is a new stay at the same
    /// place. Used when a long stretch at home turns out to have had something
    /// in the middle of it.
    func splitVisit(id: String, at moment: Date, now: Date = Date()) throws -> TimelineVisit? {
        guard let db, !id.isEmpty else { return nil }
        let existing = try loadVisits().first { $0.id == id }
        guard let original = existing else { return nil }
        guard moment > original.start, moment < original.end else {
            return nil
        }
        let tail = TimelineVisit(
            id: Geo.segmentID("sv", Geo.millis(moment), original.placeKey),
            start: moment,
            end: original.end,
            coordinate: original.coordinate,
            semanticType: original.semanticType,
            placeKey: original.placeKey
        )
        try exec("BEGIN IMMEDIATE")
        do {
            try rememberVisit(id: id, change: .split, reason: nil, now: now, db: db)
            try exec(
                """
                UPDATE visits SET end = \(moment.timeIntervalSince1970), is_open = 0
                WHERE id = \(quote(id))
                """
            )
            try logChange(.visit, id)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        try record(batch: TimelineBatch(visits: [tail], activities: [], paths: []), source: .manual)
        return tail
    }

    /// Stays at one place in a window, for answering how often and how long.
    func visits(placeKey: String, from: Date, to: Date) throws -> [TimelineVisit] {
        guard let db, !placeKey.isEmpty else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT id, start, end, lat, lon, COALESCE(place_id, place_key), semantic_type, is_open
            FROM visits
            WHERE COALESCE(place_id, place_key) = ? AND start >= ? AND start < ?
            ORDER BY start
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [] }
        sqlite3_bind_text(statement, 1, placeKey, -1, Self.transient)
        sqlite3_bind_double(statement, 2, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, to.timeIntervalSince1970)
        var rows: [TimelineVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            rows.append(
                TimelineVisit(
                    id: id,
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    coordinate: coordinate(statement, lat: 3, lon: 4),
                    semanticType: text(statement, 6),
                    placeKey: text(statement, 5) ?? "",
                    isOpen: sqlite3_column_int64(statement, 7) == 1
                )
            )
        }
        return rows
    }

    func moveVisit(id: String, toPlaceKey placeKey: String) throws {
        guard let db, !id.isEmpty, !placeKey.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // place_id is what reads resolve through; place_key is kept in step only
        // so an older build reading the same file still sees the move.
        guard sqlite3_prepare_v2(
            db,
            "UPDATE visits SET place_id = ?1, place_key = ?1 WHERE id = ?2",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        sqlite3_bind_text(statement, 1, placeKey, -1, Self.transient)
        sqlite3_bind_text(statement, 2, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        try logChange(.visit, id)
    }

    /// Build the `places` rows and point every stay at one.
    ///
    /// Idempotent: it only acts on stays that have no place yet, so it can run on
    /// every launch until the library is fully migrated and then cost nothing.
    @discardableResult
    func migrateToPlaceEntities() throws -> PlaceEntityMigration.Result {
        guard let db else { return PlaceEntityMigration.Result() }
        let pending = try scalar("SELECT COUNT(*) FROM visits WHERE place_id IS NULL")
        guard pending > 0 else { return PlaceEntityMigration.Result() }

        let visitKeys = try allVisitPlaceKeys()
        let names = try loadPlaceNameRecords().filter { !$0.value.name.isEmpty }.mapValues(\.name)
        let locations = try loadPlaceLocations()
        let merges = try loadPlaceMerges()
        let semantics = try semanticTypesByPlaceKey()
        let averages = try averageCoordinatesByPlaceKey()

        let planned = PlaceEntityMigration.plan(
            visitKeys: visitKeys,
            names: names,
            locations: locations,
            merges: merges,
            semanticTypes: semantics,
            averageCoordinates: averages
        )
        let linkage = PlaceEntityMigration.linkage(for: planned)

        var result = PlaceEntityMigration.Result()
        result.placesCreated = planned.count
        result.mergesFolded = merges.count
        result.namesCarried = planned.filter { $0.name != nil }.count
        result.locationsCarried = locations.count

        try exec("BEGIN IMMEDIATE")
        do {
            for place in planned {
                try upsertPlaceRow(place, db: db)
            }
            var linked = 0
            for (key, placeID) in linkage {
                linked += try linkVisits(placeKey: key, to: placeID, db: db)
            }
            // Some imported segments carry no place at all. They are still stays,
            // and "every stay points at a place" has to stay true, so each gets
            // one of its own from where it happened.
            let orphans = try placelessVisits()
            for orphan in orphans {
                let placeID = orphan.coordinate.map { Geo.placeKey(id: nil, coordinate: $0) }
                    ?? "unplaced:\(orphan.id)"
                try upsertPlaceRow(
                    PlaceEntityMigration.PlannedPlace(
                        id: placeID,
                        name: nil,
                        coordinate: orphan.coordinate,
                        semanticType: nil,
                        keys: []
                    ),
                    db: db
                )
                linked += try linkVisit(id: orphan.id, to: placeID, db: db)
                result.placesCreated += 1
            }
            result.visitsLinked = linked
            // The legacy key still holds where each stay was before its merges
            // were folded into place ids, which is exactly the provenance
            // unmerging needs.
            try exec(
                """
                UPDATE visits SET origin_place_id = place_key
                WHERE origin_place_id IS NULL AND place_id IS NOT NULL AND place_id != place_key
                """
            )
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return result
    }

    private func upsertPlaceRow(_ place: PlaceEntityMigration.PlannedPlace, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO places (id, name, lat, lon, semantic_type, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = COALESCE(excluded.name, places.name),
                lat = COALESCE(excluded.lat, places.lat),
                lon = COALESCE(excluded.lon, places.lon),
                semantic_type = COALESCE(excluded.semantic_type, places.semantic_type)
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, place.id, -1, Self.transient)
        if let name = place.name {
            sqlite3_bind_text(statement, 2, name, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        bindCoord(statement, index: 3, coordinate: place.coordinate)
        if let semantic = place.semanticType {
            sqlite3_bind_text(statement, 5, semantic, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
    }

    /// Point stays at the place their key resolves to.
    ///
    /// When that resolution crosses a merge — the key folded into some other
    /// place — the stay is being moved, and a move has to remember where it came
    /// from or it can never be undone. Leaving that out is what made a merge
    /// received over sync permanently stuck: the stays landed on the survivor
    /// with no trail back.
    private func linkVisits(placeKey: String, to placeID: String, db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            UPDATE visits
            SET place_id = ?1,
                origin_place_id = CASE
                    WHEN ?1 IS NOT ?2 THEN COALESCE(origin_place_id, ?2)
                    ELSE origin_place_id
                END
            WHERE place_key = ?2 AND place_id IS NULL
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, placeID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, placeKey, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        return Int(sqlite3_changes(db))
    }

    /// Stays with no place key at all — Google sometimes exports a segment
    /// without one.
    private func placelessVisits() throws -> [(id: String, coordinate: CLLocationCoordinate2D?)] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, lat, lon FROM visits WHERE place_id IS NULL",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [] }
        var rows: [(id: String, coordinate: CLLocationCoordinate2D?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            rows.append((id, coordinate(statement, lat: 1, lon: 2)))
        }
        return rows
    }

    private func linkVisit(id: String, to placeID: String, db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE visits SET place_id = ? WHERE id = ? AND place_id IS NULL",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, placeID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        return Int(sqlite3_changes(db))
    }

    private func allVisitPlaceKeys() throws -> [String] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT place_key FROM visits", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let key = text(statement, 0) { keys.append(key) }
        }
        return keys
    }

    private func semanticTypesByPlaceKey() throws -> [String: String] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT place_key, semantic_type FROM visits
            WHERE semantic_type IS NOT NULL AND semantic_type NOT IN ('', 'Unknown', 'unknown')
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [:] }
        var found: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = text(statement, 0), let type = text(statement, 1) else { continue }
            // Home and Work outrank anything else said about the place.
            if found[key] == nil || type == "Home" || type == "Work" { found[key] = type }
        }
        return found
    }

    private func averageCoordinatesByPlaceKey() throws -> [String: CLLocationCoordinate2D] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT place_key, AVG(lat), AVG(lon) FROM visits
            WHERE lat IS NOT NULL AND lon IS NOT NULL
            GROUP BY place_key
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [:] }
        var found: [String: CLLocationCoordinate2D] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = text(statement, 0) else { continue }
            let coordinate = CLLocationCoordinate2D(
                latitude: sqlite3_column_double(statement, 1),
                longitude: sqlite3_column_double(statement, 2)
            )
            if CLLocationCoordinate2DIsValid(coordinate) { found[key] = coordinate }
        }
        return found
    }

    /// Collapse rows that describe one stay under two different places.
    ///
    /// A stay's id used to be hashed from its place, so re-clustering the same
    /// stop wrote a second row rather than updating the first. Same source, same
    /// minute in and out: one stay. The row whose place has a name survives,
    /// since that is the one the user has already reasoned about.
    @discardableResult
    func collapseDuplicateStays() throws -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT v.id, v.start, v.end, v.source,
                   CASE WHEN p.name IS NOT NULL AND p.name != '' THEN 1 ELSE 0 END AS named
            FROM visits v
            LEFT JOIN places p ON p.id = v.place_id
            WHERE (v.source, v.start, v.end) IN (
                SELECT source, start, end FROM visits
                GROUP BY source, start, end HAVING COUNT(*) > 1
            )
            ORDER BY v.start, named DESC, v.id
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }

        var keepByGroup: [String: String] = [:]
        var doomed: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let source = text(statement, 3) else { continue }
            let group = "\(source)|\(sqlite3_column_double(statement, 1))|\(sqlite3_column_double(statement, 2))"
            if keepByGroup[group] == nil {
                keepByGroup[group] = id
            } else {
                doomed.append(id)
            }
        }
        guard !doomed.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE")
        do {
            for id in doomed {
                try exec("DELETE FROM visits WHERE id = \(quote(id))")
                try logChange(.visit, id, .delete)
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return doomed.count
    }

    /// Everything a place knows about itself. One read, so the name and the
    /// location can never disagree about which place they describe.
    func loadPlaces() throws -> [String: PlaceEntity] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // The merge target rides along: a place syncs as one record, and what it
        // was folded into is part of what the place is.
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT p.id, p.name, p.lat, p.lon, p.semantic_type, p.updated_at, m.to_key
            FROM places p LEFT JOIN place_merges m ON m.from_key = p.id
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [:] }
        var found: [String: PlaceEntity] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            found[id] = PlaceEntity(
                id: id,
                name: text(statement, 1),
                coordinate: coordinate(statement, lat: 2, lon: 3),
                semanticType: text(statement, 4),
                mergedInto: text(statement, 6),
                updatedAt: sqlite3_column_double(statement, 5)
            )
        }
        return found
    }

    /// Keep the place row in step with a name or location edit, so reads that go
    /// through `places` see it immediately.
    private func syncPlaceRow(id: String, name: String? = nil, coordinate: CLLocationCoordinate2D? = nil) throws {
        guard let db, !id.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO places (id, name, lat, lon, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = COALESCE(excluded.name, places.name),
                lat = COALESCE(excluded.lat, places.lat),
                lon = COALESCE(excluded.lon, places.lon),
                updated_at = excluded.updated_at
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        if let name, !name.isEmpty {
            sqlite3_bind_text(statement, 2, name, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        bindCoord(statement, index: 3, coordinate: coordinate)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    /// Stays still carrying only an old-style key. Zero once migrated.
    func unlinkedVisitCount() throws -> Int {
        try scalar("SELECT COUNT(*) FROM visits WHERE place_id IS NULL")
    }

    /// Every place we could snap a new stay onto, with how often it was visited
    /// and whether it already carries a name worth not asking about again.
    func placeAnchors() throws -> [PlaceAnchor] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Grouped by the place a stay points at, not the key it was clustered
        // under. The two drift: place_key is where clustering put the stay at
        // the time, place_id is where it belongs now, and merging, unmerging and
        // moving a stay all change the second without touching the first.
        // Anchoring on the old column meant clustering kept answering with a
        // place the library had already stopped believing in.
        let sql = """
            SELECT COALESCE(v.place_id, v.place_key),
                   AVG(v.lat),
                   AVG(v.lon),
                   COUNT(*),
                   MAX(CASE
                       WHEN p.name IS NOT NULL AND p.name != '' THEN 1
                       WHEN v.semantic_type IS NOT NULL
                            AND v.semantic_type NOT IN ('', 'Unknown', 'unknown') THEN 1
                       ELSE 0
                   END)
            FROM visits v
            LEFT JOIN places p ON p.id = COALESCE(v.place_id, v.place_key)
            WHERE v.lat IS NOT NULL AND v.lon IS NOT NULL
            GROUP BY COALESCE(v.place_id, v.place_key)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        let locations = try loadPlaceLocations()
        var anchors: [String: PlaceAnchor] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = text(statement, 0), !key.isEmpty else { continue }
            let coordinate = CLLocationCoordinate2D(
                latitude: sqlite3_column_double(statement, 1),
                longitude: sqlite3_column_double(statement, 2)
            )
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let count = Int(sqlite3_column_int64(statement, 3))
            let named = sqlite3_column_int64(statement, 4) == 1
            if let existing = anchors[key] {
                anchors[key] = PlaceAnchor(
                    placeKey: key,
                    coordinate: existing.visitCount >= count ? existing.coordinate : coordinate,
                    visitCount: existing.visitCount + count,
                    isNamed: existing.isNamed || named
                )
            } else {
                anchors[key] = PlaceAnchor(
                    placeKey: key,
                    coordinate: coordinate,
                    visitCount: count,
                    isNamed: named
                )
            }
        }
        // Snap future stays to the corrected spot, not the one we were told.
        return anchors.values.map { anchor in
            guard let corrected = locations[anchor.placeKey] else { return anchor }
            return PlaceAnchor(
                placeKey: anchor.placeKey,
                coordinate: corrected.coordinate,
                visitCount: anchor.visitCount,
                isNamed: anchor.isNamed
            )
        }
    }

    // MARK: - Change tracking

    /// Set only for the duration of a remote apply. Every function that reaches it
    /// is synchronous, so there is no suspension point at which another caller
    /// could observe the wrong value.
    private var changeOrigin: ChangeOrigin = .local

    private func applyingRemotely<T>(_ body: () throws -> T) rethrows -> T {
        let previous = changeOrigin
        changeOrigin = .remote
        defer { changeOrigin = previous }
        return try body()
    }

    /// Note that a row needs sending. Callers run this inside the same transaction
    /// as the write wherever they have one; `setPlaceName` is a single statement
    /// with no transaction of its own, so a crash in the gap can lose an entry.
    /// `markEverythingPending()` is the recovery path for that.
    private func logChange(_ kind: ChangeKind, _ rowID: String, _ operation: ChangeOperation = .upsert) throws {
        guard changeOrigin == .local, let db, !rowID.isEmpty else { return }
        let seq = try nextChangeSeq()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO change_log (kind, row_id, op, seq, changed_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(kind, row_id) DO UPDATE SET
                op = excluded.op,
                seq = excluded.seq,
                changed_at = excluded.changed_at
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, Self.transient)
        sqlite3_bind_text(statement, 2, rowID, -1, Self.transient)
        sqlite3_bind_text(statement, 3, operation.rawValue, -1, Self.transient)
        sqlite3_bind_int64(statement, 4, seq)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
    }

    /// Never reuses a number, even after the log empties, so a stale acknowledgement
    /// can never match a newer entry.
    private func nextChangeSeq() throws -> Int64 {
        guard let db else { throw TimelineDatabaseError.open }
        try exec(
            """
            INSERT INTO sync_state (key, int_value) VALUES ('changeSeq', 1)
            ON CONFLICT(key) DO UPDATE SET int_value = sync_state.int_value + 1
            """
        )
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT int_value FROM sync_state WHERE key = 'changeSeq'", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        return sqlite3_column_int64(statement, 0)
    }

    func pendingChangeCount() throws -> Int {
        try scalar("SELECT COUNT(*) FROM change_log")
    }

    /// Oldest first, so a backlog drains in the order it happened.
    func pendingChanges(limit: Int = 200) throws -> [PendingChange] {
        guard let db, limit > 0 else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT kind, row_id, op, seq, changed_at FROM change_log ORDER BY seq LIMIT ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [PendingChange] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawKind = text(statement, 0), let kind = ChangeKind(rawValue: rawKind),
                  let rowID = text(statement, 1) else { continue }
            rows.append(
                PendingChange(
                    kind: kind,
                    rowID: rowID,
                    operation: ChangeOperation(rawValue: text(statement, 2) ?? "") ?? .upsert,
                    seq: sqlite3_column_int64(statement, 3),
                    changedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                )
            )
        }
        return rows
    }

    /// Pending changes together with the rows they point at.
    func changeBatch(limit: Int = 200) throws -> ChangeBatch {
        let changes = try pendingChanges(limit: limit)
        guard !changes.isEmpty else { return ChangeBatch() }
        var batch = ChangeBatch(changes: changes)

        func ids(_ kind: ChangeKind) -> Set<String> {
            Set(changes.filter { $0.kind == kind && $0.operation == .upsert }.map(\.rowID))
        }

        let visitIDs = ids(.visit)
        if !visitIDs.isEmpty {
            batch.visits = try loadVisits().filter { visitIDs.contains($0.id) }
            batch.visitSources = try visitSources(ids: Array(visitIDs))
        }
        let activityIDs = ids(.activity)
        if !activityIDs.isEmpty {
            batch.activities = try loadActivities().filter { activityIDs.contains($0.id) }
        }
        let pathIDs = ids(.path)
        if !pathIDs.isEmpty {
            batch.paths = try loadPaths().filter { pathIDs.contains($0.id) }
        }
        let nameKeys = ids(.placeName)
        if !nameKeys.isEmpty {
            batch.names = try loadPlaceNameRecords().filter { nameKeys.contains($0.key) }
        }
        let mergeKeys = ids(.placeMerge)
        if !mergeKeys.isEmpty {
            batch.merges = try loadPlaceMergeRecords().filter { mergeKeys.contains($0.key) }
        }
        let locationKeys = ids(.placeLocation)
        if !locationKeys.isEmpty {
            batch.locations = try loadPlaceLocations().filter { locationKeys.contains($0.key) }
        }
        let placeIDs = ids(.place)
        if !placeIDs.isEmpty {
            batch.places = try loadPlaces().filter { placeIDs.contains($0.key) }
        }
        return batch
    }

    /// Clear entries that have been sent. A row edited again after the batch was
    /// read has a higher seq by then, so it survives its own acknowledgement.
    func acknowledge(_ changes: [PendingChange]) throws {
        guard let db, !changes.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "DELETE FROM change_log WHERE kind = ? AND row_id = ? AND seq <= ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        for change in changes {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, change.kind.rawValue, -1, Self.transient)
            sqlite3_bind_text(statement, 2, change.rowID, -1, Self.transient)
            sqlite3_bind_int64(statement, 3, change.seq)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
        }
    }

    /// Queue the whole library. This is the first sync, and the repair for a log
    /// entry lost to a crash.
    @discardableResult
    func markEverythingPending() throws -> Int {
        guard let db else { throw TimelineDatabaseError.open }
        try exec("BEGIN IMMEDIATE")
        do {
            for visit in try loadVisits() { try logChange(.visit, visit.id) }
            for activity in try loadActivities() { try logChange(.activity, activity.id) }
            for path in try loadPaths() { try logChange(.path, path.id) }
            for id in try loadPlaces().keys { try logChange(.place, id) }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return try pendingChangeCount()
    }

    /// Drop the queue without sending it — for "stop syncing and forget".
    func clearChangeLog() throws {
        try exec("DELETE FROM change_log")
    }

    // MARK: - Sync state and remote writes

    /// Opaque per-engine state, such as CloudKit's serialized sync state. Losing
    /// it means the next launch re-syncs the world, so it lives in the library
    /// file rather than in UserDefaults.
    func syncStateData(_ key: String) throws -> Data? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT blob_value FROM sync_state WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return blob(statement, 0)
    }

    func setSyncStateData(_ key: String, _ data: Data?) throws {
        guard let db else { throw TimelineDatabaseError.open }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO sync_state (key, int_value, blob_value) VALUES (?, 0, ?)
            ON CONFLICT(key) DO UPDATE SET blob_value = excluded.blob_value
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        if let data {
            bindBlob(statement, 2, data)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
    }

    /// The system fields of the last record CloudKit acknowledged — its change
    /// tag above all. Saving without one is an *insert*, which the server refuses
    /// the moment the row already exists.
    func cloudRecordArchive(_ recordName: String) throws -> Data? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT archive FROM ck_records WHERE record_name = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, recordName, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return blob(statement, 0)
    }

    func cloudRecordArchives(_ names: [String]) throws -> [String: Data] {
        var found: [String: Data] = [:]
        for name in names {
            if let data = try cloudRecordArchive(name) { found[name] = data }
        }
        return found
    }

    /// Passing nil forgets the record, so the next save is a fresh insert.
    func setCloudRecordArchive(_ recordName: String, _ data: Data?) throws {
        guard let db else { throw TimelineDatabaseError.open }
        guard let data else {
            var delete: OpaquePointer?
            defer { sqlite3_finalize(delete) }
            guard sqlite3_prepare_v2(db, "DELETE FROM ck_records WHERE record_name = ?", -1, &delete, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(delete, 1, recordName, -1, Self.transient)
            sqlite3_step(delete)
            return
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO ck_records (record_name, archive, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(record_name) DO UPDATE SET archive = excluded.archive, updated_at = excluded.updated_at
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, recordName, -1, Self.transient)
        bindBlob(statement, 2, data)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
    }

    func cloudRecordArchiveCount() throws -> Int {
        try scalar("SELECT COUNT(*) FROM ck_records")
    }

    /// Forget every change tag — for a sign-out, or a deliberate fresh upload.
    func clearCloudRecordArchives() throws {
        try exec("DELETE FROM ck_records")
    }

    /// Rows that arrived from another device. Written exactly like local rows but
    /// without queueing themselves to be sent straight back.
    func applyRemote(_ batch: TimelineBatch, visitSources: [String: RecordSource] = [:]) throws {
        guard let db else { throw TimelineDatabaseError.open }
        guard !batch.visits.isEmpty || !batch.activities.isEmpty || !batch.paths.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try applyingRemotely {
                // A row keeps the source it was written with. Forcing `.device`
                // here stripped a hand-added stay of the protection that stops
                // reconciliation shadowing it.
                let grouped = Dictionary(grouping: batch.visits) { visitSources[$0.id] ?? .device }
                for (source, visits) in grouped {
                    try upsertVisits(visits, db: db, source: source)
                }
                try upsertActivities(batch.activities, db: db, source: .device)
                try upsertPaths(batch.paths, db: db, source: .device)
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// A row deleted on another device.
    func applyRemoteDeletion(kind: ChangeKind, rowID: String) throws {
        let table: String
        let column: String
        switch kind {
        case .visit: table = "visits"; column = "id"
        case .activity: table = "activities"; column = "id"
        case .path: table = "paths"; column = "id"
        case .place: table = "places"; column = "id"
        case .placeName: table = "place_names"; column = "place_key"
        case .placeMerge: table = "place_merges"; column = "from_key"
        case .placeLocation: table = "place_locations"; column = "place_key"
        }
        guard let db else { throw TimelineDatabaseError.open }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE \(column) = ?", -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        sqlite3_bind_text(statement, 1, rowID, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
    }

    // MARK: - Recorder state

    func openStop() throws -> OpenStop? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT start, lat, lon, h_accuracy, place_key FROM open_visit WHERE id = 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return nil }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return OpenStop(
            stop: CapturedStop(
                coordinate: CLLocationCoordinate2D(
                    latitude: sqlite3_column_double(statement, 1),
                    longitude: sqlite3_column_double(statement, 2)
                ),
                horizontalAccuracy: sqlite3_column_double(statement, 3),
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                end: nil
            ),
            placeKey: text(statement, 4) ?? ""
        )
    }

    func setOpenStop(_ stop: CapturedStop, placeKey: String) throws {
        guard let db else { throw TimelineDatabaseError.open }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO open_visit (id, start, lat, lon, h_accuracy, place_key)
            VALUES (1, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                start = excluded.start,
                lat = excluded.lat,
                lon = excluded.lon,
                h_accuracy = excluded.h_accuracy,
                place_key = excluded.place_key
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_double(statement, 1, stop.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, stop.coordinate.latitude)
        sqlite3_bind_double(statement, 3, stop.coordinate.longitude)
        sqlite3_bind_double(statement, 4, stop.horizontalAccuracy)
        sqlite3_bind_text(statement, 5, placeKey, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        // And as a row, so the stay exists for everything that reads the
        // library and travels to the other device. Core Location reports a
        // visit twice, and waiting for the second report meant a week working
        // from home was a week of empty days on the Mac, which has no recorder
        // of its own and no way to learn of a stay that had not ended.
        //
        // Written once, ending where it starts. Nothing rewrites it as the day
        // goes on — reading extends it to the present — so it costs one row and
        // one send however long the stay runs.
        guard stop.arrivalIsKnown else { return }
        let opened = TimelineVisit(
            id: PlaceClusterer.visitID(placeKey: placeKey, start: stop.start),
            start: stop.start,
            end: stop.start,
            coordinate: stop.coordinate,
            semanticType: nil,
            placeKey: placeKey,
            isOpen: true
        )
        try record(batch: TimelineBatch(visits: [opened], activities: [], paths: []))
    }

    /// Give the stay we are inside a row, if it has not got one.
    ///
    /// A stay becomes a row when Core Location reports the arrival. A stay that
    /// was already in flight when the app was replaced never gets that report —
    /// the arrival happened under the previous build — so it would sit in
    /// open_visit forever, invisible to the other device, until the next time
    /// you left and came back.
    @discardableResult
    func backfillOpenStayRow(now: Date = Date()) throws -> Bool {
        guard let open = try openStop(), open.stop.arrivalIsKnown, !open.placeKey.isEmpty else {
            return false
        }
        let since = now.timeIntervalSince(open.stop.start)
        guard since >= 0, since <= Self.longestOpenStay else { return false }
        let id = PlaceClusterer.visitID(placeKey: open.placeKey, start: open.stop.start)
        if try loadVisits().contains(where: { $0.id == id }) { return false }
        try record(
            batch: TimelineBatch(
                visits: [
                    TimelineVisit(
                        id: id,
                        start: open.stop.start,
                        end: open.stop.start,
                        coordinate: open.stop.coordinate,
                        semanticType: nil,
                        placeKey: open.placeKey,
                        isOpen: true
                    )
                ],
                activities: [],
                paths: []
            )
        )
        return true
    }

    func clearOpenStop() throws {
        try exec("DELETE FROM open_visit")
    }

    func captureMark(_ name: String) throws -> Date? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT through FROM capture_marks WHERE name = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, name, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    func setCaptureMark(_ name: String, through: Date) throws {
        guard let db else { throw TimelineDatabaseError.open }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO capture_marks (name, through) VALUES (?, ?)
            ON CONFLICT(name) DO UPDATE SET through = MAX(capture_marks.through, excluded.through)
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, name, -1, Self.transient)
        sqlite3_bind_double(statement, 2, through.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
    }

    func appendFixes(_ fixes: [CapturedFix]) throws {
        guard let db, !fixes.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO fixes (t, lat, lon, h_accuracy, speed) VALUES (?, ?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        for fix in fixes {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_double(statement, 1, fix.timestamp.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, fix.coordinate.latitude)
            sqlite3_bind_double(statement, 3, fix.coordinate.longitude)
            sqlite3_bind_double(statement, 4, fix.horizontalAccuracy)
            sqlite3_bind_double(statement, 5, fix.speed)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
        }
    }

    func fixes(from: Date, to: Date) throws -> [CapturedFix] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT t, lat, lon, h_accuracy, speed FROM fixes WHERE t >= ? AND t <= ? ORDER BY t",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        var rows: [CapturedFix] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let coordinate = CLLocationCoordinate2D(
                latitude: sqlite3_column_double(statement, 1),
                longitude: sqlite3_column_double(statement, 2)
            )
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            rows.append(
                CapturedFix(
                    coordinate: coordinate,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    horizontalAccuracy: sqlite3_column_double(statement, 3),
                    speed: sqlite3_column_double(statement, 4)
                )
            )
        }
        return rows
    }

    /// Raw fixes are scaffolding for the paths we already built; keep a week.
    func pruneFixes(before date: Date) throws {
        try exec("DELETE FROM fixes WHERE t < \(date.timeIntervalSince1970)")
    }

    func hop(key: String) throws -> [CLLocationCoordinate2D]? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT points FROM route_hops WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return CoordBlob.unpack(blob(statement, 0))
    }

    func saveHop(key: String, points: [CLLocationCoordinate2D]) throws {
        guard let db, points.count >= 2 else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO route_hops (key, points) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        bindBlob(statement, 2, CoordBlob.pack(points))
        sqlite3_step(statement)
    }

    /// A cached route, but only if it still runs between the same two points.
    ///
    /// A hop is identified by the stays it joins, and a stay keeps its id when
    /// its place is corrected — so the id alone cannot say whether the geometry
    /// is still right. Correcting a place used to leave every route into and out
    /// of it pointing at where the place used to be. The anchor is what the route
    /// was drawn between; when it no longer matches, the row is a miss.
    func pathRoute(id: String, anchor: String) throws -> [CLLocationCoordinate2D]? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT points, anchor FROM path_routes WHERE path_id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        // Rows written before anchors carry none; re-route them once.
        guard let stored = text(statement, 1), stored == anchor else { return nil }
        return CoordBlob.unpack(blob(statement, 0))
    }

    func savePathRoute(id: String, anchor: String, points: [CLLocationCoordinate2D]) throws {
        guard let db, points.count >= 2 else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO path_routes (path_id, anchor, points) VALUES (?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        sqlite3_bind_text(statement, 2, anchor, -1, Self.transient)
        bindBlob(statement, 3, CoordBlob.pack(points))
        sqlite3_step(statement)
    }

    func loadPlaceNames() throws -> [String: String] {
        try loadPlaceNameRecords()
            .filter { !$0.value.name.isEmpty }
            .mapValues(\.name)
    }

    func loadPlaceNameRecords() throws -> [String: PlaceIdentityName] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT place_key, name, updated_at FROM place_names",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        var names: [String: PlaceIdentityName] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = text(statement, 0), let name = text(statement, 1) else { continue }
            names[key] = PlaceIdentityName(name: name, updatedAt: sqlite3_column_double(statement, 2))
        }
        return names
    }

    /// Empty / whitespace `name` stores a tombstone so iCloud sync can clear other devices.
    func setPlaceName(placeKey: String, name: String, updatedAt: TimeInterval? = nil) throws {
        guard let db else { throw TimelineDatabaseError.open }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = updatedAt ?? Date().timeIntervalSince1970
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO place_names (place_key, name, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(place_key) DO UPDATE SET
                name = excluded.name,
                updated_at = excluded.updated_at
            WHERE excluded.updated_at >= place_names.updated_at
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, placeKey, -1, Self.transient)
        sqlite3_bind_text(statement, 2, trimmed, -1, Self.transient)
        sqlite3_bind_double(statement, 3, stamp)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        try logChange(.place, placeKey)
        try syncPlaceRow(id: placeKey, name: trimmed)
    }

    /// Apply a remote name when it is strictly newer than the local row.
    func applyPlaceNameIfNewer(placeKey: String, name: String, updatedAt: TimeInterval) throws -> Bool {
        let local = try loadPlaceNameRecords()[placeKey]
        if let local, local.updatedAt >= updatedAt { return false }
        try applyingRemotely {
            try setPlaceName(placeKey: placeKey, name: name, updatedAt: updatedAt)
        }
        return true
    }

    /// A whole place arriving from another device.
    ///
    /// One record, so the name, the location and the merge land together rather
    /// than racing each other. It reuses the same setters a local edit goes
    /// through — the merge especially, which moves stays and remembers where
    /// they came from — with the origin flipped so nothing is queued straight
    /// back out.
    @discardableResult
    func applyPlaceIfNewer(_ place: PlaceEntity) throws -> Bool {
        guard !place.id.isEmpty else { return false }
        if let local = try loadPlaces()[place.id], local.updatedAt >= place.updatedAt, place.updatedAt > 0 {
            return false
        }
        // Each piece goes through the setter a local edit uses, so an incoming
        // merge still moves the stays and remembers where they came from.
        try applyingRemotely {
            try setPlaceName(placeKey: place.id, name: place.name ?? "", updatedAt: place.updatedAt)
            if let coordinate = place.coordinate {
                try setPlaceLocation(placeKey: place.id, coordinate: coordinate, updatedAt: place.updatedAt)
            }
            try setPlaceSemantic(placeKey: place.id, semanticType: place.semanticType)
            // A place that was never merged carries no target; one that was
            // unmerged carries an empty one, which is a statement in its own
            // right and has to be acted on. Without that the other device kept
            // the fold forever.
            if let into = place.mergedInto {
                if into.isEmpty {
                    try unmergePlace(from: place.id, updatedAt: place.updatedAt)
                } else if into != place.id {
                    try mergePlace(
                        from: place.id,
                        into: into,
                        targetSemantic: place.semanticType,
                        updatedAt: place.updatedAt
                    )
                }
            }
        }
        return true
    }

    /// What kind of place this is, as the other device sees it. Only ever fills
    /// a gap: a device that knows a place is Home should not forget it because
    /// the other one never worked that out.
    private func setPlaceSemantic(placeKey: String, semanticType: String?) throws {
        guard let db, !placeKey.isEmpty, let semanticType, !semanticType.isEmpty else { return }
        guard !["Unknown", "unknown"].contains(semanticType) else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE places SET semantic_type = COALESCE(semantic_type, ?) WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, semanticType, -1, Self.transient)
        sqlite3_bind_text(statement, 2, placeKey, -1, Self.transient)
        sqlite3_step(statement)
    }

    /// Active `from_key → to_key` aliases (tombstones omitted). Values are chain-resolved.
    /// Where a place really is, when the recorded or imported coordinate was
    /// wrong. Google ships one coordinate per Place ID and it is sometimes the
    /// wrong end of the block; a recorded stay is wherever the fix landed.
    func loadPlaceLocations() throws -> [String: PlaceLocation] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT place_key, lat, lon, updated_at FROM place_locations",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [:] }
        var found: [String: PlaceLocation] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = text(statement, 0) else { continue }
            let coordinate = CLLocationCoordinate2D(
                latitude: sqlite3_column_double(statement, 1),
                longitude: sqlite3_column_double(statement, 2)
            )
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            found[key] = PlaceLocation(
                coordinate: coordinate,
                updatedAt: sqlite3_column_double(statement, 3)
            )
        }
        return found
    }

    func setPlaceLocation(
        placeKey: String,
        coordinate: CLLocationCoordinate2D,
        updatedAt: TimeInterval? = nil
    ) throws {
        guard let db, !placeKey.isEmpty, CLLocationCoordinate2DIsValid(coordinate) else { return }
        let stamp = updatedAt ?? Date().timeIntervalSince1970
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO place_locations (place_key, lat, lon, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(place_key) DO UPDATE SET
                lat = excluded.lat,
                lon = excluded.lon,
                updated_at = excluded.updated_at
            WHERE excluded.updated_at >= place_locations.updated_at
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(statement, 1, placeKey, -1, Self.transient)
        sqlite3_bind_double(statement, 2, coordinate.latitude)
        sqlite3_bind_double(statement, 3, coordinate.longitude)
        sqlite3_bind_double(statement, 4, stamp)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        try logChange(.place, placeKey)
        try syncPlaceRow(id: placeKey, coordinate: coordinate)
    }

    /// Put a place back where the data said it was.
    func clearPlaceLocation(placeKey: String) throws {
        guard let db, !placeKey.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM place_locations WHERE place_key = ?", -1, &statement, nil) == SQLITE_OK else {
            return
        }
        sqlite3_bind_text(statement, 1, placeKey, -1, Self.transient)
        sqlite3_step(statement)
        try logChange(.place, placeKey)
    }

    /// Apply a corrected location that is newer than the one held locally.
    func applyPlaceLocationIfNewer(
        placeKey: String,
        coordinate: CLLocationCoordinate2D,
        updatedAt: TimeInterval
    ) throws -> Bool {
        if let local = try loadPlaceLocations()[placeKey], local.updatedAt >= updatedAt { return false }
        try applyingRemotely {
            try setPlaceLocation(placeKey: placeKey, coordinate: coordinate, updatedAt: updatedAt)
        }
        return true
    }

    func loadPlaceMerges() throws -> [String: String] {
        try loadPlaceMergeRecords()
            .filter { !$0.value.isTombstone }
            .mapValues(\.toKey)
            .resolvedMerges()
    }

    func loadPlaceMergeRecords() throws -> [String: PlaceIdentityMerge] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT from_key, to_key, updated_at FROM place_merges",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        var raw: [String: PlaceIdentityMerge] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let from = text(statement, 0), let to = text(statement, 1) else { continue }
            raw[from] = PlaceIdentityMerge(toKey: to, updatedAt: sqlite3_column_double(statement, 2))
        }
        return raw
    }

    /// Apply a remote merge or unmerge tombstone when it is newer.
    func applyPlaceMergeIfNewer(
        from fromKey: String,
        into toKey: String,
        updatedAt: TimeInterval,
        targetSemantic: String?
    ) throws -> Bool {
        if toKey.isEmpty {
            return try applyPlaceUnmergeIfNewer(from: fromKey, updatedAt: updatedAt)
        }
        guard fromKey != toKey else { return false }
        if let local = try loadPlaceMergeRecords()[fromKey], local.updatedAt >= updatedAt {
            return false
        }
        try applyingRemotely {
            try mergePlace(from: fromKey, into: toKey, targetSemantic: targetSemantic, updatedAt: updatedAt)
        }
        return true
    }

    func applyPlaceUnmergeIfNewer(from fromKey: String, updatedAt: TimeInterval) throws -> Bool {
        if let local = try loadPlaceMergeRecords()[fromKey], local.updatedAt >= updatedAt {
            return false
        }
        try applyingRemotely {
            try unmergePlace(from: fromKey, updatedAt: updatedAt)
        }
        return true
    }

    /// Fold `fromKey` into `toKey` via an alias. Visits keep their original `place_key`;
    /// `loadBatch` remaps through `place_merges`. Older libraries may still have hard-remapped
    /// rows — `unmergePlace` restores those by matching visit ids.
    func mergePlace(
        from fromKey: String,
        into toKey: String,
        targetSemantic: String?,
        updatedAt: TimeInterval? = nil
    ) throws {
        guard fromKey != toKey, !toKey.isEmpty else { return }
        guard let db else { throw TimelineDatabaseError.open }
        let stamp = updatedAt ?? Date().timeIntervalSince1970
        _ = targetSemantic // Soft merge keeps each visit's semantic; target titles come from assembly.
        try exec("BEGIN IMMEDIATE")
        do {
            var insert: OpaquePointer?
            defer { sqlite3_finalize(insert) }
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT INTO place_merges (from_key, to_key, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(from_key) DO UPDATE SET
                    to_key = excluded.to_key,
                    updated_at = excluded.updated_at
                WHERE excluded.updated_at >= place_merges.updated_at
                """,
                -1,
                &insert,
                nil
            ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
            sqlite3_bind_text(insert, 1, fromKey, -1, Self.transient)
            sqlite3_bind_text(insert, 2, toKey, -1, Self.transient)
            sqlite3_bind_double(insert, 3, stamp)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
            try logChange(.place, fromKey)

            // Anything that pointed at fromKey should now point at toKey.
            try exec(
                """
                UPDATE place_merges
                SET to_key = \(quote(toKey)), updated_at = \(stamp)
                WHERE to_key = \(quote(fromKey))
                """
            )
            // Move the stays themselves. Reads resolve through place_id now, so
            // this is what the merge actually means; the alias above is kept only
            // until the sync format catches up.
            try repointStays(from: fromKey, to: toKey)
            try setPlaceName(placeKey: fromKey, name: "", updatedAt: stamp)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Move every stay at one place to another, remembering where it came from so
    /// the merge can be undone.
    private func repointStays(from fromKey: String, to toKey: String) throws {
        guard let db else { throw TimelineDatabaseError.open }
        var moved: [String] = []
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        if sqlite3_prepare_v2(db, "SELECT id FROM visits WHERE place_id = ?", -1, &select, nil) == SQLITE_OK {
            sqlite3_bind_text(select, 1, fromKey, -1, Self.transient)
            while sqlite3_step(select) == SQLITE_ROW {
                if let id = text(select, 0) { moved.append(id) }
            }
        }
        guard !moved.isEmpty else { return }

        // COALESCE keeps the *first* origin through a chain of merges, so
        // unmerging steps back one place at a time rather than losing the trail.
        try exec(
            """
            UPDATE visits
            SET place_id = \(quote(toKey)),
                origin_place_id = COALESCE(origin_place_id, \(quote(fromKey)))
            WHERE place_id = \(quote(fromKey))
            """
        )
        for id in moved {
            try logChange(.visit, id)
        }
    }

    /// The named places visited in a window, for a maintenance pass. Takes epochs
    /// rather than a date string: SQLite's `localtime` depends on the process
    /// timezone, which is not the user's in a test runner.
    func namedPlaces(from: Date, to: Date) throws -> [PlaceEntity] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT DISTINCT p.id, p.name, p.lat, p.lon, p.semantic_type
            FROM visits v JOIN places p ON p.id = v.place_id
            WHERE v.start >= ? AND v.start < ?
              AND p.name IS NOT NULL AND p.name != ''
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [] }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        var found: [PlaceEntity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            found.append(
                PlaceEntity(
                    id: id,
                    name: text(statement, 1),
                    coordinate: coordinate(statement, lat: 2, lon: 3),
                    semanticType: text(statement, 4)
                )
            )
        }
        return found
    }

    /// How many stays each place holds. Which of two duplicates is the stray.
    func stayCountsByPlace() throws -> [String: Int] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT place_id, COUNT(*) FROM visits WHERE place_id IS NOT NULL GROUP BY place_id",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [:] }
        var counts: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            counts[id] = Int(sqlite3_column_int64(statement, 1))
        }
        return counts
    }

    /// Every place's folded-in origins in one read, for the menus.
    func mergedOriginsByPlace() throws -> [String: [String]] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT DISTINCT place_id, origin_place_id FROM visits
            WHERE origin_place_id IS NOT NULL AND place_id IS NOT NULL AND place_id != origin_place_id
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [:] }
        var found: [String: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let place = text(statement, 0), let origin = text(statement, 1) else { continue }
            found[place, default: []].append(origin)
        }
        return found
    }

    /// The places folded into this one, for the Unmerge menu.
    func mergedOrigins(into placeID: String) throws -> [String] {
        guard let db, !placeID.isEmpty else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT DISTINCT origin_place_id FROM visits WHERE place_id = ? AND origin_place_id IS NOT NULL",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [] }
        sqlite3_bind_text(statement, 1, placeID, -1, Self.transient)
        var origins: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let origin = text(statement, 0), origin != placeID { origins.append(origin) }
        }
        return origins
    }

    /// Undo a merge: tombstone the alias and restore any hard-remapped visits whose
    /// id was minted from `fromKey` (SHA segment id includes the original place key).
    func unmergePlace(from fromKey: String, updatedAt: TimeInterval? = nil) throws {
        guard let db else { throw TimelineDatabaseError.open }
        let stamp = updatedAt ?? Date().timeIntervalSince1970
        let prior = try loadPlaceMergeRecords()[fromKey]
        let toKey = prior?.isTombstone == false ? prior?.toKey : nil

        try exec("BEGIN IMMEDIATE")
        do {
            if let toKey, !toKey.isEmpty {
                try restoreHardMergedVisits(fromKey: fromKey, toKey: toKey, db: db)
            }

            var insert: OpaquePointer?
            defer { sqlite3_finalize(insert) }
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT INTO place_merges (from_key, to_key, updated_at)
                VALUES (?, '', ?)
                ON CONFLICT(from_key) DO UPDATE SET
                    to_key = '',
                    updated_at = excluded.updated_at
                WHERE excluded.updated_at >= place_merges.updated_at
                """,
                -1,
                &insert,
                nil
            ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
            sqlite3_bind_text(insert, 1, fromKey, -1, Self.transient)
            sqlite3_bind_double(insert, 2, stamp)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
            try logChange(.place, fromKey)
            // Send the stays home.
            try restoreStays(originallyAt: fromKey)
            // And give them somewhere to arrive. Merging blanked this place's
            // name and the reading path goes through `places`, so without a row
            // the restored stays come back to nowhere and show as unnamed.
            try reinstatePlaceRow(fromKey, db: db)
            // Mark the place as changed now. A place syncs as one record settled
            // by last-write-wins, and an unmerge that left the timestamp alone
            // arrived looking older than what the other device already had, so
            // it was discarded and the fold stayed folded over there forever.
            try touchPlace(fromKey, at: stamp)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Record that a place changed, so the other device takes this version.
    private func touchPlace(_ placeKey: String, at stamp: TimeInterval) throws {
        guard let db, !placeKey.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE places SET updated_at = ?1 WHERE id = ?2 AND updated_at < ?1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_double(statement, 1, stamp)
        sqlite3_bind_text(statement, 2, placeKey, -1, Self.transient)
        sqlite3_step(statement)
    }

    /// Put a place row back for a key whose stays have just been restored,
    /// positioned where those stays actually are.
    ///
    /// The name is not recoverable: merging cleared it deliberately, and there
    /// is nothing left to read it from. The place comes back unnamed, which is
    /// honest, and can be renamed.
    private func reinstatePlaceRow(_ placeKey: String, db: OpaquePointer) throws {
        guard !placeKey.isEmpty else { return }
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT AVG(lat), AVG(lon), COUNT(*)
            FROM visits
            WHERE place_id = ? AND lat IS NOT NULL AND lon IS NOT NULL
            """,
            -1,
            &select,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(select, 1, placeKey, -1, Self.transient)
        guard sqlite3_step(select) == SQLITE_ROW, sqlite3_column_int64(select, 2) > 0 else { return }
        let coordinate = CLLocationCoordinate2D(
            latitude: sqlite3_column_double(select, 0),
            longitude: sqlite3_column_double(select, 1)
        )
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        try ensurePlaceRow(id: placeKey, coordinate: coordinate, semanticType: nil, db: db)
    }

    /// Visits rewritten by older hard merges keep a segment id hashed with the source place key.
    private func restoreHardMergedVisits(fromKey: String, toKey: String, db: OpaquePointer) throws {
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, start, end FROM visits WHERE place_key = ?",
            -1,
            &select,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        sqlite3_bind_text(select, 1, toKey, -1, Self.transient)

        var restoreIDs: [String] = []
        while sqlite3_step(select) == SQLITE_ROW {
            guard let id = text(select, 0) else { continue }
            let start = Date(timeIntervalSince1970: sqlite3_column_double(select, 1))
            let end = Date(timeIntervalSince1970: sqlite3_column_double(select, 2))
            let expected = Geo.segmentID("v", Geo.millis(start), Geo.millis(end), fromKey)
            if id == expected {
                restoreIDs.append(id)
            }
        }

        guard !restoreIDs.isEmpty else { return }

        var update: OpaquePointer?
        defer { sqlite3_finalize(update) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE visits SET place_id = ?1, place_key = ?1 WHERE id = ?2",
            -1,
            &update,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        for id in restoreIDs {
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            sqlite3_bind_text(update, 1, fromKey, -1, Self.transient)
            sqlite3_bind_text(update, 2, id, -1, Self.transient)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
        }
    }

    /// Corrections are keyed by the place the user was looking at. Merging that
    /// place into another would otherwise strand the correction on a key nothing
    /// resolves to any more, so it follows the merge.
    static func resolved(
        _ locations: [String: PlaceLocation],
        merges: [String: String]
    ) -> [String: PlaceLocation] {
        var resolved = locations
        for (fromKey, toKey) in merges {
            guard let carried = locations[fromKey] else { continue }
            // A correction made directly on the surviving place wins over one
            // inherited from a place folded into it.
            if let existing = resolved[toKey], existing.updatedAt >= carried.updatedAt { continue }
            resolved[toKey] = carried
        }
        return resolved
    }

    /// A corrected location wins over whatever was recorded or imported, so the
    /// pin, the day's framing and the routes all agree with it.
    private static func relocated(_ visit: TimelineVisit, locations: [String: PlaceLocation]) -> TimelineVisit {
        guard let corrected = locations[visit.placeKey] else { return visit }
        return TimelineVisit(
            id: visit.id,
            start: visit.start,
            end: visit.end,
            coordinate: corrected.coordinate,
            semanticType: visit.semanticType,
            placeKey: visit.placeKey,
            isDerived: visit.isDerived
        )
    }

    /// Mark every stay at a place as needing to be sent again.
    ///
    /// A repair changes rows whose records CloudKit has already acknowledged, so
    /// nothing would go out on its own and the other device would never learn of
    /// it.
    @discardableResult
    func requeueStays(atPlace placeKey: String) throws -> Int {
        guard let db, !placeKey.isEmpty else { return 0 }
        var ids: [String] = []
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM visits WHERE place_id = ?", -1, &select, nil) == SQLITE_OK else {
            return 0
        }
        sqlite3_bind_text(select, 1, placeKey, -1, Self.transient)
        while sqlite3_step(select) == SQLITE_ROW {
            if let id = text(select, 0) { ids.append(id) }
        }
        for id in ids { try logChange(.visit, id) }
        try logChange(.place, placeKey)
        return ids.count
    }

    /// Empty the stays table. Reproduces a library that has the note about the
    /// stay you are inside but no row for it, which is what replacing the app
    /// mid-stay used to leave behind.
    func clearVisitsForTesting() throws {
        try exec("DELETE FROM visits")
    }

    /// Drop every recorded merge origin. Reproduces the state a merge arriving
    /// from another device used to leave behind, so the recovery can be tested.
    func forgetMergeOrigins() throws {
        try exec("UPDATE visits SET origin_place_id = NULL")
    }

    /// Put back every stay a merge moved away from this place.
    /// Put back every stay a merge moved away from this place.
    ///
    /// `origin_place_id` is the record of the move, but only a merge this device
    /// performed leaves one. A merge that arrived over sync, or one the entity
    /// migration resolved while linking stays to places, moves the stay without
    /// writing an origin — and then unmerging found nothing to put back. Every
    /// such stay still carries the key it was clustered under, which is the same
    /// answer by a different route, so fall back to that.
    private func restoreStays(originallyAt originKey: String) throws {
        guard let db else { throw TimelineDatabaseError.open }
        var moved: [String] = []
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        let sql = """
            SELECT id FROM visits
            WHERE origin_place_id = ?1
               OR (origin_place_id IS NULL AND place_key = ?1 AND place_id IS NOT ?1)
            """
        if sqlite3_prepare_v2(db, sql, -1, &select, nil) == SQLITE_OK {
            sqlite3_bind_text(select, 1, originKey, -1, Self.transient)
            while sqlite3_step(select) == SQLITE_ROW {
                if let id = text(select, 0) { moved.append(id) }
            }
        }
        guard !moved.isEmpty else { return }

        try exec(
            """
            UPDATE visits
            SET place_id = \(quote(originKey)), origin_place_id = NULL
            WHERE origin_place_id = \(quote(originKey))
               OR (origin_place_id IS NULL AND place_key = \(quote(originKey)))
            """
        )
        for id in moved {
            try logChange(.visit, id)
        }
    }

    private static func remapped(_ visit: TimelineVisit, merges: [String: String]) -> TimelineVisit {
        guard let target = merges[visit.placeKey], target != visit.placeKey else { return visit }
        return TimelineVisit(
            id: visit.id,
            start: visit.start,
            end: visit.end,
            coordinate: visit.coordinate,
            semanticType: visit.semanticType,
            placeKey: target
        )
    }

    private static func migrate(_ db: OpaquePointer?) throws {
        try exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS imports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_name TEXT NOT NULL,
                imported_at REAL NOT NULL,
                visit_count INTEGER NOT NULL,
                activity_count INTEGER NOT NULL,
                path_count INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS visits (
                id TEXT PRIMARY KEY,
                start REAL NOT NULL,
                end REAL NOT NULL,
                lat REAL,
                lon REAL,
                place_key TEXT NOT NULL,
                semantic_type TEXT
            );
            CREATE INDEX IF NOT EXISTS visits_start ON visits(start);
            CREATE TABLE IF NOT EXISTS activities (
                id TEXT PRIMARY KEY,
                start REAL NOT NULL,
                end REAL NOT NULL,
                distance REAL NOT NULL,
                start_lat REAL,
                start_lon REAL,
                end_lat REAL,
                end_lon REAL,
                kind TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS activities_start ON activities(start);
            CREATE TABLE IF NOT EXISTS paths (
                id TEXT PRIMARY KEY,
                start REAL NOT NULL,
                end REAL NOT NULL,
                kind TEXT NOT NULL,
                point_count INTEGER NOT NULL,
                points BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS paths_start ON paths(start);
            CREATE TABLE IF NOT EXISTS route_hops (
                key TEXT PRIMARY KEY,
                points BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS path_routes (
                path_id TEXT PRIMARY KEY,
                points BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS place_names (
                place_key TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS places (
                id TEXT PRIMARY KEY,
                name TEXT,
                lat REAL,
                lon REAL,
                semantic_type TEXT,
                updated_at REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS place_locations (
                place_key TEXT PRIMARY KEY,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS place_merges (
                from_key TEXT PRIMARY KEY,
                to_key TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS fixes (
                t REAL PRIMARY KEY,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                h_accuracy REAL NOT NULL,
                speed REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS open_visit (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                start REAL NOT NULL,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                h_accuracy REAL NOT NULL,
                place_key TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS capture_marks (
                name TEXT PRIMARY KEY,
                through REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS change_log (
                kind TEXT NOT NULL,
                row_id TEXT NOT NULL,
                op TEXT NOT NULL,
                seq INTEGER NOT NULL,
                changed_at REAL NOT NULL,
                PRIMARY KEY (kind, row_id)
            );
            CREATE INDEX IF NOT EXISTS change_log_seq ON change_log(seq);
            CREATE TABLE IF NOT EXISTS ck_records (
                record_name TEXT PRIMARY KEY,
                archive BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sync_state (
                key TEXT PRIMARY KEY,
                int_value INTEGER NOT NULL DEFAULT 0,
                blob_value BLOB
            );
            CREATE TRIGGER IF NOT EXISTS paths_points_changed AFTER UPDATE OF points ON paths
            BEGIN
                DELETE FROM path_routes WHERE path_id = NEW.id;
            END;
            """
        )
        // Existing libraries predate provenance; everything already in them came
        // from an export.
        for table in ["visits", "activities", "paths"] {
            try addColumn(db, table: table, column: "source TEXT NOT NULL DEFAULT 'google'")
        }
        // Imported rows a recording supersedes are hidden, never deleted.
        try addColumn(db, table: "visits", column: "shadowed INTEGER NOT NULL DEFAULT 0")
        // A stay points at a place rather than carrying one inside its identity.
        try addColumn(db, table: "visits", column: "place_id TEXT")
        // What a cached route was drawn between, so moving a place invalidates it.
        try addColumn(db, table: "path_routes", column: "anchor TEXT")
        // A stay that has begun and not ended. It is a row from the moment it
        // opens so the other device can see it; its end is only provisional
        // until it closes.
        try addColumn(db, table: "visits", column: "is_open INTEGER NOT NULL DEFAULT 0")
        // Every version of a stay that was superseded, in the order it happened.
        //
        // Deleting one takes it out of the timeline; it does not destroy it. The
        // same goes for correcting its times or cutting it in two: what was
        // there before is still a reading of where you were, and the difference
        // between a mistake and a thing you have forgotten is often only
        // obvious later. So nothing is overwritten without the previous version
        // being written down first, and any of them can be put back.
        try exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS visit_history (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL,
                start REAL NOT NULL,
                end REAL NOT NULL,
                lat REAL,
                lon REAL,
                place_key TEXT,
                place_id TEXT,
                semantic_type TEXT,
                source TEXT NOT NULL DEFAULT 'device',
                changed_at REAL NOT NULL,
                change TEXT NOT NULL,
                reason TEXT
            );
            CREATE INDEX IF NOT EXISTS visit_history_when ON visit_history(changed_at);
            CREATE INDEX IF NOT EXISTS visit_history_stay ON visit_history(id);
            """
        )
        // The bin came first and only held deletions. Its rows are versions too.
        //
        // Guarded in Swift, not in SQL: SQLite resolves table names when a
        // statement is prepared, so a query mentioning a table that was never
        // created fails before any WHERE clause can say "only if it exists" —
        // and a migration that throws halfway leaves every later column
        // unadded.
        if try Self.tableExists("deleted_visits", db: db) {
            try exec(
                db,
                """
                INSERT INTO visit_history
                    (id, start, end, lat, lon, place_key, place_id, semantic_type, source, changed_at, change, reason)
                SELECT id, start, end, lat, lon, place_key, place_id, semantic_type, source, deleted_at, 'deleted', reason
                FROM deleted_visits
                WHERE id NOT IN (SELECT id FROM visit_history WHERE change = 'deleted')
                """
            )
        }
        // Where the stay was before a merge moved it, so unmerging can put it
        // back. Repointing without this would be a one-way door.
        try addColumn(db, table: "visits", column: "origin_place_id TEXT")
        try exec(db, "CREATE INDEX IF NOT EXISTS visits_place_id ON visits(place_id)")
        try addColumn(db, table: "sync_state", column: "blob_value BLOB")
    }

    /// `ALTER TABLE ADD COLUMN` has no `IF NOT EXISTS`, so ask first.
    private static func tableExists(_ name: String, db: OpaquePointer?) throws -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, name, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func addColumn(_ db: OpaquePointer?, table: String, column: String) throws {
        guard let db else { throw TimelineDatabaseError.open }
        let name = String(column.prefix(while: { $0 != " " }))
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1), String(cString: raw) == name { exists = true }
        }
        guard !exists else { return }
        try exec(db, "ALTER TABLE \(table) ADD COLUMN \(column)")
    }

    private func upsertVisits(_ visits: [TimelineVisit], db: OpaquePointer, source: RecordSource) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            INSERT INTO visits (id, start, end, lat, lon, place_key, semantic_type, source, place_id, is_open)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                start = excluded.start,
                end = excluded.end,
                lat = COALESCE(excluded.lat, visits.lat),
                lon = COALESCE(excluded.lon, visits.lon),
                place_key = excluded.place_key,
                -- And the place it points at. Reads resolve through place_id, so
                -- leaving it alone here meant nothing about where a stay belongs
                -- ever crossed between devices: a merge, an unmerge or a move
                -- updated place_id locally, sent a record carrying the new place,
                -- and the other device filed it under place_key and went on
                -- showing the old one.
                place_id = excluded.place_id,
                is_open = excluded.is_open,
                semantic_type = CASE
                    WHEN excluded.semantic_type IS NOT NULL
                         AND excluded.semantic_type NOT IN ('', 'Unknown', 'unknown')
                    THEN excluded.semantic_type
                    ELSE visits.semantic_type
                END,
                -- Hand-added wins from either side: a later recording must not
                -- quietly demote a stay someone entered themselves.
                source = CASE
                    WHEN excluded.source = 'manual' OR visits.source = 'manual' THEN 'manual'
                    ELSE excluded.source
                END
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        for visit in visits {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, visit.id, -1, Self.transient)
            sqlite3_bind_double(statement, 2, visit.start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, visit.end.timeIntervalSince1970)
            if let coordinate = visit.coordinate {
                sqlite3_bind_double(statement, 4, coordinate.latitude)
                sqlite3_bind_double(statement, 5, coordinate.longitude)
            } else {
                sqlite3_bind_null(statement, 4)
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_bind_text(statement, 6, visit.placeKey, -1, Self.transient)
            if let type = visit.semanticType {
                sqlite3_bind_text(statement, 7, type, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            sqlite3_bind_text(statement, 8, source.rawValue, -1, Self.transient)
            // Every stay points at a place from the moment it is written. Leaving
            // that to the migration meant a stay recorded in the background had
            // no place until the app was next opened.
            sqlite3_bind_text(statement, 9, visit.placeKey, -1, Self.transient)
            sqlite3_bind_int64(statement, 10, visit.isOpen ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
            try ensurePlaceRow(
                id: visit.placeKey,
                coordinate: visit.coordinate,
                semanticType: visit.semanticType,
                db: db
            )
            try logChange(.visit, visit.id)
        }
    }

    /// Create the place a stay points at, if this is the first time we have seen
    /// it. Never overwrites what is already known about it — a recorded fix is
    /// weaker evidence than a name or a correction the user has given.
    private func ensurePlaceRow(
        id: String,
        coordinate: CLLocationCoordinate2D?,
        semanticType: String?,
        db: OpaquePointer
    ) throws {
        guard !id.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO places (id, name, lat, lon, semantic_type, updated_at)
            VALUES (?, NULL, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                lat = COALESCE(places.lat, excluded.lat),
                lon = COALESCE(places.lon, excluded.lon),
                semantic_type = COALESCE(places.semantic_type, excluded.semantic_type)
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        bindCoord(statement, index: 2, coordinate: coordinate)
        if let semanticType, !semanticType.isEmpty, !["Unknown", "unknown"].contains(semanticType) {
            sqlite3_bind_text(statement, 4, semanticType, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    private func upsertActivities(_ activities: [TimelineActivity], db: OpaquePointer, source: RecordSource) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            INSERT INTO activities (id, start, end, distance, start_lat, start_lon, end_lat, end_lon, kind, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                distance = MAX(activities.distance, excluded.distance),
                kind = excluded.kind
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        for activity in activities {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, activity.id, -1, Self.transient)
            sqlite3_bind_double(statement, 2, activity.start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, activity.end.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, activity.distance)
            bindCoord(statement, index: 5, coordinate: activity.startCoordinate)
            bindCoord(statement, index: 7, coordinate: activity.endCoordinate)
            sqlite3_bind_text(statement, 9, activity.kind.stored, -1, Self.transient)
            sqlite3_bind_text(statement, 10, source.rawValue, -1, Self.transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
            try logChange(.activity, activity.id)
        }
    }

    private func upsertPaths(_ paths: [TimelinePath], db: OpaquePointer, source: RecordSource) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            INSERT INTO paths (id, start, end, kind, point_count, points, source)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                point_count = excluded.point_count,
                points = excluded.points
            WHERE excluded.point_count >= paths.point_count
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        for path in paths {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, path.id, -1, Self.transient)
            sqlite3_bind_double(statement, 2, path.start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, path.end.timeIntervalSince1970)
            sqlite3_bind_text(statement, 4, path.kind.stored, -1, Self.transient)
            sqlite3_bind_int(statement, 5, Int32(path.points.count))
            bindBlob(statement, 6, CoordBlob.pack(path.points))
            sqlite3_bind_text(statement, 7, source.rawValue, -1, Self.transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
            try logChange(.path, path.id)
        }
    }

    private func loadVisits(includingShadowed: Bool = true, source: RecordSource? = nil) throws -> [TimelineVisit] {
        guard let db else { return [] }
        var clauses: [String] = []
        if !includingShadowed { clauses.append("shadowed = 0") }
        if let source { clauses.append("source = '\(source.rawValue)'") }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, start, end, lat, lon, COALESCE(place_id, place_key), semantic_type, is_open FROM visits" + filter,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        var rows: [TimelineVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                TimelineVisit(
                    id: text(statement, 0) ?? "",
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    coordinate: coordinate(statement, lat: 3, lon: 4),
                    semanticType: text(statement, 6),
                    placeKey: text(statement, 5) ?? "",
                    isOpen: sqlite3_column_int64(statement, 7) == 1
                )
            )
        }
        return rows
    }

    /// Activities overlapping a window, for the HealthKit correction pass.
    func activities(from: Date, to: Date) throws -> [TimelineActivity] {
        try loadActivities().filter { $0.end > from && $0.start < to }
    }

    private func loadActivities() throws -> [TimelineActivity] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, start, end, distance, start_lat, start_lon, end_lat, end_lon, kind FROM activities",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        var rows: [TimelineActivity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                TimelineActivity(
                    id: text(statement, 0) ?? "",
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    distance: sqlite3_column_double(statement, 3),
                    startCoordinate: coordinate(statement, lat: 4, lon: 5),
                    endCoordinate: coordinate(statement, lat: 6, lon: 7),
                    kind: TravelKind(stored: text(statement, 8) ?? "automobile")
                )
            )
        }
        return rows
    }

    private func loadPaths() throws -> [TimelinePath] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, start, end, kind, points FROM paths",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
        var rows: [TimelinePath] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                TimelinePath(
                    id: text(statement, 0) ?? "",
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    points: CoordBlob.unpack(blob(statement, 4)) ?? [],
                    kind: TravelKind(stored: text(statement, 3) ?? "automobile")
                )
            )
        }
        return rows
    }

    private func bindCoord(_ statement: OpaquePointer?, index: Int32, coordinate: CLLocationCoordinate2D?) {
        if let coordinate {
            sqlite3_bind_double(statement, index, coordinate.latitude)
            sqlite3_bind_double(statement, index + 1, coordinate.longitude)
        } else {
            sqlite3_bind_null(statement, index)
            sqlite3_bind_null(statement, index + 1)
        }
    }

    private func coordinate(_ statement: OpaquePointer?, lat: Int32, lon: Int32) -> CLLocationCoordinate2D? {
        if sqlite3_column_type(statement, lat) == SQLITE_NULL { return nil }
        let coordinate = CLLocationCoordinate2D(
            latitude: sqlite3_column_double(statement, lat),
            longitude: sqlite3_column_double(statement, lon)
        )
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private func blob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), Self.transient)
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func exec(_ sql: String) throws {
        try Self.exec(db, sql)
    }

    /// Takes the handle explicitly so `init`, which is nonisolated, can run the
    /// pragmas and the migration without hopping onto the actor.
    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard let db else { throw TimelineDatabaseError.open }
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        if let error {
            let message = String(cString: error)
            sqlite3_free(error)
            if status != SQLITE_OK { throw TimelineDatabaseError.execute(message) }
        } else if status != SQLITE_OK {
            throw TimelineDatabaseError.execute(errmsg(db))
        }
    }

    private func scalar(_ sql: String) throws -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func string(_ sql: String) throws -> String? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func errmsg() -> String {
        Self.errmsg(db)
    }

    private static func errmsg(_ db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "SQLite error" }
        return String(cString: message)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum CoordBlob {
    static func pack(_ points: [CLLocationCoordinate2D]) -> Data {
        var data = Data(count: points.count * 16)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.bindMemory(to: Double.self).baseAddress else { return }
            for (index, point) in points.enumerated() {
                base[index * 2] = point.latitude
                base[index * 2 + 1] = point.longitude
            }
        }
        return data
    }

    static func unpack(_ data: Data?) -> [CLLocationCoordinate2D]? {
        guard let data, !data.isEmpty, data.count % 16 == 0 else { return nil }
        let count = data.count / 16
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: Double.self).baseAddress else { return [] }
            var points: [CLLocationCoordinate2D] = []
            points.reserveCapacity(count)
            for index in 0..<count {
                let point = CLLocationCoordinate2D(latitude: base[index * 2], longitude: base[index * 2 + 1])
                if CLLocationCoordinate2DIsValid(point) { points.append(point) }
            }
            return points
        }
    }
}
