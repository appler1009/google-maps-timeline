import Foundation
import CoreLocation
import Observation

extension Notification.Name {
    /// The recorder wrote something; the store should reload from the library.
    static let timelineLibraryChanged = Notification.Name("timelineLibraryChanged")
    /// A stay was recorded and its place has no name yet.
    static let timelineWantsPlaceName = Notification.Name("timelineWantsPlaceName")
}

/// Turns what the phone noticed into rows in the library.
///
/// Everything it decides lives in `PlaceClusterer`, `MotionSegmenter` and
/// `VisitNotificationPolicy`; this owns the I/O and the order of operations. It
/// must be safe to build and run with no UI on screen, because iOS relaunches the
/// app in the background for a visit or a significant location change.
@MainActor
@Observable
final class TimelineRecorder {
    static let shared = TimelineRecorder()

    private(set) var lastStopAt: Date?
    /// Stays recorded since this process started. Useful in a log, misleading in
    /// the UI — iOS relaunches the app in the background constantly, so it says
    /// far more about the last relaunch than about the day.
    private(set) var recordedVisitCount = 0
    private(set) var isRunning = false

    private let database: TimelineDatabase
    private let stops: StopSource
    private let motion: MotionSource
    private let settings: TrackingSettings
    private let health: HealthSource?
    private let guesser: any PlaceGuessing
    private let ranker: any PlaceRanking
    /// Injectable so the quiet-hours and daily-cap paths are testable at any hour.
    private let now: () -> Date
    private var fixBuffer: [CapturedFix] = []
    private var flushTask: Task<Void, Never>?

    /// How far back a wake will look when the library has never been marked.
    private static let coldBackfill: TimeInterval = 24 * 60 * 60
    /// Core Motion keeps about a week; asking for more returns nothing useful.
    private static let maximumBackfill: TimeInterval = 6.5 * 24 * 60 * 60
    private static let fixRetention: TimeInterval = 7 * 24 * 60 * 60

    init(
        database: TimelineDatabase? = nil,
        stops: StopSource? = nil,
        motion: MotionSource? = nil,
        settings: TrackingSettings? = nil,
        health: HealthSource? = nil,
        guesser: any PlaceGuessing = PlaceGuessService(),
        ranker: (any PlaceRanking)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.database = database ?? TimelineDatabase()
        self.settings = settings ?? TrackingSettings.shared
        self.guesser = guesser
        self.ranker = ranker ?? ModelPlaceRanker(chooser: PlaceChooserFactory.make())
        self.now = now
        #if os(iOS)
        self.stops = stops ?? DeviceLocationSource()
        self.motion = motion ?? DeviceMotionSource()
        self.health = health ?? DeviceHealthSource()
        #else
        // The Mac reads the library but cannot record; without injected sources
        // this recorder is inert by construction.
        self.stops = stops ?? InertStopSource()
        self.motion = motion ?? InertMotionSource()
        self.health = health
        #endif
        self.stops.onStop = { [weak self] stop in
            Task { @MainActor in await self?.handle(stop: stop) }
        }
        self.stops.onFix = { [weak self] fix in
            Task { @MainActor in self?.handle(fix: fix) }
        }
    }

    // MARK: - Lifecycle

    func start() {
        let mode = settings.mode
        guard mode.isRecording else {
            stop()
            return
        }
        isRunning = true
        stops.start(mode: mode)
        if mode.tracksFinePaths {
            motion.startLiveUpdates { [weak self] sample in
                Task { @MainActor in
                    self?.stops.setLiveTracing(sample.kind.isMoving)
                }
            }
        } else {
            motion.stopLiveUpdates()
        }
        Task { await catchUp() }
    }

    func stop() {
        isRunning = false
        flushTask?.cancel()
        stops.stop()
        motion.stopLiveUpdates()
    }

    func restart() {
        stop()
        start()
    }

    /// Run on every wake and every foreground: close out anything Core Motion
    /// recorded while we were not running, then tidy.
    func catchUp() async {
        guard settings.mode.isRecording else { return }
        await backfillMotion()
        await flushFixes()
        await enrichFromHealth()
        await reconcileIfDue()
        try? await database.pruneFixes(before: now().addingTimeInterval(-Self.fixRetention))
        await deliverHeldSummaryIfNeeded()
    }

