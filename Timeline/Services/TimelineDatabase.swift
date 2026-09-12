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

    func loadBatch(includingShadowed: Bool = false) throws -> TimelineBatch? {
        if try isEmpty() { return nil }
        let merges = try loadPlaceMerges()
        return TimelineBatch(
            visits: try loadVisits(includingShadowed: includingShadowed).map { Self.remapped($0, merges: merges) },
            activities: try loadActivities(),
            paths: try loadPaths()
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
        guard sqlite3_prepare_v2(db, "SELECT id FROM visits WHERE end <= start", -1, &statement, nil) == SQLITE_OK else {
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
    func moveVisit(id: String, toPlaceKey placeKey: String) throws {
        guard let db, !id.isEmpty, !placeKey.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "UPDATE visits SET place_key = ? WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        sqlite3_bind_text(statement, 1, placeKey, -1, Self.transient)
        sqlite3_bind_text(statement, 2, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        try logChange(.visit, id)
    }

    /// Every place we could snap a new stay onto, with how often it was visited
    /// and whether it already carries a name worth not asking about again.
    func placeAnchors() throws -> [PlaceAnchor] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT v.place_key,
                   AVG(v.lat),
                   AVG(v.lon),
                   COUNT(*),
                   MAX(CASE
                       WHEN n.name IS NOT NULL AND n.name != '' THEN 1
                       WHEN v.semantic_type IS NOT NULL
                            AND v.semantic_type NOT IN ('', 'Unknown', 'unknown') THEN 1
                       ELSE 0
                   END)
            FROM visits v
            LEFT JOIN place_names n ON n.place_key = v.place_key
            WHERE v.lat IS NOT NULL AND v.lon IS NOT NULL
            GROUP BY v.place_key
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TimelineDatabaseError.execute(errmsg())
        }
        let merges = try loadPlaceMerges()
        var anchors: [String: PlaceAnchor] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawKey = text(statement, 0) else { continue }
            let key = merges[rawKey] ?? rawKey
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
        return Array(anchors.values)
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
            for key in try loadPlaceNameRecords().keys { try logChange(.placeName, key) }
            for key in try loadPlaceMergeRecords().keys { try logChange(.placeMerge, key) }
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
        case .placeName: table = "place_names"; column = "place_key"
        case .placeMerge: table = "place_merges"; column = "from_key"
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

    func pathRoute(id: String) throws -> [CLLocationCoordinate2D]? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT points FROM path_routes WHERE path_id = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return CoordBlob.unpack(blob(statement, 0))
    }

    func savePathRoute(id: String, points: [CLLocationCoordinate2D]) throws {
        guard let db, points.count >= 2 else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO path_routes (path_id, points) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        bindBlob(statement, 2, CoordBlob.pack(points))
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
        try logChange(.placeName, placeKey)
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

    /// Active `from_key → to_key` aliases (tombstones omitted). Values are chain-resolved.
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
            try logChange(.placeMerge, fromKey)

            // Anything that pointed at fromKey should now point at toKey.
            try exec(
                """
                UPDATE place_merges
                SET to_key = \(quote(toKey)), updated_at = \(stamp)
                WHERE to_key = \(quote(fromKey))
                """
            )
            try setPlaceName(placeKey: fromKey, name: "", updatedAt: stamp)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
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
            try logChange(.placeMerge, fromKey)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
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
            "UPDATE visits SET place_key = ? WHERE id = ?",
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
        try addColumn(db, table: "sync_state", column: "blob_value BLOB")
    }

    /// `ALTER TABLE ADD COLUMN` has no `IF NOT EXISTS`, so ask first.
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
            INSERT INTO visits (id, start, end, lat, lon, place_key, semantic_type, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                start = excluded.start,
                end = excluded.end,
                lat = COALESCE(excluded.lat, visits.lat),
                lon = COALESCE(excluded.lon, visits.lon),
                place_key = excluded.place_key,
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
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
            try logChange(.visit, visit.id)
        }
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
            "SELECT id, start, end, lat, lon, place_key, semantic_type FROM visits" + filter,
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
                    placeKey: text(statement, 5) ?? ""
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
