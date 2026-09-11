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
    private var zoneCreated = false

    /// Rows the engine is currently sending, so the acknowledgement can name them
    /// precisely rather than clearing whatever happens to be queued.
    private var inFlight: [String: PendingChange] = [:]

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
    func resyncEverything() async throws {
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
            inFlight[change.rowID] = change
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
        let records = recordsByName(from: batch)

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            records[recordID.recordName]
        }
    }

    /// The rows a batch names, keyed by record name so the engine's provider can
    /// answer in constant time.
    private func recordsByName(from batch: ChangeBatch) -> [String: CKRecord] {
        var records: [String: CKRecord] = [:]
        for visit in batch.visits {
            records[visit.id] = TimelineRecordMapper.record(for: visit, in: zoneID)
        }
        for activity in batch.activities {
            records[activity.id] = TimelineRecordMapper.record(for: activity, in: zoneID)
        }
        for path in batch.paths {
            records[path.id] = TimelineRecordMapper.record(for: path, in: zoneID)
        }
        for (key, name) in batch.names {
            records[key] = TimelineRecordMapper.record(forPlaceKey: key, name: name, in: zoneID)
        }
        for (key, merge) in batch.merges {
            records[key] = TimelineRecordMapper.record(forPlaceKey: key, merge: merge, in: zoneID)
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
        try? await database.applyRemote(parsed.rows)
        for (key, name) in parsed.names {
            _ = try? await database.applyPlaceNameIfNewer(
                placeKey: key,
                name: name.name,
                updatedAt: name.updatedAt
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
            guard let kind = TimelineRecordMapper.kind(forRecordType: deletion.recordType) else { continue }
            try? await database.applyRemoteDeletion(kind: kind, rowID: deletion.recordID.recordName)
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
        let saved = sent.savedRecords.map(\.recordID.recordName) + sent.deletedRecordIDs.map(\.recordName)
        let acknowledged = saved.compactMap { inFlight[$0] }
        if !acknowledged.isEmpty {
            try? await database.acknowledge(acknowledged)
            for name in saved { inFlight.removeValue(forKey: name) }
        }

        for failure in sent.failedRecordSaves {
            let name = failure.record.recordID.recordName
            inFlight.removeValue(forKey: name)
            // A row left in the change log is retried on the next send, which is
            // the right answer for a rate limit or a dropped connection.
            TimelineLog.error(
                "cloud sync record failed",
                ["record": name, "error": failure.error.localizedDescription]
            )
        }

        if !acknowledged.isEmpty {
            TimelineLog.info("cloud sync sent", ["records": "\(acknowledged.count)"])
        }
        // Drain whatever the change log gained while this batch was in flight.
        await enqueuePendingChanges()
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            // A fresh account has none of this library, so offer all of it.
            try? await resyncEverything()
        case .switchAccounts, .signOut:
            // Do not push one person's timeline into another's account.
            try? await database.clearChangeLog()
            try? await database.setSyncStateData(Self.stateKey, nil)
            stop()
        @unknown default:
            break
        }
    }
}
