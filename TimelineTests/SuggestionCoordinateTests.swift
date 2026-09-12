import CoreLocation
import MapKit
import XCTest
@testable import Timeline

/// A stay was added two kilometres from the school it named, because a typed
/// search result carries no position and the code fell back to the middle of the
/// map. Coordinates now travel with the suggestion, or are looked up.
final class SuggestionCoordinateTests: XCTestCase {
    private let school = CLLocationCoordinate2D(latitude: 49.2597, longitude: -123.1878)

    func testAMapResultCarriesItsPosition() async {
        let service = PlaceGuessService()
        _ = service
        // A point of interest knows where it is, so the suggestion should say so.
        let suggestion = PlaceNameSuggestion(
            id: "poi:49.2597,-123.1878:Lord Byng Secondary",
            title: "Lord Byng Secondary",
            subtitle: "School",
            source: .map,
            visitCount: 0,
            distanceMeters: 40,
            targetPlaceID: nil,
            category: "School",
            latitude: school.latitude,
            longitude: school.longitude
        )
        XCTAssertEqual(suggestion.coordinate?.latitude ?? 0, school.latitude, accuracy: 0.000_001)
        XCTAssertEqual(suggestion.coordinate?.longitude ?? 0, school.longitude, accuracy: 0.000_001)
    }

    func testATypedResultAdmitsItHasNoPosition() {
        // This is the shape that caused the bug: MKLocalSearchCompleter gives a
        // name and a subtitle, nothing more.
        let typed = PlaceNameSuggestion(
            id: "completer:Lord Byng Secondary|Vancouver, BC",
            title: "Lord Byng Secondary",
            subtitle: "Vancouver, BC",
            source: .map,
            visitCount: 0,
            distanceMeters: .infinity,
            targetPlaceID: nil
        )
        XCTAssertNil(typed.coordinate, "pretending to know would put the stay anywhere")
    }

    func testAVisitedPlaceCarriesItsOwnCoordinate() {
        let rows = PlaceGuessRanker.visitedRows(
            near: school,
            places: [(id: "byng", title: "Lord Byng", visitCount: 3, coordinate: school)],
            excluding: "other"
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].coordinate?.latitude ?? 0, school.latitude, accuracy: 0.000_001)
    }

    func testAnInvalidCoordinateIsRejected() {
        let broken = PlaceNameSuggestion(
            id: "poi:bad",
            title: "Nowhere",
            subtitle: nil,
            source: .map,
            visitCount: 0,
            distanceMeters: 10,
            targetPlaceID: nil,
            category: nil,
            latitude: 999,
            longitude: 999
        )
        XCTAssertNil(broken.coordinate)
    }

    @MainActor
    func testResolvingSomethingWeAlreadyKnowNeedsNoLookup() async {
        let suggester = PlaceNameSuggester()
        let known = PlaceNameSuggestion(
            id: "poi:49.2597,-123.1878:Lord Byng",
            title: "Lord Byng",
            subtitle: nil,
            source: .map,
            visitCount: 0,
            distanceMeters: 10,
            targetPlaceID: nil,
            category: nil,
            latitude: school.latitude,
            longitude: school.longitude
        )
        let resolved = await suggester.coordinate(for: known)
        XCTAssertEqual(resolved?.latitude ?? 0, school.latitude, accuracy: 0.000_001)
    }

    @MainActor
    func testAnUnknownTypedResultResolvesToNothingRatherThanSomewhereWrong() async {
        // Not in the completer's cache, so there is nothing to search with. The
        // answer has to be "I don't know", not the centre of the map.
        let suggester = PlaceNameSuggester()
        let orphan = PlaceNameSuggestion(
            id: "completer:Never Suggested|Nowhere",
            title: "Never Suggested",
            subtitle: "Nowhere",
            source: .map,
            visitCount: 0,
            distanceMeters: .infinity,
            targetPlaceID: nil
        )
        let resolved = await suggester.coordinate(for: orphan)
        XCTAssertNil(resolved)
    }
}
