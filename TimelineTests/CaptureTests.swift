import CoreLocation
import XCTest
@testable import Timeline

/// Vancouver, so distances read as something a person could walk.
private let home = CLLocationCoordinate2D(latitude: 49.2765, longitude: -123.0680)

private func offset(_ base: CLLocationCoordinate2D, metersNorth: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: base.latitude + metersNorth / 111_320,
        longitude: base.longitude
    )
}

private func stop(
    at coordinate: CLLocationCoordinate2D = home,
    accuracy: CLLocationAccuracy = 65,
    start: Date,
    minutes: Double?
) -> CapturedStop {
    CapturedStop(
        coordinate: coordinate,
        horizontalAccuracy: accuracy,
        start: start,
        end: minutes.map { start.addingTimeInterval($0 * 60) }
    )
}

final class PlaceClustererTests: XCTestCase {
    private let anchors = [
        PlaceAnchor(placeKey: "cafe", coordinate: home, visitCount: 12, isNamed: true),
        PlaceAnchor(
            placeKey: "bank",
            coordinate: offset(home, metersNorth: 90),
            visitCount: 1,
            isNamed: false
        ),
    ]

    func testSnapsToKnownPlaceWithinRadius() {
        let sample = stop(at: offset(home, metersNorth: 40), start: .now, minutes: 30)
        let match = PlaceClusterer.match(sample, among: anchors)
        XCTAssertEqual(match.placeKey, "cafe")
        XCTAssertFalse(match.isNew)
        XCTAssertEqual(match.anchor?.isNamed, true)
    }

    func testOpensNewPlaceBeyondRadius() {
        let sample = stop(at: offset(home, metersNorth: 400), start: .now, minutes: 30)
        let match = PlaceClusterer.match(sample, among: anchors)
        XCTAssertTrue(match.isNew)
        XCTAssertNil(match.anchor)
        XCTAssertEqual(match.placeKey, Geo.placeKey(id: nil, coordinate: sample.coordinate))
    }

    func testRadiusGrowsWithAccuracyButIsCapped() {
        XCTAssertEqual(PlaceClusterer.radius(for: 10), PlaceClusterer.minimumRadius)
        XCTAssertEqual(PlaceClusterer.radius(for: 120), 120)
        XCTAssertEqual(PlaceClusterer.radius(for: 5_000), PlaceClusterer.maximumRadius)
    }

    func testNearTiesPreferTheMoreVisitedPlace() {
        // Halfway between the two anchors: a daily stop should win over a one-off
        // that happens to sit the same distance away.
        let sample = stop(at: offset(home, metersNorth: 45), accuracy: 150, start: .now, minutes: 30)
        XCTAssertEqual(PlaceClusterer.match(sample, among: anchors).placeKey, "cafe")
    }

    func testVisitIDIsStableAndDistinctFromImports() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = PlaceClusterer.visitID(placeKey: "cafe", start: start)
        XCTAssertEqual(first, PlaceClusterer.visitID(placeKey: "cafe", start: start))
        XCTAssertNotEqual(first, Geo.segmentID("v", Geo.millis(start), "cafe"))
    }

    func testOpenStopMakesNoVisit() {
        let open = stop(start: .now, minutes: nil)
        XCTAssertNil(PlaceClusterer.visit(for: open, placeKey: "cafe"))
    }
}

final class MotionSegmenterTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ minutes: Double, _ kind: MotionKind, confidence: Int = 2) -> MotionSample {
        MotionSample(start: origin.addingTimeInterval(minutes * 60), kind: kind, confidence: confidence)
    }

    func testPairsSamplesIntoTripsAndDropsStationary() {
        let trips = MotionSegmenter.trips(
            from: [sample(0, .stationary), sample(10, .walking), sample(25, .automotive)],
            through: origin.addingTimeInterval(40 * 60)
        )
        XCTAssertEqual(trips.count, 2)
        XCTAssertEqual(trips[0].kind, .walking)
        XCTAssertEqual(trips[0].duration, 15 * 60)
        XCTAssertEqual(trips[1].kind, .automotive)
        XCTAssertEqual(trips[1].end, origin.addingTimeInterval(40 * 60))
    }

    func testFlickerIsDroppedAndTheWalkStaysOneTrip() {
        // One stray 30-second "stationary" in the middle of a walk must not split
        // the walk into two trips.
        let trips = MotionSegmenter.trips(
            from: [
                sample(0, .walking),
                sample(10, .stationary),
                sample(10.5, .walking),
            ],
            through: origin.addingTimeInterval(20 * 60)
        )
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].kind, .walking)
        XCTAssertEqual(trips[0].start, origin)
        XCTAssertEqual(trips[0].end, origin.addingTimeInterval(20 * 60))
    }

    func testShortMovesAreNotTrips() {
        let trips = MotionSegmenter.trips(
            from: [sample(0, .walking), sample(1, .stationary)],
            through: origin.addingTimeInterval(30 * 60)
        )
        XCTAssertTrue(trips.isEmpty)
    }

    func testLowConfidenceUnknownIsIgnored() {
        let trips = MotionSegmenter.trips(
            from: [sample(0, .unknown, confidence: 0), sample(5, .cycling)],
            through: origin.addingTimeInterval(30 * 60)
        )
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].kind, .cycling)
    }

    func testActivityMeasuresTheFixesInsideTheTrip() {
        let trip = MotionTrip(
            start: origin,
            end: origin.addingTimeInterval(20 * 60),
            kind: .walking
        )
        let fixes = (0...4).map { step in
            CapturedFix(
                coordinate: offset(home, metersNorth: Double(step) * 200),
                timestamp: origin.addingTimeInterval(Double(step) * 4 * 60),
                horizontalAccuracy: 20,
                speed: 1.3
            )
        }
        let activity = MotionSegmenter.activities(for: [trip], fixes: fixes)[0]
        XCTAssertEqual(activity.kind, .walking)
        XCTAssertEqual(activity.distance, 800, accuracy: 5)
        XCTAssertNotNil(activity.startCoordinate)
        XCTAssertNotNil(activity.endCoordinate)
    }

    func testTripWithoutFixesStillCountsAsTypedTravel() {
        let trip = MotionTrip(start: origin, end: origin.addingTimeInterval(15 * 60), kind: .automotive)
        let activity = MotionSegmenter.activities(for: [trip], fixes: [])[0]
        XCTAssertEqual(activity.kind, .automobile)
        XCTAssertEqual(activity.distance, 0)
        XCTAssertNil(activity.startCoordinate)
        XCTAssertTrue(MotionSegmenter.paths(for: [trip], fixes: []).isEmpty)
    }

    func testPathThinningKeepsTheEnds() {
        let fixes = (0...10).map { step in
            CapturedFix(
                coordinate: offset(home, metersNorth: Double(step) * 5),
                timestamp: origin.addingTimeInterval(Double(step) * 30),
                horizontalAccuracy: 10,
                speed: 1
            )
        }
        let thinned = MotionSegmenter.thinned(fixes)
        XCTAssertLessThan(thinned.count, fixes.count)
        XCTAssertEqual(thinned.first?.timestamp, fixes.first?.timestamp)
        XCTAssertEqual(thinned.last?.timestamp, fixes.last?.timestamp)
    }

    func testDistanceIgnoresTeleportsAcrossASleepGap() {
        let near = CapturedFix(coordinate: home, timestamp: origin, horizontalAccuracy: 20, speed: 0)
        let far = CapturedFix(
            coordinate: offset(home, metersNorth: 50_000),
            timestamp: origin.addingTimeInterval(4 * 60 * 60),
            horizontalAccuracy: 20,
            speed: 0
        )
        XCTAssertEqual(MotionSegmenter.distance(of: [near, far]), 0)
    }
}