    /// The raw counters behind the Status rows. A stay is only written when it
    /// closes, so "none recorded" and "nothing is working" look identical from
    /// the outside — these are what tell them apart.
    struct Diagnostics: Equatable {
        var openStayStart: Date?
        var staysToday = 0
        var staysTotal = 0
        var fixesToday = 0
        var fixesTotal = 0
        var motionMark: Date?
        var fixMark: Date?
        var pendingSync = 0
    }

    func diagnostics(calendar: Calendar = .current) async -> Diagnostics {
        let dayStart = calendar.startOfDay(for: now())
        var report = Diagnostics()
        report.openStayStart = (try? await database.openStop())??.stop.start
        report.staysToday = (try? await database.recordedVisitCount(since: dayStart)) ?? 0
        report.staysTotal = (try? await database.recordedVisitCount(since: .distantPast)) ?? 0
        report.fixesToday = (try? await database.fixCount(since: dayStart)) ?? 0
        report.fixesTotal = (try? await database.fixCount()) ?? 0
        report.motionMark = (try? await database.captureMark(CaptureMark.motion)) ?? nil
        report.fixMark = (try? await database.captureMark(CaptureMark.fixes)) ?? nil
        report.pendingSync = (try? await database.pendingChangeCount()) ?? 0
        return report
    }

    /// What the Status row shows: stays recorded today, from the library.
    func recordedToday(calendar: Calendar = .current) async -> Int {
        let start = calendar.startOfDay(for: now())
        return (try? await database.recordedVisitCount(since: start)) ?? 0
    }

    // MARK: - Stays

    func handle(stop: CapturedStop) async {
        lastStopAt = now()
        let anchors = (try? await database.placeAnchors()) ?? []
        let known = try? await database.openStop()

        // A stay we are already inside keeps the key it was given, so closing it
        // updates one row instead of opening a second place next to the first.
        let placeKey: String
        let match: PlaceClusterer.Match
        if let known, abs(known.stop.start.timeIntervalSince(stop.start)) < 60 {
            placeKey = known.placeKey
            let anchor = anchors.first { $0.placeKey == known.placeKey }
            match = PlaceClusterer.Match(placeKey: known.placeKey, isNew: anchor == nil, anchor: anchor)
        } else {
            match = PlaceClusterer.match(stop, among: anchors)
            placeKey = match.placeKey
        }

        guard stop.isClosed else {
            try? await database.setOpenStop(stop, placeKey: placeKey)
            TimelineLog.info("stay opened", ["placeKey": placeKey])
            return
        }

        guard let visit = PlaceClusterer.visit(for: stop, placeKey: placeKey) else { return }
        do {
            try await database.record(batch: TimelineBatch(visits: [visit], activities: [], paths: []))
            try? await database.clearOpenStop()
            recordedVisitCount += 1
            TimelineLog.info(
                "stay recorded",
                ["placeKey": placeKey, "minutes": "\(Int(stop.duration / 60))", "new": "\(match.isNew)"]
            )
        } catch {
            TimelineLog.error("stay write failed", ["error": error.localizedDescription])
            return
        }
        NotificationCenter.default.post(name: .timelineLibraryChanged, object: nil)

        await considerNotifying(stop: stop, match: match, anchors: anchors)
    }

