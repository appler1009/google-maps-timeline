import XCTest
@testable import Timeline

/// The importer, run against your own Google Timeline exports.
///
/// The bundled fixture tests the parser against what this app believes the
/// format to be. These test it against what Google actually produced — which is
/// the only thing that catches the format moving underneath it. Nothing here is
/// committed: `LocalExports/` is ignored, because a real export is years of
/// precise location history.
///
/// Drop exports in and they run; leave the directory empty and they skip. See
/// the README.
final class LocalExportTests: XCTestCase {
    /// Beside the project, not inside the test bundle: these files never ship.
    private var directory: URL? {
        // TimelineTests/LocalExportTests.swift → the project root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = root.appendingPathComponent("LocalExports", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    private func exports() throws -> [URL] {
        guard let directory else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func requireExports() throws -> [URL] {
        let found = try exports()
        try XCTSkipIf(
            found.isEmpty,
            "no exports in LocalExports/ — see the README to run these against your own"
        )
        return found
    }

    /// The canary. If Google renames a field, this is what says so — before the
    /// day you need an export and find most of it missing.
    func testEveryExportIsUnderstoodInFull() throws {
        for url in try requireExports() {
            var report = TimelineParser.ImportReport()
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            XCTAssertNoThrow(
                try TimelineParser.extract(data, report: &report),
                "\(url.lastPathComponent) could not be read at all"
            )
            print("[import] \(url.lastPathComponent): \(report.summary)")
            XCTAssertFalse(
                report.isSuspicious,
                """
                \(url.lastPathComponent): \(report.unrecognised + report.undatable) of \
                \(report.segments) segments were not understood. Either the export \
                holds a shape this does not read, or the format has changed.
                """
            )
        }
    }

    /// What comes out has to be usable, not merely parseable: every stay placed
    /// somewhere, in an order that makes sense, over a plausible stretch of time.
    func testWhatComesOutOfAnExportIsCoherent() throws {
        for url in try requireExports() {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let parsed = try TimelineParser.parse(data: data, sourceName: url.lastPathComponent)
            XCTAssertFalse(parsed.days.isEmpty, "\(url.lastPathComponent) produced no days")

            for day in parsed.days {
                for visit in day.visits {
                    XCTAssertGreaterThan(
                        visit.end.timeIntervalSince(visit.start), 0,
                        "\(url.lastPathComponent): a stay ending before it began"
                    )
                    XCTAssertFalse(
                        visit.placeKey.isEmpty,
                        "\(url.lastPathComponent): a stay belonging to no place"
                    )
                }
                let starts = day.visits.map(\.start)
                XCTAssertEqual(
                    starts, starts.sorted(),
                    "\(url.lastPathComponent): a day out of order"
                )
            }
        }
    }

    /// Importing the same export twice must not double the library — the ids
    /// are content hashes precisely so a re-import is a no-op.
    func testImportingTheSameExportTwiceChangesNothing() async throws {
        let found = try requireExports()
        guard let url = found.first else { return }
        let libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-export-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let database = TimelineDatabase(fileURL: libraryURL)

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let batch = try TimelineParser.extract(data)
        try await database.upsert(batch: batch, sourceName: url.lastPathComponent)
        let first = try await database.loadBatch()?.visits.count ?? 0

        try await database.upsert(batch: batch, sourceName: url.lastPathComponent)
        let second = try await database.loadBatch()?.visits.count ?? 0

        XCTAssertEqual(second, first, "re-importing \(url.lastPathComponent) duplicated stays")
        XCTAssertGreaterThan(first, 0)
    }
}