final class VisitNotificationPolicyTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }()

    private func afternoon(_ hour: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: hour))!
    }

    private func context(
        minutes: Double = 45,
        accuracy: CLLocationAccuracy = 65,
        isNamed: Bool = false,
        sentToday: Int = 0,
        hour: Int = 14
    ) -> VisitNotificationPolicy.Context {
        let start = afternoon(hour)
        return VisitNotificationPolicy.Context(
            stop: stop(accuracy: accuracy, start: start, minutes: minutes),
            match: PlaceClusterer.Match(placeKey: "somewhere", isNew: true, anchor: nil),
            isNamed: isNamed,
            sentToday: sentToday,
            now: start.addingTimeInterval(minutes * 60),
            calendar: calendar
        )
    }

    func testNotifiesForALongStayAtAnUnnamedPlace() {
        XCTAssertEqual(VisitNotificationPolicy.decide(context()), .notify)
    }

    func testNamedPlacesStayQuiet() {
        // The rule that keeps home and work from ever sending a notification.
        guard case .silent = VisitNotificationPolicy.decide(context(isNamed: true)) else {
            return XCTFail("a named place must never notify")
        }
    }

    func testShortStaysStayQuiet() {
        guard case .silent = VisitNotificationPolicy.decide(context(minutes: 4)) else {
            return XCTFail("a four-minute stay is not worth a banner")
        }
    }

    func testCoarseFixesStayQuiet() {
        guard case .silent = VisitNotificationPolicy.decide(context(accuracy: 900)) else {
            return XCTFail("a 900 m fix cannot suggest a place")
        }
    }

    func testOverTheDailyCapItIsHeldNotDropped() {
        guard case .hold = VisitNotificationPolicy.decide(context(sentToday: 3)) else {
            return XCTFail("past the cap a stay should be held for the summary")
        }
    }

    func testQuietHoursHold() {
        guard case .hold = VisitNotificationPolicy.decide(context(hour: 23)) else {
            return XCTFail("a stay ending at 23:45 should not buzz")
        }
        XCTAssertTrue(VisitNotificationPolicy.isQuiet(afternoon(2), calendar: calendar))
        XCTAssertFalse(VisitNotificationPolicy.isQuiet(afternoon(9), calendar: calendar))
    }

    func testOpenStaysAreNeverAnnounced() {
        let open = VisitNotificationPolicy.Context(
            stop: stop(start: afternoon(), minutes: nil),
            match: PlaceClusterer.Match(placeKey: "somewhere", isNew: true, anchor: nil),
            isNamed: false,
            sentToday: 0,
            now: afternoon(15),
            calendar: calendar
        )
        guard case .silent = VisitNotificationPolicy.decide(open) else {
            return XCTFail("an open stay has no duration to report")
        }
    }

    func testDurationPhraseReadsLikeSomethingThatHappened() {
        XCTAssertEqual(VisitNotificationPolicy.durationPhrase(47 * 60), "47 minutes")
        XCTAssertEqual(VisitNotificationPolicy.durationPhrase(60 * 60), "1 hour")
        XCTAssertEqual(VisitNotificationPolicy.durationPhrase(95 * 60), "1h 35m")
    }
}

final class PlaceGuessRankerTests: XCTestCase {
    func testVisitedPlacesOutrankMapResultsAndNamesAreDeduped() {
        let visited = PlaceGuessRanker.visitedRows(
            near: home,
            places: [
                (id: "a", title: "Continental Coffee", visitCount: 9, coordinate: offset(home, metersNorth: 30)),
                (id: "b", title: "JJ Bean", visitCount: 2, coordinate: offset(home, metersNorth: 10)),
                (id: "c", title: "Too Far", visitCount: 40, coordinate: offset(home, metersNorth: 4_000)),
            ],
            excluding: "self"
        )
        XCTAssertEqual(visited.map(\.title), ["Continental Coffee", "JJ Bean"])

        let map = [
            PlaceNameSuggestion(
                id: "poi:1",
                title: "continental coffee",
                subtitle: "Cafe",
                source: .map,
                visitCount: 0,
                distanceMeters: 12,
                targetPlaceID: nil
            ),
            PlaceNameSuggestion(
                id: "poi:2",
                title: "Grandview Park",
                subtitle: "Park",
                source: .map,
                visitCount: 0,
                distanceMeters: 80,
                targetPlaceID: nil
            ),
        ]
        let merged = PlaceGuessRanker.merge(visited: visited, map: map)
        XCTAssertEqual(merged.map(\.title), ["Continental Coffee", "JJ Bean", "Grandview Park"])
        XCTAssertEqual(merged.first?.targetPlaceID, "a")
    }
}

// MARK: - Scripted sources

final class ScriptedStopSource: StopSource {
    var onStop: ((CapturedStop) -> Void)?
    var onFix: ((CapturedFix) -> Void)?
    private(set) var startedMode: TrackingMode?
    private(set) var isTracing = false

    func start(mode: TrackingMode) { startedMode = mode }
    func stop() { startedMode = nil }
    func setLiveTracing(_ enabled: Bool) { isTracing = enabled }

    func emit(_ stop: CapturedStop) { onStop?(stop) }
    func emit(_ fix: CapturedFix) { onFix?(fix) }
}

final class ScriptedMotionSource: MotionSource {
    var scripted: [MotionSample] = []
    private var liveHandler: ((MotionSample) -> Void)?
    private(set) var isLive = false

    var isAvailable: Bool { true }
    func samples(from: Date, to: Date) async -> [MotionSample] {
        scripted.filter { $0.start >= from && $0.start <= to }
    }
    func startLiveUpdates(_ handler: @escaping (MotionSample) -> Void) {
        liveHandler = handler
        isLive = true
    }
    func stopLiveUpdates() {
        liveHandler = nil
        isLive = false
    }

    /// Drive a motion transition the way Core Motion would.
    func emit(_ kind: MotionKind) {
        liveHandler?(MotionSample(start: Date(), kind: kind, confidence: 2))
    }
}

final class CaptureDatabaseTests: XCTestCase {
    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    func testRecordedVisitsLoadBackAlongsideImports() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let imported = TimelineVisit(
            id: Geo.segmentID("v", Geo.millis(start), "google-place"),
            start: start,
            end: start.addingTimeInterval(3_600),
            coordinate: home,
            semanticType: "Home",
            placeKey: "google-place"
        )
        try await db.upsert(
            batch: TimelineBatch(visits: [imported], activities: [], paths: []),
            sourceName: "Timeline.json"
        )

        let recordedStart = start.addingTimeInterval(7_200)
        let recorded = PlaceClusterer.visit(
            for: stop(start: recordedStart, minutes: 30),
            placeKey: "device-place"
        )!
        try await db.record(batch: TimelineBatch(visits: [recorded], activities: [], paths: []))

        let batch = try await db.loadBatch()
        XCTAssertEqual(batch?.visits.count, 2)
        // The import is still what names the library.
        let sourceName = try await db.latestSourceName()
        XCTAssertEqual(sourceName, "Timeline.json")
    }

    func testPlaceAnchorsCountVisitsAndKnowWhatIsNamed() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let visits = (0..<3).map { index in
            TimelineVisit(
                id: "v\(index)",
                start: start.addingTimeInterval(Double(index) * 86_400),
                end: start.addingTimeInterval(Double(index) * 86_400 + 3_600),
                coordinate: home,
                semanticType: nil,
                placeKey: "cafe"
            )
        }
        try await db.record(batch: TimelineBatch(visits: visits, activities: [], paths: []))

        var anchors = try await db.placeAnchors()
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors[0].visitCount, 3)
        XCTAssertFalse(anchors[0].isNamed)

        try await db.setPlaceName(placeKey: "cafe", name: "Continental Coffee")
        anchors = try await db.placeAnchors()
        XCTAssertTrue(anchors[0].isNamed)
    }

    func testOpenStopSurvivesAColdLaunch() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.setOpenStop(stop(start: start, minutes: nil), placeKey: "cafe")

        // A second handle is what a background relaunch really gets.
        let reopened = TimelineDatabase(fileURL: url)
        let open = try await reopened.openStop()
        XCTAssertEqual(open?.placeKey, "cafe")
        XCTAssertEqual(open?.stop.start, start)

        try await reopened.clearOpenStop()
        let cleared = try await reopened.openStop()
        XCTAssertNil(cleared)
    }

    func testCaptureMarkOnlyEverMovesForward() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let later = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.setCaptureMark(CaptureMark.motion, through: later)
        try await db.setCaptureMark(CaptureMark.motion, through: later.addingTimeInterval(-3_600))
        let mark = try await db.captureMark(CaptureMark.motion)
        XCTAssertEqual(mark, later)
    }

    func testFixesRoundTripAndPrune() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fixes = (0..<5).map { step in
            CapturedFix(
                coordinate: offset(home, metersNorth: Double(step) * 100),
                timestamp: start.addingTimeInterval(Double(step) * 60),
                horizontalAccuracy: 15,
                speed: 4
            )
        }
        try await db.appendFixes(fixes)
        let stored = try await db.fixes(from: start, to: start.addingTimeInterval(600))
        XCTAssertEqual(stored.count, 5)

        try await db.pruneFixes(before: start.addingTimeInterval(150))
        let kept = try await db.fixes(from: start, to: start.addingTimeInterval(600))
        XCTAssertEqual(kept.count, 2)
    }
}

