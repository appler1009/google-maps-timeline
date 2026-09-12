import CoreLocation
import MapKit
import XCTest
@testable import Timeline

/// A maintenance pass: ask the map where the named places on a given day
/// actually are, and optionally correct them.
///
/// Two flags, on purpose. The first only reports, so the distances can be
/// eyeballed before anything is written:
///
///     defaults write com.appler.Timeline.tests repairDay -string 2026-09-11
///     defaults write com.appler.Timeline.tests repairApply -bool YES
///
/// It writes through `setPlaceLocation`, so the correction is logged and syncs
/// like one made by hand.
final class PlaceLocationRepairTests: XCTestCase {
    private var settings: UserDefaults? { UserDefaults(suiteName: "com.appler.Timeline.tests") }
    /// A copy, not the live file: the test runner cannot read another app's
    /// container, and opening a path it cannot reach falls back to an empty
    /// in-memory database rather than failing loudly.
    private var libraryPath: String {
        settings?.string(forKey: "repairLibrary") ?? "/tmp/library.sqlite"
    }

    func testProposeCorrectionsForADay() async throws {
        guard let day = settings?.string(forKey: "repairDay") else {
            throw XCTSkip("set repairDay to a yyyy-MM-dd to run this")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libraryPath), "no library")
        let apply = settings?.bool(forKey: "repairApply") ?? false

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let dayStart = try XCTUnwrap(formatter.date(from: day))
        let dayEnd = dayStart.addingTimeInterval(24 * 3_600)

        let db = TimelineDatabase(fileURL: URL(fileURLWithPath: libraryPath))
        let named = try await db.namedPlaces(from: dayStart, to: dayEnd)
        XCTAssertFalse(named.isEmpty, "expected some named places on \(day)")

        for place in named {
            guard let name = place.name, let current = place.coordinate else { continue }
            guard let found = await Self.search(name: name, near: current) else {
                print("[repair] \(name): no match")
                continue
            }
            let metres = RoutePlanner.meters(current, found)
            print(String(
                format: "[repair] %@: %.0f m away — %.5f,%.5f -> %.5f,%.5f%@",
                name, metres,
                current.latitude, current.longitude,
                found.latitude, found.longitude,
                apply ? " (applied)" : ""
            ))
            if apply, metres > 25 {
                try await db.setPlaceLocation(placeKey: place.id, coordinate: found)
            }
        }
    }

    /// Fold same-named places that turned out to sit on top of each other.
    ///
    /// Correcting a location can reveal a duplicate rather than create one: a
    /// place added by hand got a coordinate key, the same place from an import
    /// got a Google id, and while the coordinates disagreed nothing connected
    /// them. Once both name and position agree they are one place, and the
    /// history should live together.
    func testFoldDuplicatePlacesForADay() async throws {
        guard let day = settings?.string(forKey: "repairDay") else {
            throw XCTSkip("set repairDay to a yyyy-MM-dd to run this")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libraryPath), "no library")
        let apply = settings?.bool(forKey: "repairApply") ?? false

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let dayStart = try XCTUnwrap(formatter.date(from: day))
        let dayEnd = dayStart.addingTimeInterval(24 * 3_600)

        let db = TimelineDatabase(fileURL: URL(fileURLWithPath: libraryPath))
        let onTheDay = try await db.namedPlaces(from: dayStart, to: dayEnd)
        let everywhere = try await db.loadPlaces()
        let counts = try await db.stayCountsByPlace()

        for place in onTheDay {
            guard let name = place.name, let here = place.coordinate else { continue }
            let twins = everywhere.values.filter { other in
                guard other.id != place.id, other.name == name else { return false }
                guard let there = other.coordinate else { return false }
                return RoutePlanner.meters(here, there) <= Self.sameSpot
            }
            for twin in twins {
                // The one with the history is the survivor; the other is the stray.
                let mine = counts[place.id] ?? 0
                let theirs = counts[twin.id] ?? 0
                let (from, into) = mine <= theirs ? (place.id, twin.id) : (twin.id, place.id)
                print("[fold] \(name): \(from) (\(min(mine, theirs)) stays) -> \(into)\(apply ? " (applied)" : "")")
                if apply {
                    try await db.mergePlace(from: from, into: into, targetSemantic: place.semanticType)
                }
            }
        }
    }

    /// Close enough that two rows with the same name are the same place.
    private static let sameSpot: Double = 150

    /// Apple's canonical position for a name, searched around where we think it is.
    private static func search(name: String, near: CLLocationCoordinate2D) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(center: near, latitudinalMeters: 6_000, longitudinalMeters: 6_000)
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let candidate = response.mapItems.first?.placemark.coordinate
        guard let candidate, CLLocationCoordinate2DIsValid(candidate) else { return nil }
        return candidate
    }
}


