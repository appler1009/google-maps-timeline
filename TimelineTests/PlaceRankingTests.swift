import CoreLocation
import XCTest
@testable import Timeline

private let vancouver = CLLocationCoordinate2D(latitude: 49.2765, longitude: -123.0680)

private func candidate(
    _ title: String,
    meters: Double,
    category: String? = nil,
    visits: Int = 0,
    source: PlaceNameSuggestion.Source = .map,
    targetPlaceID: String? = nil
) -> PlaceNameSuggestion {
    PlaceNameSuggestion(
        id: "c:\(title)",
        title: title,
        subtitle: category,
        source: source,
        visitCount: visits,
        distanceMeters: meters,
        targetPlaceID: targetPlaceID,
        category: category
    )
}

private func context(
    weekday: String = "Tuesday",
    startMinutes: Int = 12 * 60 + 30,
    durationMinutes: Int = 40,
    priorVisits: [VisitNamingContext.PriorVisit] = [],
    routine: [VisitNamingContext.RoutineEntry] = [],
    cameFrom: String? = nil
) -> VisitNamingContext {
    VisitNamingContext(
        weekday: weekday,
        startMinutes: startMinutes,
        startTime: VisitNamingContextBuilder.clock(minutes: startMinutes),
        durationMinutes: durationMinutes,
        durationPhrase: VisitNotificationPolicy.durationPhrase(Double(durationMinutes) * 60),
        priorVisitsHere: priorVisits,
        routine: routine,
        cameFrom: cameFrom
    )
}

final class HeuristicPlaceRankerTests: XCTestCase {
    private let ranker = HeuristicPlaceRanker()

    func testNearerWinsWhenNothingElseSeparatesThem() async {
        let ordered = await ranker.rank(
            [candidate("Far Cafe", meters: 300), candidate("Near Cafe", meters: 20)],
            context: context()
        )
        XCTAssertEqual(ordered.map(\.title), ["Near Cafe", "Far Cafe"])
    }

    func testSomewhereYouAlreadyGoBeatsASlightlyNearerStranger() async {
        let ordered = await ranker.rank(
            [
                candidate("Unknown Deli", meters: 20),
                candidate("Continental Coffee", meters: 90, visits: 12, source: .visited, targetPlaceID: "cafe"),
            ],
            context: context()
        )
        XCTAssertEqual(ordered.first?.title, "Continental Coffee")
    }

    func testAFourHourStayIsNotACoffee() async {
        // The point of the dwell table: rule out the obviously wrong.
        let ordered = await ranker.rank(
            [
                candidate("Corner Cafe", meters: 30, category: "Cafe"),
                candidate("Mercy Hospital", meters: 120, category: "Hospital"),
            ],
            context: context(durationMinutes: 240)
        )
        XCTAssertEqual(ordered.first?.title, "Mercy Hospital")
    }

    func testAnEightMinuteStopIsNotAHotel() async {
        let ordered = await ranker.rank(
            [
                candidate("Grand Hotel", meters: 25, category: "Hotel"),
                candidate("Corner Store", meters: 80, category: "Store"),
            ],
            context: context(startMinutes: 10 * 60, durationMinutes: 8)
        )
        XCTAssertEqual(ordered.first?.title, "Corner Store")
    }

    func testLunchtimeFavoursARestaurantOverABreakfastOnlyFit() async {
        let lunch = HeuristicPlaceRanker.plausibilityScore("Restaurant", context: context(startMinutes: 12 * 60 + 30, durationMinutes: 45))
        let midnight = HeuristicPlaceRanker.plausibilityScore("Restaurant", context: context(startMinutes: 3 * 60, durationMinutes: 45))
        XCTAssertGreaterThan(lunch, midnight)
    }

    func testAnUnknownCategoryIsNotPunished() {
        let unknown = HeuristicPlaceRanker.plausibilityScore("SomethingApplesNeverHeardOf", context: context())
        let missing = HeuristicPlaceRanker.plausibilityScore(nil, context: context())
        XCTAssertEqual(unknown, 0.5, "most of the world is not in Apple's category list")
        XCTAssertEqual(missing, 0.5)
    }