@MainActor
final class TimelineRecorderTests: XCTestCase {
    private func makeRecorder(
        mode: TrackingMode = .balanced
    ) -> (TimelineRecorder, ScriptedStopSource, ScriptedMotionSource, TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString).sqlite")
        let database = TimelineDatabase(fileURL: url)
        let stops = ScriptedStopSource()
        let motion = ScriptedMotionSource()
        let defaults = UserDefaults(suiteName: "recorder-\(UUID().uuidString)")!
        let settings = TrackingSettings(defaults: defaults)
        settings.mode = mode
        settings.notifiesVisits = false
        let recorder = TimelineRecorder(
            database: database,
            stops: stops,
            motion: motion,
            settings: settings
        )
        return (recorder, stops, motion, database, url)
    }

    func testAClosedStayBecomesAVisit() async throws {
        let (recorder, stops, _, database, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        await recorder.handle(stop: stop(start: start, minutes: 45))
        _ = stops

        let batch = try await database.loadBatch()
        XCTAssertEqual(batch?.visits.count, 1)
        XCTAssertEqual(batch?.visits.first?.start, start)
        XCTAssertEqual(recorder.recordedVisitCount, 1)
    }

    func testAnOpenStayIsHeldThenClosedAgainstTheSamePlace() async throws {
        let (recorder, _, _, database, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        await recorder.handle(stop: stop(start: start, minutes: nil))
        let open = try await database.openStop()
        XCTAssertNotNil(open)
        let beforeDeparture = try await database.loadBatch()?.visits.first
        XCTAssertNil(beforeDeparture)

        // The departure arrives from a slightly different coordinate, as CLVisit
        // departures do — it must still close the same place, not open a second.
        await recorder.handle(
            stop: stop(at: offset(home, metersNorth: 55), start: start, minutes: 90)
        )
        let stillOpen = try await database.openStop()
        XCTAssertNil(stillOpen)
        let visits = try await database.loadBatch()?.visits ?? []
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(Set(visits.map(\.placeKey)).count, 1)
    }

    func testASecondStayAtTheSamePlaceReusesItsKey() async throws {
        let (recorder, _, _, database, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        await recorder.handle(stop: stop(start: start, minutes: 45))
        await recorder.handle(
            stop: stop(
                at: offset(home, metersNorth: 45),
                start: start.addingTimeInterval(86_400),
                minutes: 30
            )
        )

        let visits = try await database.loadBatch()?.visits ?? []
        XCTAssertEqual(visits.count, 2)
        XCTAssertEqual(Set(visits.map(\.placeKey)).count, 1, "the same café must not splinter into two places")
    }

    func testCatchUpTurnsMotionHistoryIntoTypedTrips() async throws {
        let (recorder, _, motion, database, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        motion.scripted = [
            MotionSample(start: now.addingTimeInterval(-3_600), kind: .stationary, confidence: 2),
            MotionSample(start: now.addingTimeInterval(-2_400), kind: .automotive, confidence: 2),
            MotionSample(start: now.addingTimeInterval(-1_200), kind: .stationary, confidence: 2),
        ]
        try await database.appendFixes(
            (0..<5).map { step in
                CapturedFix(
                    coordinate: offset(home, metersNorth: Double(step) * 500),
                    timestamp: now.addingTimeInterval(-2_400 + Double(step) * 240),
                    horizontalAccuracy: 20,
                    speed: 12
                )
            }
        )

        await recorder.catchUp()

        let batch = try await database.loadBatch()
        XCTAssertEqual(batch?.activities.count, 1)
        XCTAssertEqual(batch?.activities.first?.kind.stored, "automobile")
        XCTAssertEqual(batch?.paths.count, 1)
        let motionMark = try await database.captureMark(CaptureMark.motion)
        XCTAssertNotNil(motionMark)
    }

    func testPlacesOnlyModeRecordsNoMovement() async throws {
        let (recorder, _, motion, database, url) = makeRecorder(mode: .places)
        defer { try? FileManager.default.removeItem(at: url) }

        motion.scripted = [
            MotionSample(start: Date().addingTimeInterval(-3_600), kind: .walking, confidence: 2),
            MotionSample(start: Date().addingTimeInterval(-1_800), kind: .stationary, confidence: 2),
        ]
        await recorder.catchUp()
        let activities = try await database.loadBatch()?.activities ?? []
        XCTAssertTrue(activities.isEmpty)
    }
}

// MARK: - Reconciliation with imported exports

final class TimelineReconcilerTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func visit(
        id: String,
        placeKey: String,
        offsetHours: Double,
        hours: Double,
        coordinate: CLLocationCoordinate2D = home
    ) -> TimelineVisit {
        let start = day.addingTimeInterval(offsetHours * 3_600)
        return TimelineVisit(
            id: id,
            start: start,
            end: start.addingTimeInterval(hours * 3_600),
            coordinate: coordinate,
            semanticType: nil,
            placeKey: placeKey
        )
    }

    func testImportedDaysTheDeviceRecordedAreShadowed() {
        let device = [visit(id: "d1", placeKey: "49.2765,-123.0680", offsetHours: 0, hours: 2)]
        let imported = [
            visit(id: "g1", placeKey: "ChIJ_home", offsetHours: 0.5, hours: 1),
            // A week later, with no recording of its own: untouched.
            visit(id: "g2", placeKey: "ChIJ_other", offsetHours: 24 * 7, hours: 1),
        ]
        let plan = TimelineReconciler.plan(device: device, imported: imported)
        XCTAssertEqual(plan.shadowedVisitIDs, ["g1"])
    }

    func testAnOverlappingImportLendsItsGooglePlaceID() {
        let device = [visit(id: "d1", placeKey: "49.2765,-123.0680", offsetHours: 0, hours: 2)]
        let imported = [visit(
            id: "g1",
            placeKey: "ChIJ_home",
            offsetHours: 0.5,
            hours: 1,
            coordinate: offset(home, metersNorth: 60)
        )]
        let plan = TimelineReconciler.plan(device: device, imported: imported)
        XCTAssertEqual(plan.placeAliases["49.2765,-123.0680"], "ChIJ_home")
    }

    func testFarApartStaysAreNotTheSamePlace() {
        let device = [visit(id: "d1", placeKey: "49.2765,-123.0680", offsetHours: 0, hours: 2)]
        let imported = [visit(
            id: "g1",
            placeKey: "ChIJ_elsewhere",
            offsetHours: 0.5,
            hours: 1,
            coordinate: offset(home, metersNorth: 900)
        )]
        let plan = TimelineReconciler.plan(device: device, imported: imported)
        XCTAssertTrue(plan.placeAliases.isEmpty)
        // Same day, so the import is still shadowed — only the identity is refused.
        XCTAssertEqual(plan.shadowedVisitIDs, ["g1"])
    }

    func testACoordinateKeyIsNotWorthFoldingInto() {
        let device = [visit(id: "d1", placeKey: "49.2765,-123.0680", offsetHours: 0, hours: 2)]
        let imported = [visit(id: "g1", placeKey: "49.2764,-123.0681", offsetHours: 0.5, hours: 1)]
        XCTAssertTrue(TimelineReconciler.plan(device: device, imported: imported).placeAliases.isEmpty)
    }

    func testTheLongerOverlapClaimsTheDeviceKey() {
        let device = [visit(id: "d1", placeKey: "49.2765,-123.0680", offsetHours: 0, hours: 4)]
        let imported = [
            visit(id: "g1", placeKey: "ChIJ_brief", offsetHours: 0, hours: 0.25),
            visit(id: "g2", placeKey: "ChIJ_real", offsetHours: 1, hours: 3),
        ]
        let plan = TimelineReconciler.plan(device: device, imported: imported)
        XCTAssertEqual(plan.placeAliases["49.2765,-123.0680"], "ChIJ_real")
    }

    func testNothingToDoWithoutBothSources() {
        let device = [visit(id: "d1", placeKey: "k", offsetHours: 0, hours: 2)]
        XCTAssertTrue(TimelineReconciler.plan(device: device, imported: []).isEmpty)
        XCTAssertTrue(TimelineReconciler.plan(device: [], imported: device).isEmpty)
    }
}

final class ReconciliationDatabaseTests: XCTestCase {
    func testShadowedImportsAreHiddenButRecoverable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let imported = TimelineVisit(
            id: "g1",
            start: start.addingTimeInterval(1_800),
            end: start.addingTimeInterval(5_400),
            coordinate: offset(home, metersNorth: 50),
            semanticType: "Home",
            placeKey: "ChIJ_home"
        )
        try await db.upsert(
            batch: TimelineBatch(visits: [imported], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        let recorded = PlaceClusterer.visit(
            for: stop(start: start, minutes: 180),
            placeKey: "49.2765,-123.0680"
        )!
        try await db.record(batch: TimelineBatch(visits: [recorded], activities: [], paths: []))

        let plan = try await db.reconcileSources()
        XCTAssertEqual(plan.shadowedVisitIDs, ["g1"])

        let shown = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(shown.count, 1)
        // The device visit now wears Google's place id, courtesy of the alias.
        XCTAssertEqual(shown.first?.placeKey, "ChIJ_home")

        let everything = try await db.loadBatch(includingShadowed: true)?.visits ?? []
        XCTAssertEqual(everything.count, 2, "shadowing must be reversible")
        let hidden = try await db.shadowedVisitCount()
        XCTAssertEqual(hidden, 1)
    }
}

// MARK: - Apple Watch

final class ScriptedHealthSource: HealthSource {
    var workoutsToReturn: [HealthWorkout] = []
    var distancesToReturn: [HealthDistanceSample] = []
    var isAvailable: Bool { true }
    func requestAuthorization() async -> Bool { true }
    func workouts(from: Date, to: Date) async -> [HealthWorkout] { workoutsToReturn }
    func distances(from: Date, to: Date) async -> [HealthDistanceSample] { distancesToReturn }
}

final class HealthEnrichmentTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testAWorkoutRouteBecomesAPathAndATypedActivity() {
        let workout = HealthWorkout(
            id: "abc",
            start: origin,
            end: origin.addingTimeInterval(45 * 60),
            kind: .cycling,
            distanceMeters: 12_400,
            route: (0..<20).map { offset(home, metersNorth: Double($0) * 400) }
        )
        let batch = HealthEnrichment.batch(for: [workout])
        XCTAssertEqual(batch.activities.count, 1)
        XCTAssertEqual(batch.activities[0].kind.stored, "cycling")
        XCTAssertEqual(batch.activities[0].distance, 12_400)
        XCTAssertEqual(batch.paths.count, 1)
        XCTAssertEqual(batch.paths[0].points.count, 20)
    }

    func testAWorkoutWithoutARouteStillCounts() {
        let workout = HealthWorkout(
            id: "abc",
            start: origin,
            end: origin.addingTimeInterval(30 * 60),
            kind: .running,
            distanceMeters: 5_000,
            route: []
        )
        let batch = HealthEnrichment.batch(for: [workout])
        XCTAssertEqual(batch.activities.count, 1)
        XCTAssertTrue(batch.paths.isEmpty)
    }

    func testWatchCyclingDistanceOverrulesCoreMotionsDrivingCall() {
        let driving = TimelineActivity(
            id: "a1",
            start: origin,
            end: origin.addingTimeInterval(20 * 60),
            distance: 3_000,
            startCoordinate: home,
            endCoordinate: offset(home, metersNorth: 3_000),
            kind: .automobile
        )
        let samples = [
            HealthDistanceSample(
                start: origin,
                end: origin.addingTimeInterval(20 * 60),
                meters: 3_200,
                kind: .cycling
            )
        ]
        let corrected = HealthEnrichment.corrected([driving], using: samples)
        XCTAssertEqual(corrected[0].kind.stored, "cycling")
        XCTAssertEqual(corrected[0].id, driving.id, "the correction must update the row, not add one")
    }

    func testARealDriveIsLeftAlone() {
        let driving = TimelineActivity(
            id: "a1",
            start: origin,
            end: origin.addingTimeInterval(20 * 60),
            distance: 18_000,
            startCoordinate: home,
            endCoordinate: offset(home, metersNorth: 18_000),
            kind: .automobile
        )
        // A short walk to the car is not evidence of a bike ride.
        let samples = [
            HealthDistanceSample(
                start: origin,
                end: origin.addingTimeInterval(3 * 60),
                meters: 120,
                kind: .walking
            )
        ]
        XCTAssertEqual(HealthEnrichment.corrected([driving], using: samples)[0].kind.stored, "automobile")
    }

    func testDistanceIsProRatedAcrossTheEdgeOfATrip() {
        let samples = [
            HealthDistanceSample(
                start: origin.addingTimeInterval(-10 * 60),
                end: origin.addingTimeInterval(10 * 60),
                meters: 2_000,
                kind: .cycling
            )
        ]
        let meters = HealthEnrichment.overlappingMeters(
            samples,
            from: origin,
            to: origin.addingTimeInterval(10 * 60)
        )
        XCTAssertEqual(meters, 1_000, accuracy: 1)
    }
}

// MARK: - Change tracking

final class ChangeLogTests: XCTestCase {
    private func database() -> (TimelineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("changelog-\(UUID().uuidString).sqlite")
        return (TimelineDatabase(fileURL: url), url)
    }

    private func sampleVisit(_ id: String, offsetDays: Double = 0) -> TimelineVisit {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + offsetDays * 86_400)
        return TimelineVisit(
            id: id,
            start: start,
            end: start.addingTimeInterval(3_600),
            coordinate: home,
            semanticType: nil,
            placeKey: "cafe"
        )
    }

    func testRecordingAStayQueuesIt() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(batch: TimelineBatch(visits: [sampleVisit("v1")], activities: [], paths: []))
        let pending = try await db.pendingChanges()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].kind, .visit)
        XCTAssertEqual(pending[0].rowID, "v1")
        XCTAssertEqual(pending[0].operation, .upsert)
    }

    func testImportingAlsoQueues() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.upsert(
            batch: TimelineBatch(visits: [sampleVisit("v1"), sampleVisit("v2", offsetDays: 1)], activities: [], paths: []),
            sourceName: "Timeline.json"
        )
        let count = try await db.pendingChangeCount()
        XCTAssertEqual(count, 2)
    }

    func testRenamingAPlaceQueuesTheName() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.setPlaceName(placeKey: "cafe", name: "Continental Coffee")
        let pending = try await db.pendingChanges()
        XCTAssertEqual(pending.map(\.kind), [.placeName])
        XCTAssertEqual(pending[0].rowID, "cafe")
    }

    func testRemoteAppliesDoNotQueue() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        // A name and a merge arriving from iCloud must not be queued straight
        // back out again — that is the echo loop.
        let applied = try await db.applyPlaceNameIfNewer(
            placeKey: "cafe",
            name: "From another device",
            updatedAt: Date().timeIntervalSince1970
        )
        XCTAssertTrue(applied)
        let merged = try await db.applyPlaceMergeIfNewer(
            from: "annex",
            into: "cafe",
            updatedAt: Date().timeIntervalSince1970,
            targetSemantic: nil
        )
        XCTAssertTrue(merged)

        let count = try await db.pendingChangeCount()
        XCTAssertEqual(count, 0, "remote writes must never queue themselves for sending")
    }

    func testALocalMergeDoesQueue() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.mergePlace(from: "annex", into: "cafe", targetSemantic: nil)
        let kinds = Set(try await db.pendingChanges().map(\.kind))
        XCTAssertTrue(kinds.contains(.placeMerge))
    }

    func testAcknowledgingClearsTheQueue() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(batch: TimelineBatch(visits: [sampleVisit("v1")], activities: [], paths: []))
        let pending = try await db.pendingChanges()
        try await db.acknowledge(pending)
        let after = try await db.pendingChangeCount()
        XCTAssertEqual(after, 0)
    }

    func testAnEditDuringSendingSurvivesItsOwnAcknowledgement() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(batch: TimelineBatch(visits: [sampleVisit("v1")], activities: [], paths: []))
        let inFlight = try await db.pendingChanges()

        // The row changes again while the batch is being sent.
        var edited = sampleVisit("v1")
        edited = TimelineVisit(
            id: edited.id,
            start: edited.start,
            end: edited.end.addingTimeInterval(1_800),
            coordinate: edited.coordinate,
            semanticType: edited.semanticType,
            placeKey: edited.placeKey
        )
        try await db.record(batch: TimelineBatch(visits: [edited], activities: [], paths: []))

        try await db.acknowledge(inFlight)
        let still = try await db.pendingChangeCount()
        XCTAssertEqual(still, 1, "the newer edit must not be swallowed by the older ack")
    }

    func testSequenceNumbersAreNeverReused() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(batch: TimelineBatch(visits: [sampleVisit("v1")], activities: [], paths: []))
        let first = try await db.pendingChanges()
        try await db.acknowledge(first)
        // Queue is empty; the counter must not restart.
        try await db.record(batch: TimelineBatch(visits: [sampleVisit("v2", offsetDays: 1)], activities: [], paths: []))
        let second = try await db.pendingChanges()
        XCTAssertGreaterThan(second[0].seq, first[0].seq)
    }

    func testTheBatchCarriesTheRowsThemselves() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.record(
            batch: TimelineBatch(
                visits: [sampleVisit("v1")],
                activities: [
                    TimelineActivity(
                        id: "a1",
                        start: start,
                        end: start.addingTimeInterval(900),
                        distance: 2_000,
                        startCoordinate: home,
                        endCoordinate: offset(home, metersNorth: 2_000),
                        kind: .cycling
                    )
                ],
                paths: [
                    TimelinePath(
                        id: "p1",
                        start: start,
                        end: start.addingTimeInterval(900),
                        points: [home, offset(home, metersNorth: 2_000)],
                        kind: .cycling
                    )
                ]
            )
        )
        try await db.setPlaceName(placeKey: "cafe", name: "Continental Coffee")

        let batch = try await db.changeBatch()
        XCTAssertEqual(batch.count, 4)
        XCTAssertEqual(batch.visits.map(\.id), ["v1"])
        XCTAssertEqual(batch.activities.map(\.id), ["a1"])
        XCTAssertEqual(batch.paths.map(\.id), ["p1"])
        XCTAssertEqual(batch.names["cafe"]?.name, "Continental Coffee")
    }

    func testBatchesDrainOldestFirst() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        for index in 0..<5 {
            try await db.record(
                batch: TimelineBatch(
                    visits: [sampleVisit("v\(index)", offsetDays: Double(index))],
                    activities: [],
                    paths: []
                )
            )
        }
        let first = try await db.changeBatch(limit: 2)
        XCTAssertEqual(first.changes.map(\.rowID), ["v0", "v1"])
        try await db.acknowledge(first.changes)
        let next = try await db.changeBatch(limit: 2)
        XCTAssertEqual(next.changes.map(\.rowID), ["v2", "v3"])
    }

    func testMarkEverythingPendingQueuesTheWholeLibrary() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        try await db.record(
            batch: TimelineBatch(
                visits: [sampleVisit("v1"), sampleVisit("v2", offsetDays: 1)],
                activities: [],
                paths: []
            )
        )
        try await db.setPlaceName(placeKey: "cafe", name: "Continental Coffee")
        try await db.clearChangeLog()
        let empty = try await db.pendingChangeCount()
        XCTAssertEqual(empty, 0)

        let queued = try await db.markEverythingPending()
        XCTAssertEqual(queued, 3, "two visits and one name")
    }

    func testDerivedStateIsNotTracked() async throws {
        let (db, url) = database()
        defer { try? FileManager.default.removeItem(at: url) }

        // Fixes, capture marks and the open stay are all device-local scaffolding;
        // syncing them would be pure noise.
        try await db.appendFixes([
            CapturedFix(coordinate: home, timestamp: Date(), horizontalAccuracy: 10, speed: 3)
        ])
        try await db.setCaptureMark(CaptureMark.motion, through: Date())
        try await db.setOpenStop(
            CapturedStop(coordinate: home, horizontalAccuracy: 50, start: Date(), end: nil),
            placeKey: "cafe"
        )
        let count = try await db.pendingChangeCount()
        XCTAssertEqual(count, 0)
    }
}

