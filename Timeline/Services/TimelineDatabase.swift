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

    func loadBatch() throws -> TimelineBatch? {
        if try isEmpty() { return nil }
        let merges = try loadPlaceMerges()
        return TimelineBatch(
            visits: try loadVisits().map { Self.remapped($0, merges: merges) },
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
            try upsertVisits(batch.visits, db: db)
            try upsertActivities(batch.activities, db: db)
            try upsertPaths(batch.paths, db: db)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
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
    }

    /// Apply a remote name when it is strictly newer than the local row.
    func applyPlaceNameIfNewer(placeKey: String, name: String, updatedAt: TimeInterval) throws -> Bool {
        let local = try loadPlaceNameRecords()[placeKey]
        if let local, local.updatedAt >= updatedAt { return false }
        try setPlaceName(placeKey: placeKey, name: name, updatedAt: updatedAt)
        return true
    }

    /// `from_key → to_key` aliases. Values are already resolved through chains.
    func loadPlaceMerges() throws -> [String: String] {
        try loadPlaceMergeRecords().mapValues(\.toKey).resolvedMerges()
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

    /// Apply a remote merge when it is newer; remaps visits like a local merge.
    func applyPlaceMergeIfNewer(
        from fromKey: String,
        into toKey: String,
        updatedAt: TimeInterval,
        targetSemantic: String?
    ) throws -> Bool {
        guard fromKey != toKey else { return false }
        if let local = try loadPlaceMergeRecords()[fromKey], local.updatedAt >= updatedAt {
            return false
        }
        try mergePlace(from: fromKey, into: toKey, targetSemantic: targetSemantic, updatedAt: updatedAt)
        return true
    }

    /// Fold `fromKey` into `toKey`: remap visits, record the alias, drop the old custom name.
    func mergePlace(
        from fromKey: String,
        into toKey: String,
        targetSemantic: String?,
        updatedAt: TimeInterval? = nil
    ) throws {
        guard fromKey != toKey else { return }
        guard let db else { throw TimelineDatabaseError.open }
        let stamp = updatedAt ?? Date().timeIntervalSince1970
        try exec("BEGIN IMMEDIATE")
        do {
            var update: OpaquePointer?
            defer { sqlite3_finalize(update) }
            guard sqlite3_prepare_v2(
                db,
                """
                UPDATE visits
                SET place_key = ?,
                    semantic_type = CASE
                        WHEN ? IS NOT NULL AND ? NOT IN ('', 'Unknown', 'unknown')
                        THEN ?
                        ELSE semantic_type
                    END
                WHERE place_key = ?
                """,
                -1,
                &update,
                nil
            ) == SQLITE_OK else { throw TimelineDatabaseError.execute(errmsg()) }
            sqlite3_bind_text(update, 1, toKey, -1, Self.transient)
            if let targetSemantic, !targetSemantic.isEmpty {
                sqlite3_bind_text(update, 2, targetSemantic, -1, Self.transient)
                sqlite3_bind_text(update, 3, targetSemantic, -1, Self.transient)
                sqlite3_bind_text(update, 4, targetSemantic, -1, Self.transient)
            } else {
                sqlite3_bind_null(update, 2)
                sqlite3_bind_null(update, 3)
                sqlite3_bind_null(update, 4)
            }
            sqlite3_bind_text(update, 5, fromKey, -1, Self.transient)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }

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
            CREATE TRIGGER IF NOT EXISTS paths_points_changed AFTER UPDATE OF points ON paths
            BEGIN
                DELETE FROM path_routes WHERE path_id = NEW.id;
            END;
            """
        )
    }

    private func upsertVisits(_ visits: [TimelineVisit], db: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            INSERT INTO visits (id, start, end, lat, lon, place_key, semantic_type)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                lat = COALESCE(excluded.lat, visits.lat),
                lon = COALESCE(excluded.lon, visits.lon),
                semantic_type = CASE
                    WHEN excluded.semantic_type IS NOT NULL
                         AND excluded.semantic_type NOT IN ('', 'Unknown', 'unknown')
                    THEN excluded.semantic_type
                    ELSE visits.semantic_type
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
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
        }
    }

    private func upsertActivities(_ activities: [TimelineActivity], db: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            INSERT INTO activities (id, start, end, distance, start_lat, start_lon, end_lat, end_lon, kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                distance = MAX(activities.distance, excluded.distance)
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
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
        }
    }

    private func upsertPaths(_ paths: [TimelinePath], db: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            INSERT INTO paths (id, start, end, kind, point_count, points)
            VALUES (?, ?, ?, ?, ?, ?)
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
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TimelineDatabaseError.execute(errmsg())
            }
        }
    }

    private func loadVisits() throws -> [TimelineVisit] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, start, end, lat, lon, place_key, semantic_type FROM visits",
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
