import CoreLocation
import XCTest
@testable import Timeline

/// Runs the migration against a copy of a real library when one is present, so
/// the shape is checked against ten thousand rows of genuine mess rather than a
/// handful of invented ones. Skipped everywhere else.
///
///     cp ~/Library/Containers/com.appler.Timeline/Data/Library/Application\ Support/Timeline/library.sqlite /tmp/realcopy.sqlite
final class RealLibraryMigrationTests: XCTestCase {
    private let path = "/tmp/realcopy.sqlite"

    func testMigratingARealLibrary() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path),
            "no library copy at \(path)"
        )
        // Work on a throwaway so a re-run starts from the same place.
        let working = URL(fileURLWithPath: "/tmp/realcopy-working.sqlite")
        try? FileManager.default.removeItem(at: working)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: working)
        defer { try? FileManager.default.removeItem(at: working) }

        let db = TimelineDatabase(fileURL: working)
        let before = try await db.loadBatch()?.visits.count ?? 0
        XCTAssertGreaterThan(before, 100, "expected a substantial library")

        let result = try await db.migrateToPlaceEntities()
        print("[migration] \(result)")
        XCTAssertGreaterThan(result.placesCreated, 0)
        XCTAssertEqual(result.visitsLinked, before > 0 ? result.visitsLinked : 0)

        // Nothing may be left behind: every stay must point at a place.
        let unlinked = try await db.unlinkedVisitCount()
        XCTAssertEqual(unlinked, 0, "every stay must end up pointing at a place")

        // And the day count must not change — this moves identity, not data.
        let after = try await db.loadBatch()?.visits.count ?? 0
        XCTAssertEqual(after, before, "migrating must not add or lose stays")

        // Running it twice must be a no-op.
        let again = try await db.migrateToPlaceEntities()
        XCTAssertEqual(again.visitsLinked, 0)
    }
}

/// The reported case, checked against the real library: the night of 10–11
/// September should read as one stay at home, not vanish because a three-minute
/// walk was treated as leaving.
final class RealLibraryOvernightTests: XCTestCase {
    private let path = "/tmp/realcopy.sqlite"

    func testTheNightBeforeTheMorningDriveIsAccountedFor() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "no library copy at \(path)")
        let working = URL(fileURLWithPath: "/tmp/realcopy-overnight.sqlite")
        try? FileManager.default.removeItem(at: working)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: working)
        defer { try? FileManager.default.removeItem(at: working) }

        let db = TimelineDatabase(fileURL: working)
        _ = try await db.migrateToPlaceEntities()
        let loaded = try await db.loadBatch()
        let batch = try XCTUnwrap(loaded)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        // 08:35 local on 11 September, when the drive to the school begins.
        let driveStart = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 11, hour: 8, minute: 35)
        )!
        let theNightBefore = driveStart.addingTimeInterval(-6 * 3_600)

        let parsed = TimelineParser.assemble(batch, sourceName: "real", now: driveStart)
        let covering = parsed.days
            .flatMap(\.visits)
            .filter { $0.start <= theNightBefore && $0.end >= theNightBefore }

        XCTAssertFalse(
            covering.isEmpty,
            "the small hours of 11 September should be accounted for, not a hole in the day"
        )
        print("[overnight] \(covering.count) stay(s) cover 02:35, derived: \(covering.map(\.isDerived))")
    }
}