// MARK: - CloudKit record mapping

import CloudKit

final class TimelineRecordMapperTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: TimelineRecordMapper.zoneName, ownerName: CKCurrentUserDefaultName)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testVisitRoundTrips() throws {
        let visit = TimelineVisit(
            id: "dv-abc",
            start: origin,
            end: origin.addingTimeInterval(2_700),
            coordinate: home,
            semanticType: "Home",
            placeKey: "ChIJ_home"
        )
        let record = TimelineRecordMapper.record(for: visit, in: zoneID)
        XCTAssertEqual(record.recordID.recordName, "dv-abc")
        XCTAssertEqual(record.recordType, "Visit")

        let parsed = try XCTUnwrap(TimelineRecordMapper.visit(from: record))
        XCTAssertEqual(parsed.id, visit.id)
        XCTAssertEqual(parsed.start, visit.start)
        XCTAssertEqual(parsed.end, visit.end)
        XCTAssertEqual(parsed.placeKey, visit.placeKey)
        XCTAssertEqual(parsed.semanticType, "Home")
        XCTAssertEqual(parsed.coordinate?.latitude ?? 0, home.latitude, accuracy: 0.000_001)
        XCTAssertEqual(parsed.coordinate?.longitude ?? 0, home.longitude, accuracy: 0.000_001)
    }

    func testVisitWithoutACoordinateRoundTrips() throws {
        let visit = TimelineVisit(
            id: "v1",
            start: origin,
            end: origin.addingTimeInterval(600),
            coordinate: nil,
            semanticType: nil,
            placeKey: "somewhere"
        )
        let parsed = try XCTUnwrap(
            TimelineRecordMapper.visit(from: TimelineRecordMapper.record(for: visit, in: zoneID))
        )
        XCTAssertNil(parsed.coordinate)
        XCTAssertNil(parsed.semanticType)
    }

    func testActivityRoundTripsIncludingItsKind() throws {
        let activity = TimelineActivity(
            id: "da-1",
            start: origin,
            end: origin.addingTimeInterval(1_200),
            distance: 8_400,
            startCoordinate: home,
            endCoordinate: offset(home, metersNorth: 8_400),
            kind: .cycling
        )
        let parsed = try XCTUnwrap(
            TimelineRecordMapper.activity(from: TimelineRecordMapper.record(for: activity, in: zoneID))
        )
        XCTAssertEqual(parsed.kind.stored, "cycling")
        XCTAssertEqual(parsed.distance, 8_400)
        XCTAssertNotNil(parsed.startCoordinate)
        XCTAssertNotNil(parsed.endCoordinate)
    }

    func testPathPointsSurviveThePackedBlob() throws {
        let points = (0..<500).map { offset(home, metersNorth: Double($0) * 25) }
        let path = TimelinePath(
            id: "dp-1",
            start: origin,
            end: origin.addingTimeInterval(3_600),
            points: points,
            kind: .automobile
        )
        let record = TimelineRecordMapper.record(for: path, in: zoneID)
        let parsed = try XCTUnwrap(TimelineRecordMapper.path(from: record))
        XCTAssertEqual(parsed.points.count, points.count)
        XCTAssertEqual(parsed.points.last?.latitude ?? 0, points.last?.latitude ?? -1, accuracy: 0.000_001)

        // A dense full-trace day has to stay well inside CloudKit's 1 MB record cap.
        let blob = try XCTUnwrap(record[TimelineRecordMapper.Field.points] as? Data)
        XCTAssertEqual(blob.count, points.count * 16)
        XCTAssertLessThan(blob.count, 900_000)
    }

    func testPlaceNameAndMergeRoundTrip() throws {
        let stamp = origin.timeIntervalSince1970
        let nameRecord = TimelineRecordMapper.record(
            forPlaceKey: "cafe",
            name: PlaceIdentityName(name: "Continental Coffee", updatedAt: stamp),
            in: zoneID
        )
        let parsedName = try XCTUnwrap(TimelineRecordMapper.placeName(from: nameRecord))
        XCTAssertEqual(parsedName.key, "cafe")
        XCTAssertEqual(parsedName.name.name, "Continental Coffee")
        XCTAssertEqual(parsedName.name.updatedAt, stamp)

        let mergeRecord = TimelineRecordMapper.record(
            forPlaceKey: "annex",
            merge: PlaceIdentityMerge(toKey: "cafe", updatedAt: stamp),
            in: zoneID
        )
        let parsedMerge = try XCTUnwrap(TimelineRecordMapper.placeMerge(from: mergeRecord))
        XCTAssertEqual(parsedMerge.merge.toKey, "cafe")
    }

    func testAnUnmergeTombstoneSurvives() throws {
        // An empty toKey is how an undone merge travels; it must not be dropped.
        let record = TimelineRecordMapper.record(
            forPlaceKey: "annex",
            merge: PlaceIdentityMerge(toKey: "", updatedAt: origin.timeIntervalSince1970),
            in: zoneID
        )
        let parsed = try XCTUnwrap(TimelineRecordMapper.placeMerge(from: record))
        XCTAssertTrue(parsed.merge.isTombstone)
    }

    func testRecordTypesAndKindsAgree() {
        for kind in ChangeKind.allCases {
            let type = TimelineRecordMapper.recordType(for: kind)
            XCTAssertEqual(TimelineRecordMapper.kind(forRecordType: type), kind)
        }
        XCTAssertNil(TimelineRecordMapper.kind(forRecordType: "SomethingElse"))
    }

    func testMismatchedRecordTypesParseAsNil() {
        let activityRecord = TimelineRecordMapper.record(
            for: TimelineActivity(
                id: "a1",
                start: origin,
                end: origin.addingTimeInterval(60),
                distance: 0,
                startCoordinate: nil,
                endCoordinate: nil,
                kind: .walking
            ),
            in: zoneID
        )
        XCTAssertNil(TimelineRecordMapper.visit(from: activityRecord))
        XCTAssertNil(TimelineRecordMapper.path(from: activityRecord))
    }

    func testFetchedRecordsSortIntoTheRightBuckets() {
        let visit = TimelineVisit(
            id: "v1", start: origin, end: origin.addingTimeInterval(60),
            coordinate: home, semanticType: nil, placeKey: "k"
        )
        let activity = TimelineActivity(
            id: "a1", start: origin, end: origin.addingTimeInterval(60), distance: 10,
            startCoordinate: home, endCoordinate: nil, kind: .walking
        )
        let records = [
            TimelineRecordMapper.record(for: visit, in: zoneID),
            TimelineRecordMapper.record(for: activity, in: zoneID),
            TimelineRecordMapper.record(
                forPlaceKey: "k",
                name: PlaceIdentityName(name: "Home", updatedAt: 1),
                in: zoneID
            ),
        ]
        let sorted = TimelineRecordMapper.batch(from: records)
        XCTAssertEqual(sorted.rows.visits.count, 1)
        XCTAssertEqual(sorted.rows.activities.count, 1)
        XCTAssertEqual(sorted.names["k"]?.name, "Home")
        XCTAssertTrue(sorted.merges.isEmpty)
    }
}

