import Foundation
import CloudKit
import Observation

/// Syncs the library between the user's devices with `CKSyncEngine`.
///
/// The phone records and the Mac reads, so in practice this is one-way — but the
/// engine is bidirectional anyway, which is what makes a second iPhone or an iPad
/// free later.
///
/// Two properties of the data make this much simpler than sync usually is: row
/// ids are content hashes, so both devices mint the same id for the same stay and
/// re-sending is idempotent; and a closed stay never changes, so last-writer-wins
/// per record is actually the correct merge rule rather than a resignation.
actor TimelineCloudSync {
    /// Where the engine's own serialized state lives, inside the library file.
    private static let stateKey = "cloudKitSyncState"
    private static let containerIdentifier = "iCloud.com.appler.Timeline"
    /// CloudKit rejects oversized batches; the engine also caps by byte size, but
    /// there is no reason to hand it a thousand rows at once.
    private static let batchLimit = 200

    private let database: TimelineDatabase
    private let containerIdentifier: String
    private var engine: CKSyncEngine?
    private var isResyncing = false

    /// Rows the engine is currently sending, so the acknowledgement can name them
    /// precisely rather than clearing whatever happens to be queued.
    private var inFlight: [String: PendingChange] = [:]
    /// Conflicts resolve by adopting the server's record and retrying once. A
    /// record that keeps failing after that is a bug, not a race, and retrying it
    /// forever is how 400 rows became 3,400 failed requests.
    private var conflictRetries: [String: Int] = [:]
    private static let maximumConflictRetries = 3

    init(database: TimelineDatabase, containerIdentifier: String = TimelineCloudSync.containerIdentifier) {
        self.database = database
        self.containerIdentifier = containerIdentifier
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: TimelineRecordMapper.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    var isRunning: Bool { engine != nil }

    // MARK: - Lifecycle

    /// Build the engine and hand it whatever state the last run left behind.
    /// Without that state every launch would re-sync the entire library.
    func start() async throws {
        guard engine == nil else { return }
        let container = CKContainer(identifier: containerIdentifier)
        let status = try? await container.accountStatus()
        guard status == .available else {
            TimelineLog.info("cloud sync unavailable", ["status": "\(status?.rawValue ?? -1)"])
            throw CloudSyncError.noAccount
        }

        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: await loadState(),
            delegate: self
        )
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)

        // Creating the zone is idempotent and the engine dedupes it, so asking
        // every launch costs nothing and saves a first-run failure path.
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        TimelineLog.info("cloud sync started")

        // Anything queued before sync was turned on still needs sending.
        await enqueuePendingChanges()
    }

    func stop() {
        engine = nil
        inFlight = [:]
        TimelineLog.info("cloud sync stopped")
    }

    /// Queue the whole library, then send. This is the first sync after the user
    /// turns iCloud on, and the repair if the change log ever loses an entry.
    ///
    /// Must never be awaited from inside a delegate callback — see the sign-in
    /// case in `handleAccountChange`.
    func resyncEverything() async throws {
        guard !isResyncing else { return }
        isResyncing = true
        defer { isResyncing = false }
        _ = try await database.markEverythingPending()
        await enqueuePendingChanges()
        try await engine?.sendChanges()
    }

    func fetchNow() async throws {
        try await engine?.fetchChanges()
    }

    /// Tell the engine which records have local edits waiting. The change log is
    /// the source of truth; the engine's pending list is a mirror of it.
    func enqueuePendingChanges() async {
        guard let engine else { return }
        let changes = (try? await database.pendingChanges(limit: Self.batchLimit)) ?? []
        guard !changes.isEmpty else { return }
        let pending: [CKSyncEngine.PendingRecordZoneChange] = changes.map { change in
            let id = TimelineRecordMapper.recordID(for: change, in: zoneID)
            return change.operation == .delete ? .deleteRecord(id) : .saveRecord(id)
        }
        for change in changes {
            // Keyed by record name, which is what the server acknowledges.
            inFlight[TimelineRecordMapper.recordName(for: change.kind, rowID: change.rowID)] = change
        }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    private func loadState() async -> CKSyncEngine.State.Serialization? {
        guard let data = try? await database.syncStateData(Self.stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func save(state: CKSyncEngine.State.Serialization) async {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? await database.setSyncStateData(Self.stateKey, data)
    }

    enum CloudSyncError: LocalizedError {
        case noAccount

        var errorDescription: String? {
            switch self {
            case .noAccount: return "Sign in to iCloud to sync your timeline between devices."
            }
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension TimelineCloudSync: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            await save(state: update.stateSerialization)

        case .fetchedRecordZoneChanges(let changes):
            await apply(changes)

        case .sentRecordZoneChanges(let sent):
            await acknowledge(sent)

        case .accountChange(let change):
            await handleAccountChange(change)

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        let batch = (try? await database.changeBatch(limit: Self.batchLimit)) ?? ChangeBatch()
        // Build each save on the record CloudKit last acknowledged, so it carries
        // the change tag and reads as an update rather than an insert.
        let names = batch.changes.map { TimelineRecordMapper.recordName(for: $0.kind, rowID: $0.rowID) }
        let archives = (try? await database.cloudRecordArchives(names)) ?? [:]
        let bases = archives.compactMapValues { TimelineRecordMapper.decodeSystemFields($0) }
        let records = recordsByName(from: batch, bases: bases)

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            records[recordID.recordName]
        }
    }

    /// The rows a batch names, keyed by record name so the engine's provider can
    /// answer in constant time.
    private func recordsByName(from batch: ChangeBatch, bases: [String: CKRecord]) -> [String: CKRecord] {
        var records: [String: CKRecord] = [:]
        func name(_ kind: ChangeKind, _ rowID: String) -> String {
            TimelineRecordMapper.recordName(for: kind, rowID: rowID)
        }
        for visit in batch.visits {
            let key = name(.visit, visit.id)
            records[key] = TimelineRecordMapper.record(
                for: visit,
                in: zoneID,
                base: bases[key],
                source: batch.visitSources[visit.id] ?? .device
            )
        }
        for activity in batch.activities {
            let key = name(.activity, activity.id)
            records[key] = TimelineRecordMapper.record(for: activity, in: zoneID, base: bases[key])
        }
        for path in batch.paths {
            let key = name(.path, path.id)
            records[key] = TimelineRecordMapper.record(for: path, in: zoneID, base: bases[key])
        }
        for (placeKey, value) in batch.names {
            let key = name(.placeName, placeKey)
            records[key] = TimelineRecordMapper.record(forPlaceKey: placeKey, name: value, in: zoneID, base: bases[key])
        }
        for (placeKey, value) in batch.merges {
            let key = name(.placeMerge, placeKey)
            records[key] = TimelineRecordMapper.record(forPlaceKey: placeKey, merge: value, in: zoneID, base: bases[key])
        }
        for (placeKey, value) in batch.locations {
            let key = name(.placeLocation, placeKey)
            records[key] = TimelineRecordMapper.record(forPlaceKey: placeKey, location: value, in: zoneID, base: bases[key])
        }
        return records
    }

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        // Modifications arrive wrapped; the record is what we want.
        let modifications = changes.modifications.map(\.record)
        let deletions = changes.deletions
        guard !modifications.isEmpty || !deletions.isEmpty else { return }
        let parsed = TimelineRecordMapper.batch(from: modifications)

        // applyRemote deliberately does not log these as local changes — that is
        // what stops an incoming row from being queued straight back out.
        for record in modifications {
            try? await database.setCloudRecordArchive(
                record.recordID.recordName,
                TimelineRecordMapper.encodeSystemFields(record)
            )
        }
        try? await database.applyRemote(parsed.rows, visitSources: parsed.visitSources)
        for (key, name) in parsed.names {
            _ = try? await database.applyPlaceNameIfNewer(
                placeKey: key,
                name: name.name,
                updatedAt: name.updatedAt
            )
        }
        for (key, location) in parsed.locations {
            _ = try? await database.applyPlaceLocationIfNewer(
                placeKey: key,
                coordinate: location.coordinate,
                updatedAt: location.updatedAt
            )
        }
        for (key, merge) in parsed.merges {
            _ = try? await database.applyPlaceMergeIfNewer(
                from: key,
                into: merge.toKey,
                updatedAt: merge.updatedAt,
                targetSemantic: nil
            )
        }
        for deletion in deletions {
            try? await database.setCloudRecordArchive(deletion.recordID.recordName, nil)
            guard let kind = TimelineRecordMapper.kind(forRecordType: deletion.recordType) else { continue }
            try? await database.applyRemoteDeletion(
                kind: kind,
                rowID: TimelineRecordMapper.rowID(fromRecordName: deletion.recordID.recordName, kind: kind)
            )
        }

        TimelineLog.info(
            "cloud sync fetched",
            ["records": "\(modifications.count)", "deletions": "\(deletions.count)"]
        )
        await MainActor.run {
            NotificationCenter.default.post(name: .timelineLibraryChanged, object: nil)
        }
    }

    private func acknowledge(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async {
        // A saved record carries the change tag the next save has to quote.
        for record in sent.savedRecords {
            try? await database.setCloudRecordArchive(
                record.recordID.recordName,
                TimelineRecordMapper.encodeSystemFields(record)
            )
            conflictRetries.removeValue(forKey: record.recordID.recordName)
        }

        let saved = sent.savedRecords.map(\.recordID.recordName) + sent.deletedRecordIDs.map(\.recordName)
        let acknowledged = saved.compactMap { inFlight[$0] }
        if !acknowledged.isEmpty {
            try? await database.acknowledge(acknowledged)
            for name in saved { inFlight.removeValue(forKey: name) }
        }
        for name in sent.deletedRecordIDs.map(\.recordName) {
            try? await database.setCloudRecordArchive(name, nil)
        }

        for failure in sent.failedRecordSaves {
            await handle(failure: failure)
        }

        if !acknowledged.isEmpty {
            TimelineLog.info("cloud sync sent", ["records": "\(acknowledged.count)"])
        }
        // Drain whatever the change log gained while this batch was in flight.
        await enqueuePendingChanges()
    }

    /// Not every failure deserves another attempt. Leaving them all in the change
    /// log turned a permanent rejection into an endless retry.
    private func handle(failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) async {
        let name = failure.record.recordID.recordName
        let change = inFlight.removeValue(forKey: name)
        let error = failure.error

        switch error.code {
        case .serverRecordChanged:
            // The row exists and our copy was stale — adopt the server's record so
            // the next save quotes the right change tag. This is the exact failure
            // that fired 3,400 times: a fresh CKRecord has no tag at all.
            if let server = error.serverRecord {
                try? await database.setCloudRecordArchive(
                    name,
                    TimelineRecordMapper.encodeSystemFields(server)
                )
            }
            await retryOrGiveUp(name: name, change: change, reason: "conflict")

        case .unknownItem:
            // Gone from the server. Forget the tag and let it insert cleanly.
            try? await database.setCloudRecordArchive(name, nil)
            await retryOrGiveUp(name: name, change: change, reason: "missing on server")

        case .zoneNotFound, .userDeletedZone:
            try? await database.clearCloudRecordArchives()
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            await retryOrGiveUp(name: name, change: change, reason: "zone missing")

        case .networkFailure, .networkUnavailable, .requestRateLimited,
             .serviceUnavailable, .zoneBusy, .operationCancelled:
            // Transient: leave it queued and let the next send pick it up.
            break

        default:
            // Permanent and unhandled. Drop it rather than spin, and say so.
            if let change { try? await database.acknowledge([change]) }
            TimelineLog.error(
                "cloud sync record dropped",
                ["record": name, "error": failure.error.localizedDescription]
            )
        }
    }

    private func retryOrGiveUp(name: String, change: PendingChange?, reason: String) async {
        let attempts = (conflictRetries[name] ?? 0) + 1
        conflictRetries[name] = attempts
        guard attempts <= Self.maximumConflictRetries else {
            if let change { try? await database.acknowledge([change]) }
            conflictRetries.removeValue(forKey: name)
            TimelineLog.error(
                "cloud sync record gave up",
                ["record": name, "reason": reason, "attempts": "\(attempts)"]
            )
            return
        }
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
        if let change { inFlight[name] = change }
        TimelineLog.info("cloud sync retrying", ["record": name, "reason": reason, "attempt": "\(attempts)"])
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            // A fresh account has none of this library, so offer all of it — but
            // never from inside a delegate callback. CKSyncEngine traps if you
            // await a call that reenters the delegate, because it can no longer
            // promise to deliver callbacks serially. The engine fires this event
            // during start(), so awaiting here crashed the moment sync was
            // switched on.
            Task.detached { [weak self] in
                try? await self?.resyncEverything()
            }
        case .switchAccounts, .signOut:
            // Do not push one person's timeline into another's account.
            try? await database.clearChangeLog()
            try? await database.clearCloudRecordArchives()
            try? await database.setSyncStateData(Self.stateKey, nil)
            stop()
        @unknown default:
            break
        }
    }
}
