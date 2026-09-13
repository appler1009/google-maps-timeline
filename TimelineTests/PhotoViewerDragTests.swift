import SwiftUI
import XCTest
@testable import Timeline

/// Reading a drag across the photo viewer: sideways moves between photos, up or
/// down puts it away. One gesture doing two jobs, so which job it did is worth
/// being sure about.
final class PhotoViewerDragTests: XCTestCase {
    private func outcome(_ width: CGFloat, _ height: CGFloat, predicted: CGSize? = nil) -> PhotoViewerDrag.Outcome {
        let translation = CGSize(width: width, height: height)
        return PhotoViewerDrag.outcome(
            translation: translation,
            predictedEnd: predicted ?? translation
        )
    }

    func testAFirmPullDownPutsItAway() {
        XCTAssertEqual(outcome(0, PhotoViewerDrag.dismissDistance), .dismiss)
        XCTAssertEqual(outcome(0, 400), .dismiss)
    }

    /// Up as well as down: reaching the top of a tall phone to dismiss is worse
    /// than flicking whichever way the thumb already is.
    func testAFirmPushUpPutsItAwayToo() {
        XCTAssertEqual(outcome(0, -PhotoViewerDrag.dismissDistance), .dismiss)
        XCTAssertEqual(outcome(0, -400), .dismiss)
    }

    /// A flick that stops short still means it — what matters is where it was
    /// heading, not where the finger happened to leave the glass.
    func testAQuickFlickCountsEvenWhenItStopsShort() {
        XCTAssertEqual(
            outcome(0, 40, predicted: CGSize(width: 0, height: PhotoViewerDrag.throwDistance)),
            .dismiss
        )
        XCTAssertEqual(
            outcome(0, -40, predicted: CGSize(width: 0, height: -PhotoViewerDrag.throwDistance)),
            .dismiss
        )
    }

    func testSidewaysStillMovesBetweenPhotos() {
        XCTAssertEqual(outcome(-PhotoViewerDrag.navigateDistance, 0), .next)
        XCTAssertEqual(outcome(PhotoViewerDrag.navigateDistance, 0), .previous)
    }

    /// A drag that wanders is read as the thing it did most of, so leaning
    /// slightly while swiping across does not throw the photo away.
    func testTheDominantDirectionWins() {
        XCTAssertEqual(outcome(-200, 60), .next, "mostly sideways")
        XCTAssertEqual(outcome(60, 200), .dismiss, "mostly downward")
        XCTAssertEqual(outcome(-200, -190), .next, "still mostly sideways")
    }

    /// The axis is read from where the finger went, not from where it was
    /// heading. A flick between photos that drifts downward as it lifts still
    /// pages, whatever its momentum says — otherwise paging would occasionally
    /// throw the photo away instead.
    func testMomentumDoesNotChooseTheAxis() {
        XCTAssertEqual(
            outcome(-200, 60, predicted: CGSize(width: -220, height: 400)),
            .next,
            "mostly sideways, however it was heading"
        )
        XCTAssertEqual(
            outcome(60, 200, predicted: CGSize(width: 400, height: 220)),
            .dismiss,
            "and mostly downward stays downward"
        )
    }

    /// Something has to win a dead-on diagonal, and paging is the one you can
    /// undo by paging back.
    func testADiagonalCountsAsSideways() {
        XCTAssertEqual(outcome(-100, 100), .next)
        XCTAssertEqual(outcome(100, -100), .previous)
    }

    /// A quick flick sideways counts the same way a quick flick down does. Only
    /// having the allowance on one axis made paging feel sticky beside a
    /// dismiss that went at a touch.
    func testAQuickFlickPagesEvenWhenItStopsShort() {
        XCTAssertEqual(
            outcome(-20, 0, predicted: CGSize(width: -PhotoViewerDrag.navigateThrowDistance, height: 0)),
            .next
        )
        XCTAssertEqual(
            outcome(20, 0, predicted: CGSize(width: PhotoViewerDrag.navigateThrowDistance, height: 0)),
            .previous
        )
    }

    /// Neither far enough nor thrown: put it back rather than guess.
    func testASmallDragDoesNothing() {
        XCTAssertEqual(outcome(0, 30), .stay)
        XCTAssertEqual(outcome(0, -30), .stay)
        XCTAssertEqual(outcome(20, 0), .stay)
        XCTAssertEqual(outcome(0, 0), .stay)
    }

    /// The photo shrinks and the ground fades as it is pulled, and both stop at
    /// the point the release would dismiss.
    func testProgressRunsFromNothingToWholeAndNoFurther() {
        XCTAssertEqual(PhotoViewerDrag.progress(height: 0), 0)
        XCTAssertEqual(PhotoViewerDrag.progress(height: PhotoViewerDrag.dismissDistance / 2), 0.5, accuracy: 0.01)
        XCTAssertEqual(PhotoViewerDrag.progress(height: PhotoViewerDrag.dismissDistance), 1)
        XCTAssertEqual(PhotoViewerDrag.progress(height: 1_000), 1, "never past the end")
        XCTAssertEqual(PhotoViewerDrag.progress(height: -PhotoViewerDrag.dismissDistance), 1, "either way")
    }
}