final class RemoteApplyTests: XCTestCase {
    func testRowsArrivingFromAnotherDeviceAreNotQueuedBackOut() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.applyRemote(
            TimelineBatch(
                visits: [
                    TimelineVisit(
                        id: "v-from-phone",
                        start: start,
                        end: start.addingTimeInterval(1_800),
                        coordinate: home,
                        semanticType: nil,
                        placeKey: "cafe"
                    )
                ],
                activities: [],
                paths: []
            )
        )

        let stored = try await db.loadBatch()?.visits ?? []
        XCTAssertEqual(stored.count, 1)
        let queued = try await db.pendingChangeCount()
        XCTAssertEqual(queued, 0, "a row we just received must not be queued for sending")
    }

    func testSyncStateSurvivesReopening() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncstate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let db = TimelineDatabase(fileURL: url)
        try await db.setSyncStateData("cloudKitSyncState", Data([1, 2, 3, 4]))

        let reopened = TimelineDatabase(fileURL: url)
        let restored = try await reopened.syncStateData("cloudKitSyncState")
        XCTAssertEqual(restored, Data([1, 2, 3, 4]))

        try await reopened.setSyncStateData("cloudKitSyncState", nil)
        let cleared = try await reopened.syncStateData("cloudKitSyncState")
        XCTAssertNil(cleared)
    }

    func testRemoteDeletionRemovesTheRow() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotedelete-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.record(
            batch: TimelineBatch(
                visits: [
                    TimelineVisit(
                        id: "v1", start: start, end: start.addingTimeInterval(600),
                        coordinate: home, semanticType: nil, placeKey: "cafe"
                    )
                ],
                activities: [],
                paths: []
            )
        )
        try await db.applyRemoteDeletion(kind: .visit, rowID: "v1")
        let remaining = try await db.loadBatch()?.visits ?? []
        XCTAssertTrue(remaining.isEmpty)
    }
}

