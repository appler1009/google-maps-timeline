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
    var isAvailable: Bool { true }
    func samples(from: Date, to: Date) async -> [MotionSample] {
        scripted.filter { $0.start >= from && $0.start <= to }
    }
    func startLiveUpdates(_ handler: @escaping (MotionSample) -> Void) {}
    func stopLiveUpdates() {}
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
