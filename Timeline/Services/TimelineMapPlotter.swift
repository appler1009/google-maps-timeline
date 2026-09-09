import MapKit
#if os(iOS)
import UIKit
private typealias PlatformColor = UIColor
#else
import AppKit
private typealias PlatformColor = NSColor
#endif

final class KindPolyline: MKPolyline {
    var kind: TravelKind = .automobile
    /// Wider parchment understroke so dashed modes stay readable over drives.
    var isCasing: Bool = false
}

final class VisitAnnotation: MKPointAnnotation {
    var semantic: String?
    var visitID: String?
}

enum TimelineMapPlotter {
    static func install(on map: MKMapView, day: DayRecord?, place: PlaceRecord?, routed: [RoutedHop]) {
        if let day {
            addDayPaths(map: map, routed: routed)
            for visit in day.visits {
                guard let coordinate = visit.coordinate else { continue }
                map.addAnnotation(pin(visit: visit, coordinate: coordinate))
            }
        } else if let place, let coordinate = place.coordinate {
            map.addAnnotation(pin(place: place, coordinate: coordinate))
        }
    }

    static func pin(visit: TimelineVisit, coordinate: CLLocationCoordinate2D) -> VisitAnnotation {
        let pin = VisitAnnotation()
        pin.coordinate = coordinate
        pin.title = TimelineParser.semanticTitle(visit.semanticType) ?? "Place"
        pin.semantic = visit.semanticType
        pin.visitID = visit.id
        return pin
    }

    static func pin(place: PlaceRecord, coordinate: CLLocationCoordinate2D) -> VisitAnnotation {
        let pin = VisitAnnotation()
        pin.coordinate = coordinate
        pin.title = TimelineParser.semanticTitle(place.semanticType) ?? "Place"
        pin.semantic = place.semanticType
        return pin
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
        for hop in orderedForDisplay(routed) {
            if hop.kind.usesPathCasing {
                addPolyline(map: map, points: hop.points, kind: hop.kind, isCasing: true)
            }
            addPolyline(map: map, points: hop.points, kind: hop.kind, isCasing: false)
        }
    }

    static func addPolyline(
        map: MKMapView,
        points: [CLLocationCoordinate2D],
        kind: TravelKind,
        isCasing: Bool = false
    ) {
        var coords = points
        let overlay = KindPolyline(coordinates: &coords, count: coords.count)
        overlay.kind = kind
        overlay.isCasing = isCasing
        map.addOverlay(overlay, level: .aboveRoads)
    }

    static func configure(_ renderer: MKPolylineRenderer, for line: KindPolyline) {
        if line.isCasing {
            applyCasing(to: renderer, kind: line.kind)
            return
        }
        switch line.kind {
        case .walking:
            renderer.strokeColor = platformColor(red: 0.55, green: 0.82, blue: 0.74, alpha: 1)
            renderer.lineWidth = 3
            renderer.lineDashPattern = [7, 5]
            renderer.lineCap = .round
            renderer.lineJoin = .round
        case .cycling:
            renderer.strokeColor = platformColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 0.9)
            renderer.lineWidth = 2.6
            renderer.lineDashPattern = [9, 5]
            renderer.lineCap = .round
            renderer.lineJoin = .round
        case .raw:
            renderer.strokeColor = platformColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 0.55)
            renderer.lineWidth = 2
            renderer.lineDashPattern = [5, 5]
        case .automobile:
            renderer.strokeColor = platformColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 1)
            renderer.lineWidth = 3.5
            renderer.lineCap = .round
            renderer.lineJoin = .round
        }
    }

    private static func applyCasing(to renderer: MKPolylineRenderer, kind: TravelKind) {
        renderer.strokeColor = platformColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 0.92)
        renderer.lineWidth = casingWidth(for: kind)
        renderer.lineCap = .round
        renderer.lineJoin = .round
        renderer.lineDashPattern = nil
    }

    private static func casingWidth(for kind: TravelKind) -> CGFloat {
        switch kind {
        case .walking: return 5
        case .cycling: return 4.5
        case .raw: return 4
        case .automobile: return 3.5
        }
    }

    private static func platformColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> PlatformColor {
        PlatformColor(red: red, green: green, blue: blue, alpha: alpha)
    }
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
        case .walking, .cycling, .raw: return true
        case .automobile: return false
        }
    }
}