// MARK: - Notification bookkeeping

@MainActor
final class TrackingSettingsTests: XCTestCase {
    private func settings() -> TrackingSettings {
        TrackingSettings(defaults: UserDefaults(suiteName: "settings-\(UUID().uuidString)")!)
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }()

    private func day(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
    }

    func testTheDailyCountResetsAtMidnight() {
        let settings = settings()
        settings.recordSent(now: day(12, hour: 9), calendar: calendar)
        settings.recordSent(now: day(12, hour: 14), calendar: calendar)
        XCTAssertEqual(settings.sentToday(now: day(12, hour: 20), calendar: calendar), 2)
        // A stay the next morning starts a fresh allowance.
        XCTAssertEqual(settings.sentToday(now: day(13, hour: 9), calendar: calendar), 0)
    }

    func testCountingLateAtNightDoesNotBleedIntoTomorrow() {
        let settings = settings()
        settings.recordSent(now: day(12, hour: 23), calendar: calendar)
        settings.recordSent(now: day(13, hour: 1), calendar: calendar)
        XCTAssertEqual(settings.sentToday(now: day(13, hour: 8), calendar: calendar), 1)
    }

    func testHeldPlacesDedupeAndAreBounded() {
        let settings = settings()
        settings.hold("cafe")
        settings.hold("cafe")
        XCTAssertEqual(settings.heldPlaceKeys, ["cafe"])

        for index in 0..<40 {
            settings.hold("place-\(index)")
        }
        XCTAssertLessThanOrEqual(settings.heldPlaceKeys.count, 20, "the morning summary must not grow without bound")
        XCTAssertEqual(settings.heldPlaceKeys.last, "place-39", "the newest holds are the ones kept")

        settings.clearHeld()
        XCTAssertTrue(settings.heldPlaceKeys.isEmpty)
    }

    func testSettingsSurviveANewInstanceOnTheSameDefaults() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let first = TrackingSettings(defaults: defaults)
        first.mode = .fullTrace
        first.notifiesVisits = false
        first.usesHealth = true
        first.syncsWithCloud = true

        let second = TrackingSettings(defaults: defaults)
        XCTAssertEqual(second.mode, .fullTrace)
        XCTAssertFalse(second.notifiesVisits)
        XCTAssertTrue(second.usesHealth)
        XCTAssertTrue(second.syncsWithCloud)
    }

    func testModesDescribeWhatTheyRun() {
        XCTAssertFalse(TrackingMode.off.isRecording)
        XCTAssertTrue(TrackingMode.places.isRecording)
        XCTAssertFalse(TrackingMode.places.tracksMovement, "places only draws no lines")
        XCTAssertTrue(TrackingMode.balanced.tracksMovement)
        XCTAssertFalse(TrackingMode.balanced.tracksFinePaths, "fine paths are the expensive tier")
        XCTAssertTrue(TrackingMode.fullTrace.tracksFinePaths)
    }

    func testMotionKindsMapOntoDrawableTravel() {
        XCTAssertEqual(MotionKind.walking.travelKind.stored, "walking")
        XCTAssertEqual(MotionKind.running.travelKind.stored, "walking", "a run draws like a walk")
        XCTAssertEqual(MotionKind.cycling.travelKind.stored, "cycling")
        XCTAssertEqual(MotionKind.automotive.travelKind.stored, "automobile")
        XCTAssertEqual(MotionKind.stationary.travelKind.stored, "raw")
        XCTAssertFalse(MotionKind.unknown.isMoving)
        XCTAssertFalse(MotionKind.stationary.isMoving)
        XCTAssertTrue(MotionKind.cycling.isMoving)
    }
}

// MARK: - The notification path, without the network

final class ScriptedGuesser: PlaceGuessing {
    let guesses: [PlaceNameSuggestion]

    init(_ titles: [String]) {
        self.guesses = titles.map { title in
            PlaceNameSuggestion(
                id: "scripted:\(title)",
                title: title,
                subtitle: "Nearby",
                source: .map,
                visitCount: 0,
                distanceMeters: 40,
                targetPlaceID: nil
            )
        }
    }

    func pointsOfInterest(around coordinate: CLLocationCoordinate2D) async -> [PlaceNameSuggestion] { guesses }
    func address(at coordinate: CLLocationCoordinate2D) async -> PlaceNameSuggestion? { guesses.first }
    func guesses(
        around coordinate: CLLocationCoordinate2D,
        visited: [PlaceNameSuggestion],
        limit: Int
    ) async -> [PlaceNameSuggestion] {
        Array((visited + guesses).prefix(limit))
    }
}

@MainActor
final class RecorderNotificationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }()

    private func afternoon(_ hour: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: hour))!
    }

    private func makeRecorder(
        now: Date
    ) -> (TimelineRecorder, TimelineDatabase, TrackingSettings, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-\(UUID().uuidString).sqlite")
        let database = TimelineDatabase(fileURL: url)
        let settings = TrackingSettings(defaults: UserDefaults(suiteName: "notify-\(UUID().uuidString)")!)
        settings.mode = .balanced
        settings.notifiesVisits = true
        let recorder = TimelineRecorder(
            database: database,
            stops: ScriptedStopSource(),
            motion: ScriptedMotionSource(),
            settings: settings,
            guesser: ScriptedGuesser(["Continental Coffee", "JJ Bean"]),
            // Deterministic on purpose: the default ranker would reach for this
            // Mac's real language model, making these tests slow and dependent on
            // whether Apple Intelligence happens to be switched on.
            ranker: HeuristicPlaceRanker(),
            now: { now }
        )
        return (recorder, database, settings, url)
    }

    func testAStayAtANamedPlaceIsRecordedInSilence() async throws {
        let now = afternoon()
        let (recorder, database, settings, url) = makeRecorder(now: now)
        defer { try? FileManager.default.removeItem(at: url) }

        // Seed a place that already has a name — home and work look like this.
        let earlier = now.addingTimeInterval(-86_400)
        try await database.record(
            batch: TimelineBatch(
                visits: [
                    TimelineVisit(
                        id: "seed", start: earlier, end: earlier.addingTimeInterval(3_600),
                        coordinate: home, semanticType: nil, placeKey: "cafe"
                    )
                ],
                activities: [],
                paths: []
            )
        )
        try await database.setPlaceName(placeKey: "cafe", name: "Home")

        await recorder.handle(stop: stop(start: now.addingTimeInterval(-3_600), minutes: 60))

        XCTAssertTrue(settings.heldPlaceKeys.isEmpty)
        XCTAssertEqual(settings.sentToday(now: now, calendar: calendar), 0, "a named place must never notify")
        let visits = try await database.loadBatch()?.visits ?? []
        XCTAssertEqual(visits.count, 2, "but the stay is still recorded")
    }

    func testAStayDuringQuietHoursIsHeldForTheMorning() async throws {
        let night = afternoon(23)
        let (recorder, _, settings, url) = makeRecorder(now: night)
        defer { try? FileManager.default.removeItem(at: url) }

        await recorder.handle(stop: stop(start: night.addingTimeInterval(-2_700), minutes: 45))
        XCTAssertEqual(settings.heldPlaceKeys.count, 1, "a 23:45 stay should wait until morning")
    }

    func testPastTheDailyCapStaysAreHeldRatherThanDropped() async throws {
        let now = afternoon()
        let (recorder, _, settings, url) = makeRecorder(now: now)
        defer { try? FileManager.default.removeItem(at: url) }

        for _ in 0..<VisitNotificationPolicy.dailyCap {
            settings.recordSent(now: now, calendar: calendar)
        }
        await recorder.handle(stop: stop(start: now.addingTimeInterval(-3_600), minutes: 60))
        XCTAssertEqual(settings.heldPlaceKeys.count, 1)
    }

    func testAShortStayIsNeitherAnnouncedNorHeld() async throws {
        let now = afternoon()
        let (recorder, _, settings, url) = makeRecorder(now: now)
        defer { try? FileManager.default.removeItem(at: url) }

        await recorder.handle(stop: stop(start: now.addingTimeInterval(-240), minutes: 4))
        XCTAssertTrue(settings.heldPlaceKeys.isEmpty)
        XCTAssertEqual(settings.sentToday(now: now, calendar: calendar), 0)
    }

    func testTurningNotificationsOffSilencesEverything() async throws {
        let night = afternoon(23)
        let (recorder, _, settings, url) = makeRecorder(now: night)
        defer { try? FileManager.default.removeItem(at: url) }
        settings.notifiesVisits = false

        await recorder.handle(stop: stop(start: night.addingTimeInterval(-2_700), minutes: 45))
        XCTAssertTrue(settings.heldPlaceKeys.isEmpty, "nothing is held when nothing would be sent")
    }

    func testTheMorningSummaryClearsWhatWasHeld() async throws {
        let morning = afternoon(9)
        let (recorder, _, settings, url) = makeRecorder(now: morning)
        defer { try? FileManager.default.removeItem(at: url) }

        settings.hold("cafe")
        settings.hold("bank")
        await recorder.catchUp()
        XCTAssertTrue(settings.heldPlaceKeys.isEmpty, "the summary goes out and the queue empties")
    }

    func testHoldsSurviveUntilItIsMorning() async throws {
        let night = afternoon(2)
        let (recorder, _, settings, url) = makeRecorder(now: night)
        defer { try? FileManager.default.removeItem(at: url) }

        settings.hold("cafe")
        await recorder.catchUp()
        XCTAssertEqual(settings.heldPlaceKeys, ["cafe"], "2am is not the time to send a summary")
    }
}