    private func considerNotifying(
        stop: CapturedStop,
        match: PlaceClusterer.Match,
        anchors: [PlaceAnchor]
    ) async {
        guard settings.notifiesVisits else { return }
        let context = VisitNotificationPolicy.Context(
            stop: stop,
            match: match,
            isNamed: match.anchor?.isNamed ?? false,
            sentToday: settings.sentToday(now: now()),
            now: now()
        )
        switch VisitNotificationPolicy.decide(context) {
        case .silent(let reason):
            TimelineLog.debug("visit notification skipped", ["reason": reason])
        case .hold(let reason):
            TimelineLog.info("visit notification held", ["reason": reason])
            settings.hold(match.placeKey)
        case .notify:
            let names = (try? await database.loadPlaceNames()) ?? [:]
            let visited = PlaceGuessRanker.visitedRows(
                near: stop.coordinate,
                places: anchors.compactMap { anchor in
                    guard let name = names[anchor.placeKey], !name.isEmpty else { return nil }
                    return (
                        id: anchor.placeKey,
                        title: name,
                        visitCount: anchor.visitCount,
                        coordinate: anchor.coordinate
                    )
                },
                excluding: match.placeKey
            )
            // Ask for a shortlist rather than the final two: ranking has to see
            // more than it will show.
            let candidates = await guesser.guesses(
                around: stop.coordinate,
                visited: visited,
                limit: ModelPlaceRanker.shortlistSize + 3
            )
            let context = await namingContext(for: stop, placeKey: match.placeKey)
            // Turning the model off leaves the measured ranking, which is what
            // every device without Apple Intelligence gets anyway.
            let active: any PlaceRanking = settings.usesOnDeviceModel ? ranker : HeuristicPlaceRanker()
            let guesses = Array(await active.rank(candidates, context: context).prefix(2))
            let area = await guesser.address(at: stop.coordinate)?.subtitle
            #if os(iOS)
            await VisitNotifier.shared.notify(
                stop: stop,
                placeKey: match.placeKey,
                guesses: guesses,
                areaHint: area
            )
            settings.recordSent(now: now())
            #endif
            NotificationCenter.default.post(name: .timelineWantsPlaceName, object: match.placeKey)
        }
    }

    /// Everything the ranker gets to reason about, read once per notification.
    private func namingContext(for stop: CapturedStop, placeKey: String) async -> VisitNamingContext {
        let end = stop.end ?? now()
        let weekAgo = end.addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = (try? await database.visits(from: weekAgo, to: end)) ?? []
        let priorHere = (try? await database.visits(
            placeKey: placeKey,
            since: end.addingTimeInterval(-90 * 24 * 60 * 60)
        )) ?? []
        let names = (try? await database.loadPlaceNames()) ?? [:]
        return VisitNamingContextBuilder.build(
            stop: stop,
            placeKey: placeKey,
            recentVisits: recent,
            priorVisitsHere: priorHere,
            names: names,
            calendar: .current
        )
    }

    // MARK: - Fixes and movement