    func testAStreetAddressIsDemotedBelowARealPlace() async {
        let ordered = await ranker.rank(
            [
                candidate("1490 Commercial Drive", meters: 5, source: .address),
                candidate("Continental Coffee", meters: 60, category: "Cafe"),
            ],
            context: context()
        )
        XCTAssertEqual(ordered.first?.title, "Continental Coffee")
    }

    func testConfidenceIsHighWhenOneCandidateClearlyWins() {
        let confident = ranker.confidence(
            [
                candidate("Continental Coffee", meters: 10, visits: 20, source: .visited, targetPlaceID: "cafe"),
                candidate("Distant Warehouse", meters: 430),
            ],
            context: context()
        )
        XCTAssertGreaterThan(confident, ModelPlaceRanker.confidenceFloor)
    }

    func testConfidenceIsLowWhenTheTopTwoAreInterchangeable() {
        let ambiguous = ranker.confidence(
            [
                candidate("Chipotle", meters: 40, category: "Restaurant"),
                candidate("Bright Smile Dental", meters: 45),
            ],
            context: context()
        )
        XCTAssertLessThan(ambiguous, ModelPlaceRanker.confidenceFloor, "this is exactly when to ask a model")
    }

    func testASingleCandidateIsNotAmbiguous() {
        XCTAssertEqual(ranker.confidence([], context: context()), 0)
        let single = ranker.confidence([candidate("Only Option", meters: 20)], context: context())
        XCTAssertGreaterThan(single, 0)
    }
}

// MARK: - Model re-ranking

private struct StubChooser: PlaceChoosing {
    var available = true
    var result: ModelPlaceChoice?
    var delay: Duration?
    var failure: Error?

    var isAvailable: Bool { available }

    func choose(from titles: [String], prompt: String) async throws -> ModelPlaceChoice {
        if let delay { try? await Task.sleep(for: delay) }
        if let failure { throw failure }
        guard let result else { throw CocoaError(.featureUnsupported) }
        return result
    }
}

private let ambiguousPair = [
    candidate("Chipotle", meters: 40, category: "Restaurant"),
    candidate("Bright Smile Dental", meters: 45),
]

final class ModelPlaceRankerTests: XCTestCase {
    private func ranker(_ chooser: StubChooser, timeout: Duration = .seconds(2)) -> ModelPlaceRanker {
        ModelPlaceRanker(chooser: chooser, timeout: timeout)
    }

    func testThePicksAreReorderedWhenTheModelChooses() async {
        let chooser = StubChooser(
            result: ModelPlaceChoice(title: "Chipotle", confidence: 0.8, reason: "lunchtime, 40 minutes")
        )
        let ordered = await ranker(chooser).rank(ambiguousPair, context: context())
        XCTAssertEqual(ordered.first?.title, "Chipotle")
        XCTAssertEqual(ordered.count, 2, "re-ranking must not drop candidates")
    }

    func testAnOffListAnswerIsIgnored() async {
        // Constraining the model is not the same as trusting it.
        let chooser = StubChooser(
            result: ModelPlaceChoice(title: "A Place That Was Never Offered", confidence: 0.99, reason: "made up")
        )
        let ordered = await ranker(chooser).rank(ambiguousPair, context: context())
        let heuristic = await HeuristicPlaceRanker().rank(ambiguousPair, context: context())
        XCTAssertEqual(ordered.map(\.title), heuristic.map(\.title))
    }

    func testAFailingModelLeavesTheMeasuredOrderAlone() async {
        let chooser = StubChooser(failure: CocoaError(.featureUnsupported))
        let ordered = await ranker(chooser).rank(ambiguousPair, context: context())
        let heuristic = await HeuristicPlaceRanker().rank(ambiguousPair, context: context())
        XCTAssertEqual(ordered.map(\.title), heuristic.map(\.title))
    }

