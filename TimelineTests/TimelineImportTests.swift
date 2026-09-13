import XCTest
@testable import Timeline

/// What an import understood, and what it quietly did not.
///
/// The importer is the part of this app most likely to break without anyone
/// noticing. Google has changed the export format before and will again, and
/// once the phone is recording for itself an export might only be opened once a
/// year — by which time a rename that stopped nine segments in ten being read
/// looks like a year that simply had less in it.
final class TimelineImportTests: XCTestCase {
    private func report(for json: String) throws -> TimelineParser.ImportReport {
        var report = TimelineParser.ImportReport()
        _ = try? TimelineParser.extract(Data(json.utf8), report: &report)
        return report
    }

    private func segment(_ body: String) -> String {
        """
        {"startTime":"2024-06-15T10:00:00.000+02:00","endTime":"2024-06-15T11:00:00.000+02:00",\(body)}
        """
    }

    private let visitBody = """
    "visit":{"topCandidate":{"placeID":"p1","semanticType":"Home","placeLocation":"geo:48.858370,2.294481"}}
    """

    func testAWholeExportIsCountedAsUnderstood() throws {
        let json = "{\"semanticSegments\":[\(segment(visitBody))]}"
        let counted = try report(for: json)
        XCTAssertEqual(counted.segments, 1)
        XCTAssertEqual(counted.visits, 1)
        XCTAssertEqual(counted.unrecognised, 0)
        XCTAssertEqual(counted.undatable, 0)
        XCTAssertFalse(counted.isSuspicious)
    }

    /// The failure that matters: a format change that leaves some of it
    /// readable. The import succeeds, a timeline appears, and most of the
    /// history is missing.
    func testSegmentsInAShapeThisCannotReadAreCounted() throws {
        let unknown = segment("\"somethingNew\":{\"topCandidate\":{\"placeID\":\"p2\"}}")
        let json = "{\"semanticSegments\":[\(segment(visitBody)),\(unknown),\(unknown),\(unknown)]}"
        let counted = try report(for: json)

        XCTAssertEqual(counted.segments, 4)
        XCTAssertEqual(counted.visits, 1)
        XCTAssertEqual(counted.unrecognised, 3)
        XCTAssertTrue(counted.isSuspicious, "three quarters unread is worth saying out loud")
        XCTAssertTrue(counted.summary.contains("3 of 4 segments not understood"))
    }

    /// Times are the field most likely to change and the hardest to notice
    /// going wrong, so they are counted apart from the rest.
    func testSegmentsWithUnreadableTimesAreCountedApart() throws {
        let undatable = """
        {"startTime":"the fifteenth of June","endTime":"later",\(visitBody)}
        """
        let json = "{\"semanticSegments\":[\(segment(visitBody)),\(undatable)]}"
        let counted = try report(for: json)

        XCTAssertEqual(counted.undatable, 1)
        XCTAssertEqual(counted.unrecognised, 0)
        XCTAssertEqual(counted.visits, 1)
    }

    /// A handful missed out of thousands is ordinary; it should not cry wolf.
    func testAFewMissedSegmentsAreNotWorthAWarning() throws {
        let unknown = segment("\"somethingNew\":{}")
        let many = (0..<50).map { _ in segment(visitBody) }.joined(separator: ",")
        let json = "{\"semanticSegments\":[\(many),\(unknown)]}"
        let counted = try report(for: json)

        XCTAssertEqual(counted.unrecognised, 1)
        XCTAssertFalse(counted.isSuspicious)
    }

    func testAFormatThisCannotReadAtAllStillThrows() {
        XCTAssertThrowsError(try TimelineParser.extract(Data("{\"whatever\":[]}".utf8)))
    }

    // MARK: - The reference export, held to its exact reading

    /// A golden file: what the bundled export parses to, written down.
    ///
    /// Not a check that parsing works — the tests above do that — but that it
    /// keeps giving the same answer. Any change to what comes out has to be
    /// re-blessed deliberately rather than discovered a year later.
    func testTheReferenceExportStillReadsTheSameWay() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "eiffel-tower-day", withExtension: "json"))
        var counted = TimelineParser.ImportReport()
        let batch = try TimelineParser.extract(Data(contentsOf: url), report: &counted)

        XCTAssertEqual(counted.segments, 3)
        XCTAssertEqual(counted.unrecognised, 0)
        XCTAssertEqual(counted.undatable, 0)
        XCTAssertEqual(counted.visits, 2)
        XCTAssertEqual(counted.activities, 1)
        XCTAssertEqual(counted.paths, 0)
        XCTAssertEqual(counted.understood, 3)

        let byStart = batch.visits.sorted { $0.start < $1.start }
        XCTAssertEqual(byStart.map(\.semanticType), ["Home", "Work"])
        XCTAssertEqual(byStart.map(\.duration), [2 * 3_600, 100 * 60])
        XCTAssertEqual(byStart[0].coordinate?.latitude ?? 0, Landmark.eiffelTower.latitude, accuracy: 0.000001)
        XCTAssertEqual(byStart[1].coordinate?.longitude ?? 0, Landmark.louvrePyramid.longitude, accuracy: 0.000001)

        let activity = try XCTUnwrap(batch.activities.first)
        XCTAssertEqual(activity.end.timeIntervalSince(activity.start), 20 * 60)
        XCTAssertEqual(activity.endCoordinate?.longitude ?? 0, Landmark.louvrePyramid.longitude, accuracy: 0.000001)
    }
}