    private func handle(fix: CapturedFix) {
        fixBuffer.append(fix)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)
            self?.flushTask = nil
            await self?.flushFixes()
        }
    }

    private func flushFixes() async {
        let pending = fixBuffer
        fixBuffer = []
        guard !pending.isEmpty else { return }
        try? await database.appendFixes(pending)
        if let last = pending.map(\.timestamp).max() {
            try? await database.setCaptureMark(CaptureMark.fixes, through: last)
        }
    }

    /// The inversion the whole design rests on: we did not stream anything, we
    /// woke up and asked the coprocessor what it saw.
    private func backfillMotion() async {
        guard settings.mode.tracksMovement, motion.isAvailable else { return }
        let now = now()
        let mark = (try? await database.captureMark(CaptureMark.motion)) ?? nil
        let earliest = now.addingTimeInterval(-Self.maximumBackfill)
        let from = max(mark ?? now.addingTimeInterval(-Self.coldBackfill), earliest)
        guard now.timeIntervalSince(from) > 60 else { return }

        let samples = await motion.samples(from: from, to: now)
        let trips = MotionSegmenter.trips(from: samples, through: now)
        guard !trips.isEmpty else {
            try? await database.setCaptureMark(CaptureMark.motion, through: now)
            return
        }
        let fixes = (try? await database.fixes(from: from, to: now)) ?? []
        let batch = TimelineBatch(
            visits: [],
            activities: MotionSegmenter.activities(for: trips, fixes: fixes),
            paths: MotionSegmenter.paths(for: trips, fixes: fixes)
        )
        do {
            try await database.record(batch: batch)
            // Only mark through the last trip we closed: the tail of the window is
            // probably still in progress and will be re-read on the next wake.
            try await database.setCaptureMark(CaptureMark.motion, through: trips.last?.end ?? now)
            TimelineLog.info(
                "movement backfilled",
                ["trips": "\(trips.count)", "paths": "\(batch.paths.count)"]
            )
            NotificationCenter.default.post(name: .timelineLibraryChanged, object: nil)
        } catch {
            TimelineLog.error("movement write failed", ["error": error.localizedDescription])
        }
    }

    /// Ask HealthKit for permission, and start watching for workouts if granted.
    @discardableResult
    func enableHealth() async -> Bool {
        guard let health, health.isAvailable else { return false }
        let granted = await health.requestAuthorization()
        settings.usesHealth = granted
        if granted {
            #if os(iOS)
            (health as? DeviceHealthSource)?.startObserving {
                Task { @MainActor in await TimelineRecorder.shared.catchUp() }
            }
            #endif
            await enrichFromHealth()
        }
        return granted
    }

    /// The Watch's actual contribution: exact routes for workouts, and the
    /// passive cycling distance that overrules Core Motion's worst guess.
    private func enrichFromHealth() async {
        guard settings.usesHealth, settings.mode.tracksMovement, let health, health.isAvailable else { return }
        let now = now()
        let mark = (try? await database.captureMark(CaptureMark.health)) ?? nil
        let from = mark ?? now.addingTimeInterval(-Self.maximumBackfill)
        guard now.timeIntervalSince(from) > 60 else { return }

        let workouts = await health.workouts(from: from, to: now)
        let batch = HealthEnrichment.batch(for: workouts)
        if !batch.activities.isEmpty {
            try? await database.record(batch: batch)
        }

        let samples = await health.distances(from: from, to: now)
        let stored = (try? await database.activities(from: from, to: now)) ?? []
        let corrected = HealthEnrichment.corrected(stored, using: samples)
        let original = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.kind.stored) })
        let changed = corrected.filter { original[$0.id] != $0.kind.stored }
        if !changed.isEmpty {
            try? await database.record(batch: TimelineBatch(visits: [], activities: changed, paths: []))
        }

        try? await database.setCaptureMark(CaptureMark.health, through: now)
        guard !batch.activities.isEmpty || !changed.isEmpty else { return }
        TimelineLog.info(
            "health enrichment",
            ["workouts": "\(batch.activities.count)", "recategorised": "\(changed.count)"]
        )
        NotificationCenter.default.post(name: .timelineLibraryChanged, object: nil)
    }

    /// Reconciliation reads the whole visit table, so it runs daily rather than on
    /// every wake. Imports reconcile immediately on their own path.
    private func reconcileIfDue() async {
        let last = (try? await database.captureMark(CaptureMark.reconcile)) ?? nil
        if let last, now().timeIntervalSince(last) < 20 * 60 * 60 { return }
        guard let plan = try? await database.reconcileSources() else { return }
        try? await database.setCaptureMark(CaptureMark.reconcile, through: now())
        guard !plan.isEmpty else { return }
        TimelineLog.info(
            "library reconciled",
            ["shadowed": "\(plan.shadowedVisitIDs.count)", "aliases": "\(plan.placeAliases.count)"]
        )
        NotificationCenter.default.post(name: .timelineLibraryChanged, object: nil)
    }

    private func deliverHeldSummaryIfNeeded() async {
        let held = settings.heldPlaceKeys
        guard !held.isEmpty, !VisitNotificationPolicy.isQuiet(now()) else { return }
        #if os(iOS)
        await VisitNotifier.shared.notifyHeldSummary(count: held.count)
        #endif
        settings.clearHeld()
    }
}

/// Stand-ins so the recorder compiles and stays inert where there is nothing to
/// record from.
final class InertStopSource: StopSource {
    var onStop: ((CapturedStop) -> Void)?
    var onFix: ((CapturedFix) -> Void)?
    func start(mode: TrackingMode) {}
    func stop() {}
    func setLiveTracing(_ enabled: Bool) {}
}

final class InertMotionSource: MotionSource {
    var isAvailable: Bool { false }
    func samples(from: Date, to: Date) async -> [MotionSample] { [] }
    func startLiveUpdates(_ handler: @escaping (MotionSample) -> Void) {}
    func stopLiveUpdates() {}
}
