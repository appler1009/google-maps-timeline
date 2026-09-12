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
}