// MARK: - Recorder lifecycle and enrichment

@MainActor
final class RecorderLifecycleTests: XCTestCase {
    private struct Rig {
        let recorder: TimelineRecorder
        let stops: ScriptedStopSource
        let motion: ScriptedMotionSource
        let health: ScriptedHealthSource
        let database: TimelineDatabase
        let settings: TrackingSettings
        let url: URL
    }

    private func rig(mode: TrackingMode = .balanced, now: Date = Date()) -> Rig {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString).sqlite")
        let database = TimelineDatabase(fileURL: url)
        let stops = ScriptedStopSource()
        let motion = ScriptedMotionSource()
        let health = ScriptedHealthSource()
        let settings = TrackingSettings(defaults: UserDefaults(suiteName: "lifecycle-\(UUID().uuidString)")!)
        settings.mode = mode
        settings.notifiesVisits = false
        return Rig(
            recorder: TimelineRecorder(
                database: database,
                stops: stops,
                motion: motion,
                settings: settings,
                health: health,
                guesser: ScriptedGuesser([]),
                ranker: HeuristicPlaceRanker(),
                now: { now }
            ),
            stops: stops,
            motion: motion,
            health: health,
            database: database,
            settings: settings,
            url: url
        )
    }

    func testStartingArmsTheSourcesForTheChosenMode() async throws {
        let rig = rig()
        defer { try? FileManager.default.removeItem(at: rig.url) }

        rig.recorder.start()
        XCTAssertEqual(rig.stops.startedMode, .balanced)
        XCTAssertTrue(rig.recorder.isRunning)
        XCTAssertFalse(rig.motion.isLive, "balanced does not need live motion updates")
    }

    func testOffModeArmsNothing() async throws {
        let rig = rig(mode: .off)
        defer { try? FileManager.default.removeItem(at: rig.url) }

        rig.recorder.start()
        XCTAssertNil(rig.stops.startedMode)
        XCTAssertFalse(rig.recorder.isRunning)
    }

    func testFullTraceOnlyTracesWhileMoving() async throws {
        let rig = rig(mode: .fullTrace)
        defer { try? FileManager.default.removeItem(at: rig.url) }

        rig.recorder.start()
        XCTAssertTrue(rig.motion.isLive, "full trace has to watch for motion transitions")

        rig.motion.emit(.automotive)
        await Task.yield()
        XCTAssertTrue(rig.stops.isTracing, "a drive should turn the radio on")

        rig.motion.emit(.stationary)
        await Task.yield()
        XCTAssertFalse(rig.stops.isTracing, "standing still must turn it off again")
    }

    func testStoppingDisarmsEverything() async throws {
        let rig = rig(mode: .fullTrace)
        defer { try? FileManager.default.removeItem(at: rig.url) }

        rig.recorder.start()
        rig.recorder.stop()
        XCTAssertNil(rig.stops.startedMode)
        XCTAssertFalse(rig.motion.isLive)
        XCTAssertFalse(rig.recorder.isRunning)
    }

    func testWorkoutRoutesArriveThroughTheRecorder() async throws {
        let now = Date()
        let rig = rig(now: now)
        defer { try? FileManager.default.removeItem(at: rig.url) }
        rig.settings.usesHealth = true

        rig.health.workoutsToReturn = [
            HealthWorkout(
                id: "ride-1",
                start: now.addingTimeInterval(-3_600),
                end: now.addingTimeInterval(-1_800),
                kind: .cycling,
                distanceMeters: 9_000,
                route: (0..<40).map { offset(home, metersNorth: Double($0) * 225) }
            )
        ]

        await rig.recorder.catchUp()

        let batch = try await rig.database.loadBatch()
        XCTAssertEqual(batch?.paths.count, 1, "the Watch's own GPS track should land as a path")
        XCTAssertEqual(batch?.activities.first?.kind.stored, "cycling")
        let mark = try await rig.database.captureMark(CaptureMark.health)
        XCTAssertNotNil(mark)
    }

    func testWatchDistanceReclassifiesADriveThatWasARide() async throws {
        let now = Date()
        let rig = rig(now: now)
        defer { try? FileManager.default.removeItem(at: rig.url) }
        rig.settings.usesHealth = true

        // Core Motion called this stretch driving.
        rig.motion.scripted = [
            MotionSample(start: now.addingTimeInterval(-3_000), kind: .automotive, confidence: 2),
            MotionSample(start: now.addingTimeInterval(-1_200), kind: .stationary, confidence: 2),
        ]
        // The Watch logged real cycling distance across the same window.
        rig.health.distancesToReturn = [
            HealthDistanceSample(
                start: now.addingTimeInterval(-3_000),
                end: now.addingTimeInterval(-1_200),
                meters: 4_000,
                kind: .cycling
            )
        ]

        await rig.recorder.catchUp()

        let activities = try await rig.database.loadBatch()?.activities ?? []
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.kind.stored, "cycling", "the Watch overrules Core Motion here")
    }

    func testHealthIsIgnoredUntilItIsTurnedOn() async throws {
        let now = Date()
        let rig = rig(now: now)
        defer { try? FileManager.default.removeItem(at: rig.url) }

        rig.health.workoutsToReturn = [
            HealthWorkout(
                id: "ride-1",
                start: now.addingTimeInterval(-3_600),
                end: now.addingTimeInterval(-1_800),
                kind: .cycling,
                distanceMeters: 9_000,
                route: [home, offset(home, metersNorth: 9_000)]
            )
        ]
        await rig.recorder.catchUp()

        let batch = try await rig.database.loadBatch()
        XCTAssertNil(batch?.paths.first, "HealthKit is opt-in; nothing should be read")
    }

    func testReconciliationRunsAtMostOncePerDay() async throws {
        // A whole-second epoch, because a Date round-trips through the database as
        // seconds-since-1970 and an arbitrary Date loses its lowest bits to that
        // conversion — harmless for a capture mark, fatal for an equality check.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rig = rig(now: now)
        defer { try? FileManager.default.removeItem(at: rig.url) }

        await rig.recorder.catchUp()
        let first = try await rig.database.captureMark(CaptureMark.reconcile)
        XCTAssertEqual(first, now)

        // A second wake soon after must not re-read the whole visit table.
        await rig.recorder.catchUp()
        let second = try await rig.database.captureMark(CaptureMark.reconcile)
        XCTAssertEqual(second, first, "reconciliation is daily, not every wake")
    }

    func testCatchUpDoesNothingWhenRecordingIsOff() async throws {
        let rig = rig(mode: .off)
        defer { try? FileManager.default.removeItem(at: rig.url) }

        rig.motion.scripted = [
            MotionSample(start: Date().addingTimeInterval(-3_600), kind: .walking, confidence: 2),
            MotionSample(start: Date().addingTimeInterval(-1_800), kind: .stationary, confidence: 2),
        ]
        await rig.recorder.catchUp()
        let mark = try await rig.database.captureMark(CaptureMark.motion)
        XCTAssertNil(mark)
    }
}

// MARK: - Value semantics

final class CaptureValueTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testStopsCompareOnEveryFieldThatMatters() {
        let base = CapturedStop(coordinate: home, horizontalAccuracy: 65, start: origin, end: nil)
        XCTAssertEqual(base, CapturedStop(coordinate: home, horizontalAccuracy: 65, start: origin, end: nil))