    func testASlowModelIsAbandoned() async {
        // A late notification is worse than one ranked by distance.
        let chooser = StubChooser(
            result: ModelPlaceChoice(title: "Chipotle", confidence: 1, reason: "too late"),
            delay: .seconds(5)
        )
        let started = Date()
        let ordered = await ranker(chooser, timeout: .milliseconds(150)).rank(ambiguousPair, context: context())
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the timeout should fire long before the model does")
        XCTAssertEqual(ordered.count, 2)
    }

    func testADeviceWithoutAModelJustUsesTheHeuristic() async {
        let chooser = StubChooser(available: false, result: ModelPlaceChoice(title: "Chipotle", confidence: 1, reason: ""))
        let ordered = await ranker(chooser).rank(ambiguousPair, context: context())
        let heuristic = await HeuristicPlaceRanker().rank(ambiguousPair, context: context())
        XCTAssertEqual(ordered.map(\.title), heuristic.map(\.title))
    }

    func testAClearWinnerIsNotSentToTheModel() async {
        let obvious = [
            candidate("Continental Coffee", meters: 10, visits: 20, source: .visited, targetPlaceID: "cafe"),
            candidate("Distant Warehouse", meters: 430),
        ]
        let chooser = StubChooser(
            result: ModelPlaceChoice(title: "Distant Warehouse", confidence: 1, reason: "should never be asked")
        )
        let ordered = await ranker(chooser).rank(obvious, context: context())
        XCTAssertEqual(ordered.first?.title, "Continental Coffee", "no point spending inference on a settled question")
    }

    func testUnavailableChooserDeclinesCleanly() async {
        let chooser = UnavailableChooser()
        XCTAssertFalse(chooser.isAvailable)
        do {
            _ = try await chooser.choose(from: ["a"], prompt: "p")
            XCTFail("should have thrown")
        } catch {
            // expected
        }
    }
}

// MARK: - Prompt

final class PlaceNamingPromptTests: XCTestCase {
    func testThePromptStatesTheStayAndTheCandidates() {
        let prompt = PlaceNamingPrompt.build(
            context: context(cameFrom: "Work, 18 minutes earlier"),
            candidates: [candidate("Chipotle", meters: 40, category: "Restaurant")]
        )
        XCTAssertTrue(prompt.contains("Tuesday at 12:30"))
        XCTAssertTrue(prompt.contains("40 minutes"))
        XCTAssertTrue(prompt.contains("Arrived from: Work, 18 minutes earlier"))
        XCTAssertTrue(prompt.contains("Chipotle"))
        XCTAssertTrue(prompt.contains("kind: Restaurant"))
        XCTAssertTrue(prompt.contains("40 m away"))
    }

    func testAFirstVisitSaysSoRatherThanListingNothing() {
        let prompt = PlaceNamingPrompt.build(context: context(), candidates: [candidate("Chipotle", meters: 40)])
        XCTAssertTrue(prompt.contains("first recorded stay"))
        XCTAssertFalse(prompt.contains("Earlier stays"))
    }

    func testPriorVisitsAtThisSpotAreSpelledOut() {
        let prompt = PlaceNamingPrompt.build(
            context: context(
                priorVisits: [
                    VisitNamingContext.PriorVisit(weekday: "Tuesday", startTime: "18:05", durationPhrase: "1 hour"),
                    VisitNamingContext.PriorVisit(weekday: "Thursday", startTime: "18:10", durationPhrase: "55 minutes"),
                ]
            ),
            candidates: [candidate("Fitness World", meters: 30, category: "FitnessCenter")]
        )
        XCTAssertTrue(prompt.contains("Earlier stays at this exact spot"))
        XCTAssertTrue(prompt.contains("Tuesday 18:05, 1 hour"))
        XCTAssertTrue(prompt.contains("Thursday 18:10, 55 minutes"))
    }

