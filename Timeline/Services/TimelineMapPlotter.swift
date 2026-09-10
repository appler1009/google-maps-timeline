import SwiftUI
import MapKit
#if os(iOS)
import UIKit
private typealias PlatformColor = UIColor
#else
import AppKit
private typealias PlatformColor = NSColor
#endif

class KindPolyline: MKPolyline {
    var kind: TravelKind = .automobile
    var isCasing: Bool { self is PathCasingPolyline }
}

/// Separate type so MapKit cannot drop a stored `isCasing` flag when vending renderers.
final class PathCasingPolyline: KindPolyline {}

final class VisitAnnotation: MKPointAnnotation {
    var semantic: String?
    var visitID: String?
    var placeKey: String?
}

enum TimelineMapPlotter {
    static func install(
        on map: MKMapView,
        day: DayRecord?,
        place: PlaceRecord?,
        routed: [RoutedHop],
        titles: [String: String] = [:]
    ) {
        if let day {
            addDayPaths(map: map, routed: routed)
            for visit in day.visits {
                guard let coordinate = visit.coordinate else { continue }
                map.addAnnotation(pin(visit: visit, coordinate: coordinate, titles: titles))
            }
        } else if let place, let coordinate = place.coordinate {
            map.addAnnotation(pin(place: place, coordinate: coordinate, titles: titles))
        }
    }

    static func pin(
        visit: TimelineVisit,
        coordinate: CLLocationCoordinate2D,
        titles: [String: String] = [:]
    ) -> VisitAnnotation {
        let pin = VisitAnnotation()
        pin.coordinate = coordinate
        pin.placeKey = visit.placeKey
        pin.title = titles[visit.placeKey]
            ?? TimelineParser.semanticTitle(visit.semanticType)
            ?? "Unnamed place"
        pin.semantic = visit.semanticType
        pin.visitID = visit.id
        return pin
    }

    static func pin(
        place: PlaceRecord,
        coordinate: CLLocationCoordinate2D,
        titles: [String: String] = [:]
    ) -> VisitAnnotation {
        let pin = VisitAnnotation()
        pin.coordinate = coordinate
        pin.placeKey = place.id
        pin.title = titles[place.id]
            ?? TimelineParser.semanticTitle(place.semanticType)
            ?? "Unnamed place"
        pin.semantic = place.semanticType
        return pin
    }

    static func applyTitles(_ titles: [String: String], to map: MKMapView) {
        for annotation in map.annotations {
            guard let pin = annotation as? VisitAnnotation, let key = pin.placeKey else { continue }
            let next = titles[key]
                ?? TimelineParser.semanticTitle(pin.semantic)
                ?? "Unnamed place"
            guard pin.title != next else { continue }
            pin.title = next
            if let view = map.view(for: pin) as? VisitMarkerTitleUpdating {
                view.apply(pin)
            }
        }
    }

    /// Stable bottom→top order so thinner / dashed modes paint above thicker drives.
    static func orderedForDisplay(_ routed: [RoutedHop]) -> [RoutedHop] {
        routed
            .filter { $0.points.count >= 2 }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.kind.pathDrawRank != rhs.element.kind.pathDrawRank {
                    return lhs.element.kind.pathDrawRank < rhs.element.kind.pathDrawRank
                }
                if lhs.element.at != rhs.element.at {
                    return lhs.element.at < rhs.element.at
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func addDayPaths(map: MKMapView, routed: [RoutedHop]) {
        let hops = orderedForDisplay(routed)
        let kinds = Set(hops.map(\.kind))
        // Solid modes first, then every dashed halo, then dashed color — dashes stay
        // above every casing, including when walk and cycle share geometry.
        // Different kinds also get parallel lane offsets so shared snaps don’t stack.
        for hop in hops where !hop.kind.usesPathCasing {
            let points = PathOffset.displayPoints(hop.points, kind: hop.kind, amongKinds: kinds)
            addPolyline(map: map, points: points, kind: hop.kind, isCasing: false)
        }
        for hop in hops where hop.kind.usesPathCasing {
            let points = PathOffset.displayPoints(hop.points, kind: hop.kind, amongKinds: kinds)
            addPolyline(map: map, points: points, kind: hop.kind, isCasing: true)
        }
        for hop in hops where hop.kind.usesPathCasing {
            let points = PathOffset.displayPoints(hop.points, kind: hop.kind, amongKinds: kinds)
            addPolyline(map: map, points: points, kind: hop.kind, isCasing: false)
        }
    }

    static func addPolyline(
        map: MKMapView,
        points: [CLLocationCoordinate2D],
        kind: TravelKind,
        isCasing: Bool = false
    ) {
        var coords = points
        let overlay: KindPolyline = isCasing
            ? PathCasingPolyline(coordinates: &coords, count: coords.count)
            : KindPolyline(coordinates: &coords, count: coords.count)
        overlay.kind = kind
        map.addOverlay(overlay, level: .aboveRoads)
    }

    static func configure(_ renderer: MKPolylineRenderer, for line: KindPolyline) {
        if line.isCasing {
            applyCasing(to: renderer, kind: line.kind)
            return
        }
        switch line.kind {
        case .walking:
            renderer.strokeColor = platform(Palette.walk)
            renderer.lineWidth = 3
            renderer.lineDashPattern = [7, 5]
            renderer.lineCap = .round
            renderer.lineJoin = .round
        case .cycling:
            renderer.strokeColor = platform(Palette.water)
            renderer.lineWidth = 2.6
            renderer.lineDashPattern = [9, 5]
            renderer.lineCap = .round
            renderer.lineJoin = .round
        case .raw:
            renderer.strokeColor = platform(Palette.water, alpha: 0.7)
            renderer.lineWidth = 2
            renderer.lineDashPattern = [5, 5]
        case .automobile:
            renderer.strokeColor = platform(Palette.path)
            renderer.lineWidth = 3.5
            renderer.lineCap = .round
            renderer.lineJoin = .round
        }
    }

    private static func applyCasing(to renderer: MKPolylineRenderer, kind: TravelKind) {
        renderer.strokeColor = platform(Palette.parchment, alpha: 0.92)
        renderer.lineWidth = casingWidth(for: kind)
        renderer.lineCap = .round
        renderer.lineJoin = .round
        renderer.lineDashPattern = nil
    }

    private static func casingWidth(for kind: TravelKind) -> CGFloat {
        switch kind {
        case .walking: return 5
        case .cycling: return 4.5
        case .raw, .automobile: return 0
        }
    }

    private static func platform(_ color: Color, alpha: CGFloat = 1) -> PlatformColor {
        #if os(iOS)
        Palette.ui(color, alpha: alpha)
        #else
        Palette.ns(color, alpha: alpha)
        #endif
    }
}

/// Shared hook so iOS/macOS marker views can refresh titles without a full rebuild.
protocol VisitMarkerTitleUpdating: AnyObject {
    func apply(_ annotation: VisitAnnotation?)
}

private extension TravelKind {
    /// Lower ranks are drawn first (underneath).
    var pathDrawRank: Int {
        switch self {
        case .automobile: return 0
        case .raw: return 1
        case .cycling: return 2
        case .walking: return 3
        }
    }

    var usesPathCasing: Bool {
        switch self {
        case .walking, .cycling: return true
        case .automobile, .raw: return false
        }
    }
}
