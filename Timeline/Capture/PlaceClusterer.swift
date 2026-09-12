import Foundation
import CoreLocation

/// Decides which place key a freshly captured stay belongs to.
///
/// A `CLVisit` coordinate is usually 60–150 m out, so two stays at the same café
/// can land 80 m apart. Snapping to an anchor we already know keeps a place from
/// splintering into a new row every week; the radius grows with the reported
/// accuracy so a sloppy fix is allowed to reach further for a match.
enum PlaceClusterer {
    /// Never snap tighter than this, whatever the fix claims.
    static let minimumRadius: CLLocationDistance = 70
    /// Never snap further than this, however bad the fix is — beyond it the match
    /// stops meaning "the same door" and starts meaning "the same block".
    static let maximumRadius: CLLocationDistance = 180

    struct Match: Equatable {
        let placeKey: String
        /// True when this stop opened a new place rather than joining a known one.
        let isNew: Bool
        let anchor: PlaceAnchor?

        static func == (lhs: Match, rhs: Match) -> Bool {
            lhs.placeKey == rhs.placeKey && lhs.isNew == rhs.isNew && lhs.anchor == rhs.anchor
        }
    }

    static func radius(for accuracy: CLLocationAccuracy) -> CLLocationDistance {
        guard accuracy.isFinite, accuracy > 0 else { return minimumRadius }
        return min(max(accuracy, minimumRadius), maximumRadius)
    }

    /// Closest anchor inside the radius wins; ties break toward the more-visited
    /// place, so a daily stop beats a one-off that happens to sit a metre nearer.
    static func match(_ stop: CapturedStop, among anchors: [PlaceAnchor]) -> Match {
        let limit = radius(for: stop.horizontalAccuracy)
        let candidates = anchors
            .map { (anchor: $0, distance: RoutePlanner.meters(stop.coordinate, $0.coordinate)) }
            .filter { $0.distance <= limit }
            .sorted { lhs, rhs in
                if abs(lhs.distance - rhs.distance) > 15 { return lhs.distance < rhs.distance }
                if lhs.anchor.visitCount != rhs.anchor.visitCount {
                    return lhs.anchor.visitCount > rhs.anchor.visitCount
                }
                return lhs.distance < rhs.distance
            }
        if let best = candidates.first {
            return Match(placeKey: best.anchor.placeKey, isNew: false, anchor: best.anchor)
        }
        return Match(
            placeKey: Geo.placeKey(id: nil, coordinate: stop.coordinate),
            isNew: true,
            anchor: nil
        )
    }

    /// Stable across re-recording the same stay, and distinct from any import id.
    ///
    /// Deliberately *not* built from the place. It used to be, and re-clustering
    /// the same stop — which happens whenever the known places change underneath
    /// it — minted a second id instead of updating the first, so one stop at
    /// Staples appeared twice.
    static func visitID(placeKey: String = "", start: Date) -> String {
        Geo.segmentID("dv", Geo.millis(start))
    }

    static func visit(for stop: CapturedStop, placeKey: String, semanticType: String? = nil) -> TimelineVisit? {
        guard let end = stop.end else { return nil }
        return TimelineVisit(
            id: visitID(placeKey: placeKey, start: stop.start),
            start: stop.start,
            end: end,
            coordinate: stop.coordinate,
            semanticType: semanticType,
            placeKey: placeKey
        )
    }
}
