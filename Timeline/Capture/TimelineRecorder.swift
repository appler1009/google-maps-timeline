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
    private(set) var recordedVisitCount = 0
    private(set) var isRunning = false

    private let database: TimelineDatabase
    private let stops: StopSource
    private let motion: MotionSource
    private let settings: TrackingSettings
    private let guesser: PlaceGuessService
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
        guesser: PlaceGuessService = PlaceGuessService()
    ) {
        self.database = database ?? TimelineDatabase()
        self.settings = settings ?? TrackingSettings.shared
        self.guesser = guesser
        #if os(iOS)
        self.stops = stops ?? DeviceLocationSource()
        self.motion = motion ?? DeviceMotionSource()
        #else
        // The Mac reads the library but cannot record; without injected sources
        // this recorder is inert by construction.
        self.stops = stops ?? InertStopSource()
        self.motion = motion ?? InertMotionSource()
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
        try? await database.pruneFixes(before: Date().addingTimeInterval(-Self.fixRetention))
        await deliverHeldSummaryIfNeeded()
    }

    // MARK: - Stays

    func handle(stop: CapturedStop) async {
        lastStopAt = Date()
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
            sentToday: settings.sentToday(),
            now: Date()
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
            let guesses = await guesser.guesses(around: stop.coordinate, visited: visited)
            let area = await guesser.address(at: stop.coordinate)?.subtitle
            #if os(iOS)
            await VisitNotifier.shared.notify(
                stop: stop,
                placeKey: match.placeKey,
                guesses: guesses,
                areaHint: area
            )
            settings.recordSent()
            #endif
            NotificationCenter.default.post(name: .timelineWantsPlaceName, object: match.placeKey)
        }
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
        let now = Date()
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

    private func deliverHeldSummaryIfNeeded() async {
        let held = settings.heldPlaceKeys
        guard !held.isEmpty, !VisitNotificationPolicy.isQuiet(Date()) else { return }
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
