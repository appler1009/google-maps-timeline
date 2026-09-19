import XCTest
import CoreLocation
@testable import Timeline

/// A stay added by hand must wake cloud sync, not only redraw the local UI.
@MainActor
final class ManualVisitSyncTests: XCTestCase {
    private var url: URL!
    private var database: TimelineDatabase!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-sync-\(UUID().uuidString).sqlite")
        database = TimelineDatabase(fileURL: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testAddingAStayByHandNotesTheLibraryChanged() async throws {
        let store = TimelineStore(database: database)
        let expect = expectation(forNotification: .timelineLibraryChanged, object: nil)

        store.addVisit(
            name: "School",
            coordinate: CLLocationCoordinate2D(latitude: 49.24, longitude: -123.15),
            start: Date(timeIntervalSince1970: 1_780_000_000),
            end: Date(timeIntervalSince1970: 1_780_000_120)
        )

        await fulfillment(of: [expect], timeout: 5)

        let pending = try await database.pendingChanges(limit: 20)
        XCTAssertTrue(pending.contains { $0.kind == .visit }, "the stay must be waiting to upload")
    }
}