        // Same place and time, different departure: a stay that has since closed.
        XCTAssertNotEqual(
            base,
            CapturedStop(coordinate: home, horizontalAccuracy: 65, start: origin, end: origin.addingTimeInterval(600))
        )
        // Same time, moved: a different stay entirely.
        XCTAssertNotEqual(
            base,
            CapturedStop(
                coordinate: offset(home, metersNorth: 500),
                horizontalAccuracy: 65,
                start: origin,
                end: nil
            )
        )
        // Same stay, a better fix.
        XCTAssertNotEqual(
            base,
            CapturedStop(coordinate: home, horizontalAccuracy: 20, start: origin, end: nil)
        )
    }

    func testAnOpenStopHasNoDuration() {
        let open = CapturedStop(coordinate: home, horizontalAccuracy: 65, start: origin, end: nil)
        XCTAssertEqual(open.duration, 0)
        XCTAssertFalse(open.isClosed)

        let closed = CapturedStop(
            coordinate: home,
            horizontalAccuracy: 65,
            start: origin,
            end: origin.addingTimeInterval(2_700)
        )
        XCTAssertEqual(closed.duration, 2_700)
        XCTAssertTrue(closed.isClosed)
    }

    func testABackwardsStopReportsNoNegativeDuration() {
        let backwards = CapturedStop(
            coordinate: home,
            horizontalAccuracy: 65,
            start: origin,
            end: origin.addingTimeInterval(-600)
        )
        XCTAssertEqual(backwards.duration, 0, "a negative stay would poison every total it feeds")
    }

    func testAnchorsCompareOnIdentityAndStanding() {
        let anchor = PlaceAnchor(placeKey: "cafe", coordinate: home, visitCount: 4, isNamed: true)
        XCTAssertEqual(anchor, PlaceAnchor(placeKey: "cafe", coordinate: home, visitCount: 4, isNamed: true))
        XCTAssertNotEqual(anchor, PlaceAnchor(placeKey: "cafe", coordinate: home, visitCount: 5, isNamed: true))
        XCTAssertNotEqual(anchor, PlaceAnchor(placeKey: "cafe", coordinate: home, visitCount: 4, isNamed: false))
        XCTAssertNotEqual(anchor, PlaceAnchor(placeKey: "bank", coordinate: home, visitCount: 4, isNamed: true))
    }

    func testFixesAreIdentifiedByWhenAndWhere() {
        let fix = CapturedFix(coordinate: home, timestamp: origin, horizontalAccuracy: 10, speed: 3)
        // Accuracy and speed vary between reports of the same moment.
        XCTAssertEqual(fix, CapturedFix(coordinate: home, timestamp: origin, horizontalAccuracy: 40, speed: 9))
        XCTAssertNotEqual(
            fix,
            CapturedFix(coordinate: home, timestamp: origin.addingTimeInterval(1), horizontalAccuracy: 10, speed: 3)
        )
    }

    func testAnEmptyChangeBatchIsEmpty() {
        XCTAssertTrue(ChangeBatch().isEmpty)
        XCTAssertEqual(ChangeBatch().count, 0)
        XCTAssertTrue(ChangeBatch().deletions.isEmpty)
    }

    func testABatchSeparatesDeletionsFromUpserts() {
        let batch = ChangeBatch(
            changes: [
                PendingChange(kind: .visit, rowID: "v1", operation: .upsert, seq: 1, changedAt: origin),
                PendingChange(kind: .visit, rowID: "v2", operation: .delete, seq: 2, changedAt: origin),
            ]
        )
        XCTAssertFalse(batch.isEmpty)
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.deletions.map(\.rowID), ["v2"])
    }

    func testAnOpenStayStillPrintsAStartTime() {
        let open = CapturedStop(coordinate: home, horizontalAccuracy: 65, start: origin, end: nil)
        XCTAssertFalse(VisitNotificationPolicy.timeRange(open).isEmpty)
        XCTAssertFalse(VisitNotificationPolicy.timeRange(open).contains("–"), "there is no end to show yet")

        let closed = CapturedStop(
            coordinate: home,
            horizontalAccuracy: 65,
            start: origin,
            end: origin.addingTimeInterval(2_700)
        )
        XCTAssertTrue(VisitNotificationPolicy.timeRange(closed).contains("–"))
    }

    func testAVeryShortStayStillReadsAsAMinute() {
        XCTAssertEqual(VisitNotificationPolicy.durationPhrase(20), "1 minute")
        XCTAssertEqual(VisitNotificationPolicy.durationPhrase(120), "2 minutes")
        XCTAssertEqual(VisitNotificationPolicy.durationPhrase(7_200), "2 hours")
    }
}

// MARK: - Keeping CloudKit's change tags

final class CloudRecordArchiveTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: TimelineRecordMapper.zoneName, ownerName: CKCurrentUserDefaultName)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleVisit(_ id: String = "v1") -> TimelineVisit {
        TimelineVisit(
            id: id,
            start: origin,
            end: origin.addingTimeInterval(1_800),
            coordinate: home,
            semanticType: nil,
            placeKey: "cafe"
        )
    }

    func testSystemFieldsRoundTrip() throws {
        let original = TimelineRecordMapper.record(for: sampleVisit(), in: zoneID)
        let restored = try XCTUnwrap(
            TimelineRecordMapper.decodeSystemFields(TimelineRecordMapper.encodeSystemFields(original))
        )
        XCTAssertEqual(restored.recordID, original.recordID)
        XCTAssertEqual(restored.recordType, original.recordType)
        // Only the system fields travel; the values live in the library.
        XCTAssertNil(restored[TimelineRecordMapper.Field.placeKey])
    }

    func testASaveIsBuiltOnTheAcknowledgedRecord() {
        // The whole bug: a fresh CKRecord has no change tag, so the server reads
        // the save as an insert and refuses it once the row exists.
        let acknowledged = TimelineRecordMapper.record(for: sampleVisit(), in: zoneID)
        let rebuilt = TimelineRecordMapper.record(for: sampleVisit(), in: zoneID, base: acknowledged)
        XCTAssertTrue(rebuilt === acknowledged, "the update must be written onto the server's own record")
        XCTAssertEqual(rebuilt[TimelineRecordMapper.Field.placeKey] as? String, "cafe")
    }

    func testAMismatchedBaseIsIgnored() {
        let otherRow = TimelineRecordMapper.record(for: sampleVisit("somebody-else"), in: zoneID)
        let rebuilt = TimelineRecordMapper.record(for: sampleVisit("v1"), in: zoneID, base: otherRow)
        XCTAssertFalse(rebuilt === otherRow)
        XCTAssertEqual(rebuilt.recordID.recordName, "v1")

        let wrongType = TimelineRecordMapper.record(
            forPlaceKey: "v1",
            name: PlaceIdentityName(name: "Cafe", updatedAt: 1),
            in: zoneID
        )
        let fresh = TimelineRecordMapper.record(for: sampleVisit("v1"), in: zoneID, base: wrongType)
        XCTAssertFalse(fresh === wrongType, "a PlaceName record is not a canvas for a Visit")
        XCTAssertEqual(fresh.recordType, "Visit")
    }

    func testArchivesPersistAndCanBeForgotten() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckrecords-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        let record = TimelineRecordMapper.record(for: sampleVisit(), in: zoneID)
        let archive = TimelineRecordMapper.encodeSystemFields(record)
        try await db.setCloudRecordArchive("v1", archive)

        // A background relaunch gets a new handle and must still know the tag.
        let reopened = TimelineDatabase(fileURL: url)
        let stored = try await reopened.cloudRecordArchive("v1")
        XCTAssertEqual(stored, archive)
        let count = try await reopened.cloudRecordArchiveCount()
        XCTAssertEqual(count, 1)

        // Forgetting makes the next save a clean insert, which is what we want
        // after the server says the record is gone.
        try await reopened.setCloudRecordArchive("v1", nil)
        let cleared = try await reopened.cloudRecordArchive("v1")
        XCTAssertNil(cleared)
    }

    func testArchivesAreFetchedInBulkForABatch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckbulk-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        for id in ["a", "b"] {
            let record = TimelineRecordMapper.record(for: sampleVisit(id), in: zoneID)
            try await db.setCloudRecordArchive(id, TimelineRecordMapper.encodeSystemFields(record))
        }
        let found = try await db.cloudRecordArchives(["a", "b", "never-sent"])
        XCTAssertEqual(Set(found.keys), ["a", "b"], "a row we have never sent simply has no tag yet")
    }

    func testSigningOutForgetsEveryTag() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckwipe-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = TimelineDatabase(fileURL: url)

        let record = TimelineRecordMapper.record(for: sampleVisit(), in: zoneID)
        try await db.setCloudRecordArchive("v1", TimelineRecordMapper.encodeSystemFields(record))
        try await db.clearCloudRecordArchives()
        let count = try await db.cloudRecordArchiveCount()
        XCTAssertEqual(count, 0, "another account's change tags must never be quoted")
    }
}
