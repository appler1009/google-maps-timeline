import CoreLocation
import XCTest
@testable import Timeline

/// The school run: a two-minute stop CLVisit will never report, inside a drive
/// the app did record.
final class VisitTimingGuesserTests: XCTestCase {
    private let school = CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1000)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func north(_ metres: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: school.latitude + metres / 111_320, longitude: school.longitude)
    }

    private func fix(_ seconds: Double, metresAway: Double, speed: CLLocationSpeed) -> CapturedFix {
        CapturedFix(
            coordinate: north(metresAway),
            timestamp: origin.addingTimeInterval(seconds),
            horizontalAccuracy: 10,
            speed: speed
        )
    }

    func testAStopIsReadFromTheSlowFixes() {
        // Approach at speed, idle at the kerb for two minutes, drive off.
        let fixes = [
            fix(0, metresAway: 900, speed: 14),
            fix(30, metresAway: 200, speed: 11),
            fix(60, metresAway: 20, speed: 0.4),
            fix(90, metresAway: 18, speed: 0.0),
            fix(120, metresAway: 19, speed: 0.3),
            fix(180, metresAway: 240, speed: 12),
            fix(240, metresAway: 1_400, speed: 15),
        ]
        let guess = VisitTimingGuesser.guess(
            placeCoordinate: school,
            fixes: fixes,
            fallbackMidpoint: origin
        )
        XCTAssertEqual(guess.basis, .stopped)
        XCTAssertEqual(guess.start, origin.addingTimeInterval(60))
        XCTAssertEqual(guess.end, origin.addingTimeInterval(120))
    }

    func testADriveByBecomesAShortStayAroundTheClosestPass() {
        // Never stopped — the kid jumped out at a rolling halt the GPS missed.
        let fixes = [
            fix(0, metresAway: 800, speed: 13),
            fix(60, metresAway: 40, speed: 9),
            fix(120, metresAway: 850, speed: 14),
        ]
        let guess = VisitTimingGuesser.guess(
            placeCoordinate: school,
            fixes: fixes,
            fallbackMidpoint: origin
        )
        XCTAssertEqual(guess.basis, .droveBy)
        XCTAssertEqual(guess.duration, VisitTimingGuesser.driveByDuration)
        // Centred on the moment of closest approach.
        XCTAssertEqual(guess.start, origin.addingTimeInterval(60 - 60))
        XCTAssertEqual(guess.end, origin.addingTimeInterval(60 + 60))
    }

    func testMovementThatNeverComesNearIsNotEvidence() {
        let fixes = [
            fix(0, metresAway: 5_000, speed: 20),
            fix(60, metresAway: 9_000, speed: 22),
        ]
        let midpoint = origin.addingTimeInterval(3_600)
        let guess = VisitTimingGuesser.guess(
            placeCoordinate: school,
            fixes: fixes,
            fallbackMidpoint: midpoint
        )
        XCTAssertEqual(guess.basis, .unknown)
        XCTAssertEqual(guess.duration, VisitTimingGuesser.blindDuration)
        XCTAssertEqual(guess.start, midpoint.addingTimeInterval(-VisitTimingGuesser.blindDuration / 2))
    }

    func testNoFixesAtAllStillProposesSomethingEditable() {
        let midpoint = origin.addingTimeInterval(7_200)
        let guess = VisitTimingGuesser.guess(placeCoordinate: school, fixes: [], fallbackMidpoint: midpoint)
        XCTAssertEqual(guess.basis, .unknown)
        XCTAssertEqual(guess.duration, VisitTimingGuesser.blindDuration)
    }

    func testOnlyTheSlowRunContainingTheApproachCounts() {
        // Stopped at a light a few minutes earlier, well away from the school.
        let fixes = [
            fix(0, metresAway: 240, speed: 0.0),
            fix(30, metresAway: 240, speed: 0.0),
            fix(60, metresAway: 150, speed: 12),
            fix(90, metresAway: 15, speed: 0.2),
            fix(120, metresAway: 15, speed: 0.1),
            fix(150, metresAway: 400, speed: 13),
        ]
        let guess = VisitTimingGuesser.guess(
            placeCoordinate: school,
            fixes: fixes,
            fallbackMidpoint: origin
        )
        XCTAssertEqual(guess.basis, .stopped)
        XCTAssertEqual(guess.start, origin.addingTimeInterval(90), "the red light is not the drop-off")
        XCTAssertEqual(guess.end, origin.addingTimeInterval(120))
    }

    func testTheGuessIsIndependentOfFixOrder() {
        let fixes = [
            fix(120, metresAway: 19, speed: 0.3),
            fix(0, metresAway: 900, speed: 14),
            fix(60, metresAway: 20, speed: 0.4),
        ]
        let guess = VisitTimingGuesser.guess(
            placeCoordinate: school,
            fixes: fixes,
            fallbackMidpoint: origin
        )
        XCTAssertEqual(guess.basis, .stopped)
        XCTAssertEqual(guess.start, origin.addingTimeInterval(60))
    }

    // MARK: - Falling back to the day's shape

    private func visit(_ id: String, fromHour: Double, hours: Double) -> TimelineVisit {
        let start = origin.addingTimeInterval(fromHour * 3_600)
        return TimelineVisit(
            id: id,
            start: start,
            end: start.addingTimeInterval(hours * 3_600),
            coordinate: school,
            semanticType: nil,
            placeKey: "k\(id)"
        )
    }

    func testTheBiggestGapIsWhereSomethingUnrecordedProbablyHappened() {
        let visits = [
            visit("home", fromHour: 0, hours: 1),
            // four-hour hole
            visit("work", fromHour: 5, hours: 3),
            visit("shop", fromHour: 8.5, hours: 0.5),
        ]
        let midpoint = VisitTimingGuesser.largestGapMidpoint(between: visits, on: origin)
        XCTAssertEqual(midpoint, origin.addingTimeInterval(3 * 3_600), "middle of the 1h–5h gap")
    }

    func testADayWithOneStayFallsBackToNoon() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        let midpoint = VisitTimingGuesser.largestGapMidpoint(
            between: [visit("only", fromHour: 0, hours: 1)],
            on: day,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.hour, from: midpoint), 12)
    }

    /// The other device has no fixes at all — they are local scaffolding, pruned
    /// weekly and never synced — so adding a stay there could only ever propose
    /// midday. The day's route does sync, and knowing when it passed the place
    /// is enough to put the guess in the right half-hour.
    func testFallsBackToTheDaysRouteWhenThereAreNoFixes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // A straight half-hour drive; the place sits at the three-quarter mark.
        let a = CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1000)
        let b = CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1400)
        let place = CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1300)
        let path = TimelinePath(
            id: "drive",
            start: start,
            end: start.addingTimeInterval(1_800),
            points: [
                a,
                CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1200),
                place,
                b
            ],
            kind: .automobile
        )

        let guess = VisitTimingGuesser.guess(
            placeCoordinate: place,
            fixes: [],
            paths: [path],
            fallbackMidpoint: start.addingTimeInterval(40_000)
        )
        XCTAssertEqual(guess.basis, .droveBy, "the route passed it, so this is not a blind guess")
        // Three quarters of the way along a 30-minute drive.
        let expected = start.addingTimeInterval(1_350)
        XCTAssertEqual(
            guess.start.addingTimeInterval(VisitTimingGuesser.driveByDuration / 2).timeIntervalSince(expected),
            0,
            accuracy: 60
        )
    }

    /// A route that never goes near the place says nothing about when you were
    /// there, so the blind guess still applies.
    func testARouteThatMissesThePlaceIsNotEvidence() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let path = TimelinePath(
            id: "elsewhere",
            start: start,
            end: start.addingTimeInterval(1_800),
            points: [
                CLLocationCoordinate2D(latitude: 49.30, longitude: -123.10),
                CLLocationCoordinate2D(latitude: 49.31, longitude: -123.11)
            ],
            kind: .automobile
        )
        let midpoint = start.addingTimeInterval(40_000)
        let guess = VisitTimingGuesser.guess(
            placeCoordinate: CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1300),
            fixes: [],
            paths: [path],
            fallbackMidpoint: midpoint
        )
        XCTAssertEqual(guess.basis, .unknown)
    }


    /// The real shape of the problem, from a recorded drive.
    ///
    /// A half-hour drive that stopped at a music school came back as six points
    /// two to six kilometres apart, and the corner where it pulled in was the
    /// detail the simplification cut: the nearest the stored line came was 571
    /// metres. A radius tuned for fixes rejects that outright, so the guess fell
    /// back to midday even though the route says plainly when it went past.
    func testAStopSurvivesTheRoutesSimplification() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let academy = CLLocationCoordinate2D(latitude: 49.2749, longitude: -123.1444)
        let path = TimelinePath(
            id: "drive",
            start: start,
            end: start.addingTimeInterval(1_783),
            points: [
                CLLocationCoordinate2D(latitude: 49.2735, longitude: -123.2436),
                CLLocationCoordinate2D(latitude: 49.2692, longitude: -123.1848),
                CLLocationCoordinate2D(latitude: 49.2726, longitude: -123.1514),
                CLLocationCoordinate2D(latitude: 49.2727, longitude: -123.1583),
                CLLocationCoordinate2D(latitude: 49.2688, longitude: -123.1992),
                CLLocationCoordinate2D(latitude: 49.2718, longitude: -123.2494)
            ],
            kind: .automobile
        )

        let guess = VisitTimingGuesser.guess(
            placeCoordinate: academy,
            fixes: [],
            paths: [path],
            fallbackMidpoint: start.addingTimeInterval(40_000)
        )
        XCTAssertEqual(guess.basis, .droveBy)
        // The route turns around beside the school about fourteen minutes in;
        // the stay actually added by hand ran 10:01 to 10:02 on a drive that
        // began at 09:47.
        let centre = guess.start.addingTimeInterval(guess.duration / 2)
        XCTAssertEqual(centre.timeIntervalSince(start), 14 * 60, accuracy: 3 * 60)
    }

    /// Measured to the line, not its corners: a place beside a long straight leg
    /// is nowhere near either end of it.
    func testAPlaceBesideALongLegIsFound() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let a = CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.2000)
        let b = CLLocationCoordinate2D(latitude: 49.2600, longitude: -123.1000)
        // Halfway along, 200 m to the north — kilometres from either corner.
        let beside = CLLocationCoordinate2D(latitude: 49.2618, longitude: -123.1500)
        let path = TimelinePath(id: "leg", start: start, end: start.addingTimeInterval(600), points: [a, b], kind: .automobile)

        let passed = try? XCTUnwrap(VisitTimingGuesser.passingTime(placeCoordinate: beside, paths: [path]))
        XCTAssertNotNil(passed)
        XCTAssertEqual(passed?.timeIntervalSince(start) ?? 0, 300, accuracy: 30, "halfway along a ten-minute leg")
    }

}