    func testRoutineIsIncludedWhenThereIsOne() {
        let prompt = PlaceNamingPrompt.build(
            context: context(
                routine: [VisitNamingContext.RoutineEntry(name: "Home", typicalHours: "22:00–07:30", visitCount: 6)]
            ),
            candidates: [candidate("Chipotle", meters: 40)]
        )
        XCTAssertTrue(prompt.contains("Home, typically 22:00–07:30 (6 stays)"))
    }

    func testTheInstructionsForbidInvention() {
        XCTAssertTrue(PlaceNamingPrompt.instructions.contains("Never invent a name"))
    }
}

// MARK: - Building the context

final class VisitNamingContextBuilderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }()

    /// Tuesday 10 March 2026, 12:30 local.
    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    private func visit(_ id: String, placeKey: String, day: Int, hour: Int, minutes: Double) -> TimelineVisit {
        let start = at(day: day, hour: hour)
        return TimelineVisit(
            id: id,
            start: start,
            end: start.addingTimeInterval(minutes * 60),
            coordinate: vancouver,
            semanticType: nil,
            placeKey: placeKey
        )
    }

    private func stop(day: Int, hour: Int, minute: Int = 0, minutes: Double) -> CapturedStop {
        let start = at(day: day, hour: hour, minute: minute)
        return CapturedStop(
            coordinate: vancouver,
            horizontalAccuracy: 65,
            start: start,
            end: start.addingTimeInterval(minutes * 60)
        )
    }

    func testTheStayIsDescribedInWordsAndInNumbers() {
        let built = VisitNamingContextBuilder.build(
            stop: stop(day: 10, hour: 12, minute: 30, minutes: 40),
            placeKey: "unknown",
            recentVisits: [],
            priorVisitsHere: [],
            names: [:],
            calendar: calendar
        )
        XCTAssertEqual(built.weekday, "Tuesday")
        XCTAssertEqual(built.startTime, "12:30")
        XCTAssertEqual(built.startMinutes, 12 * 60 + 30)
        XCTAssertEqual(built.durationMinutes, 40)
        XCTAssertEqual(built.durationPhrase, "40 minutes")
        XCTAssertTrue(built.isFirstVisitHere)
    }

    func testPriorVisitsHereAreNewestFirstAndExcludeThisStay() {
        let current = stop(day: 12, hour: 18, minutes: 60)
        let priors = [
            visit("p1", placeKey: "gym", day: 10, hour: 18, minutes: 55),
            visit("p2", placeKey: "gym", day: 5, hour: 18, minutes: 62),
            // The stay we are naming, already written to the library.
            TimelineVisit(
                id: "current",
                start: current.start,
                end: current.end ?? current.start,
                coordinate: vancouver,
                semanticType: nil,
                placeKey: "gym"
            ),
        ]
        let built = VisitNamingContextBuilder.build(
            stop: current,
            placeKey: "gym",
            recentVisits: [],
            priorVisitsHere: priors,
            names: [:],
            calendar: calendar
        )
        XCTAssertEqual(built.priorVisitsHere.count, 2, "the current stay must not be listed as its own precedent")
        XCTAssertEqual(built.priorVisitsHere.first?.weekday, "Tuesday")
        XCTAssertEqual(built.priorVisitsHere.first?.startTime, "18:00")
        XCTAssertFalse(built.isFirstVisitHere)
    }

    func testPriorVisitsAreCapped() {
        let priors = (1...12).map { index in
            visit("p\(index)", placeKey: "gym", day: index, hour: 18, minutes: 60)
        }
        let built = VisitNamingContextBuilder.build(
            stop: stop(day: 20, hour: 18, minutes: 60),
            placeKey: "gym",
            recentVisits: [],
            priorVisitsHere: priors,
            names: [:],
            calendar: calendar
        )
        XCTAssertEqual(built.priorVisitsHere.count, VisitNamingContextBuilder.maximumPriorVisits)
    }

    func testRoutineDescribesTheNamedPlacesActuallyUsed() {
        let recent = [
            visit("h1", placeKey: "home", day: 9, hour: 22, minutes: 540),
            visit("h2", placeKey: "home", day: 10, hour: 22, minutes: 540),
            visit("w1", placeKey: "work", day: 10, hour: 9, minutes: 480),
            visit("x1", placeKey: "nameless", day: 10, hour: 15, minutes: 30),
        ]
        let built = VisitNamingContextBuilder.build(
            stop: stop(day: 11, hour: 12, minutes: 40),
            placeKey: "unknown",
            recentVisits: recent,
            priorVisitsHere: [],
            names: ["home": "Home", "work": "Work"],
            calendar: calendar
        )
        XCTAssertEqual(built.routine.map(\.name), ["Home", "Work"], "most used first, unnamed places left out")
        XCTAssertEqual(built.routine.first?.visitCount, 2)
        XCTAssertTrue(built.routine.first?.typicalHours.hasPrefix("22:00") ?? false)
    }

    func testRoutineIsCapped() {
        var names: [String: String] = [:]
        var recent: [TimelineVisit] = []
        for index in 1...6 {
            names["p\(index)"] = "Place \(index)"
            recent.append(visit("v\(index)", placeKey: "p\(index)", day: 10, hour: 9, minutes: 60))
        }
        let built = VisitNamingContextBuilder.build(
            stop: stop(day: 11, hour: 12, minutes: 40),
            placeKey: "unknown",
            recentVisits: recent,
            priorVisitsHere: [],
            names: names,
            calendar: calendar
        )
        XCTAssertEqual(built.routine.count, VisitNamingContextBuilder.maximumRoutineEntries)
    }

    func testWhereTheyCameFromIsNamedWithTheGap() {
        let recent = [visit("w1", placeKey: "work", day: 10, hour: 9, minutes: 200)]
        let built = VisitNamingContextBuilder.build(
            // Work ends at 12:20; this stay starts at 12:30.
            stop: stop(day: 10, hour: 12, minute: 30, minutes: 40),
            placeKey: "unknown",
            recentVisits: recent,
            priorVisitsHere: [],
            names: ["work": "Work"],
            calendar: calendar
        )
        XCTAssertEqual(built.cameFrom, "Work, 10 minutes earlier")
    }

    func testAStaleStayIsNotWhereTheyCameFrom() {
        // Yesterday's office day says nothing about a stop today.
        let recent = [visit("w1", placeKey: "work", day: 9, hour: 9, minutes: 480)]
        let built = VisitNamingContextBuilder.build(
            stop: stop(day: 10, hour: 12, minute: 30, minutes: 40),
            placeKey: "unknown",
            recentVisits: recent,
            priorVisitsHere: [],
            names: ["work": "Work"],
            calendar: calendar
        )
        XCTAssertNil(built.cameFrom)
    }

    func testAnUnnamedOriginIsStillWorthMentioning() {
        let recent = [visit("u1", placeKey: "somewhere", day: 10, hour: 11, minutes: 60)]
        let built = VisitNamingContextBuilder.build(
            stop: stop(day: 10, hour: 12, minute: 30, minutes: 40),
            placeKey: "unknown",
            recentVisits: recent,
            priorVisitsHere: [],
            names: [:],
            calendar: calendar
        )
        XCTAssertEqual(built.cameFrom, "somewhere unnamed, 30 minutes earlier")
    }

    func testClockFormattingWrapsAndPads() {
        XCTAssertEqual(VisitNamingContextBuilder.clock(minutes: 0), "00:00")
        XCTAssertEqual(VisitNamingContextBuilder.clock(minutes: 9 * 60 + 5), "09:05")
        XCTAssertEqual(VisitNamingContextBuilder.clock(minutes: 24 * 60), "00:00")
    }

    func testMedianOfAnEmptyListIsZeroRatherThanACrash() {
        XCTAssertEqual(VisitNamingContextBuilder.median([]), 0)
        XCTAssertEqual(VisitNamingContextBuilder.median([10, 20, 30]), 20)
    }
}
