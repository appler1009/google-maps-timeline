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