/// A one-off repair, run by hand against a copy of the real library: undo a
/// merge that folded a much-visited place into a rarely-visited one.
///
///     defaults write com.appler.Timeline.tests unmergeFrom -string "<place key>"
///     defaults write com.appler.Timeline.tests unmergeApply -bool YES
final class MergeRepairTests: XCTestCase {
    private var settings: UserDefaults? { UserDefaults(suiteName: "com.appler.Timeline.tests") }
    private var libraryPath: String {
        settings?.string(forKey: "repairLibrary") ?? "/tmp/library.sqlite"
    }

    func testUndoOneMerge() async throws {
        guard let fromKey = settings?.string(forKey: "unmergeFrom") else {
            throw XCTSkip("set unmergeFrom to a place key to run this")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libraryPath), "no library")
        let apply = settings?.bool(forKey: "unmergeApply") ?? false

        let db = TimelineDatabase(fileURL: URL(fileURLWithPath: libraryPath))
        let before = try await db.loadPlaces()
        let merges = try await db.loadPlaceMerges()
        guard let target = merges[fromKey] else {
            print("[unmerge] \(fromKey) is not merged into anything")
            return
        }
        print("[unmerge] \(fromKey) -> \(target) (\(before[target]?.name ?? "unnamed"))")

        guard apply else {
            print("[unmerge] set unmergeApply to write it")
            return
        }
        try await db.unmergePlace(from: fromKey)

        let places = try await db.loadPlaces()
        let counts = try await db.stayCountsByPlace()
        print("[unmerge] restored: \(counts[fromKey] ?? 0) stays at \(fromKey)")
        print("[unmerge] remaining at \(target): \(counts[target] ?? 0)")
        XCTAssertGreaterThan(counts[fromKey] ?? 0, 0, "the stays should have come back")
        XCTAssertNotNil(places[fromKey])
    }

    /// Merging clears the source's name, so an unmerged place comes back
    /// nameless. Give it back, then fold the near-duplicate that was sitting
    /// beside it into the one holding the history.
    ///
    ///     defaults write com.appler.Timeline.tests renameKey -string "<place key>"
    ///     defaults write com.appler.Timeline.tests renameTo -string "<name>"
    func testRenameAndConsolidate() async throws {
        guard let key = settings?.string(forKey: "renameKey"),
              let name = settings?.string(forKey: "renameTo") else {
            throw XCTSkip("set renameKey and renameTo to run this")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libraryPath), "no library")
        let db = TimelineDatabase(fileURL: URL(fileURLWithPath: libraryPath))

        try await db.setPlaceName(placeKey: key, name: name)
        let places = try await db.loadPlaces()
        let counts = try await db.stayCountsByPlace()
        let survivor = try XCTUnwrap(places[key])
        print("[rename] \(key) is now \(survivor.name ?? "unnamed") with \(counts[key] ?? 0) stays")

        // Anything else of the same name within a short walk is the same place.
        guard let here = survivor.coordinate else { return }
        for other in places.values where other.id != key && other.name == name {
            guard let there = other.coordinate else { continue }
            let metres = RoutePlanner.meters(here, there)
            guard metres <= 150 else { continue }
            let mine = counts[key] ?? 0
            let theirs = counts[other.id] ?? 0
            let (from, into) = mine <= theirs ? (key, other.id) : (other.id, key)
            print(String(format: "[rename] folding %@ (%d stays) into %@ — %.0f m apart", from, min(mine, theirs), into, metres))
            try await db.mergePlace(from: from, into: into, targetSemantic: other.semanticType)
        }
        let after = try await db.stayCountsByPlace()
        print("[rename] \(key) now holds \(after[key] ?? 0) stays")
    }


    /// Move one stay to another place.
    ///
    ///     defaults write com.appler.Timeline.tests moveVisitID -string "<visit id>"
    ///     defaults write com.appler.Timeline.tests moveToPlace -string "<place key>"
    func testMoveOneStay() async throws {
        guard let visitID = settings?.string(forKey: "moveVisitID"),
              let target = settings?.string(forKey: "moveToPlace") else {
            throw XCTSkip("set moveVisitID and moveToPlace to run this")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libraryPath), "no library")
        let db = TimelineDatabase(fileURL: URL(fileURLWithPath: libraryPath))
        let places = try await db.loadPlaces()
        print("[move] \(visitID) -> \(places[target]?.name ?? target)")
        try await db.moveVisit(id: visitID, toPlaceKey: target)
        let counts = try await db.stayCountsByPlace()
        print("[move] \(target) now holds \(counts[target] ?? 0) stays")
    }


    /// Re-queue every stay at a place, so a repair made here crosses to the
    /// other device even though its records were already acknowledged.
    ///
    ///     defaults write com.appler.Timeline.tests requeuePlace -string "<place key>"
    func testRequeueStaysAtAPlace() async throws {
        guard let placeKey = settings?.string(forKey: "requeuePlace") else {
            throw XCTSkip("set requeuePlace to a place key to run this")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libraryPath), "no library")
        let db = TimelineDatabase(fileURL: URL(fileURLWithPath: libraryPath))
        let queued = try await db.requeueStays(atPlace: placeKey)
        print("[requeue] \(queued) stays at \(placeKey)")
        XCTAssertGreaterThan(queued, 0)
    }

}
