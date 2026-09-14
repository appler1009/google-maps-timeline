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
        titles: [String: String] = [:],
        placeCoordinates: [String: CLLocationCoordinate2D] = [:]
    ) {
        if let day {
            addDayPaths(map: map, routed: routed)
            for pin in dayPins(for: day, titles: titles, placeCoordinates: placeCoordinates) {
                map.addAnnotation(pin)
            }
        } else if let place, let coordinate = place.coordinate {
            map.addAnnotation(pin(place: place, coordinate: coordinate, titles: titles))
        }
    }

    /// One pin per place, wherever the place is.
    ///
    /// It used to be one per consecutive run of stays, drawn where each stay was
    /// recorded — so going somewhere twice in a day put two pins on the map, and
    /// two copies of the name written over each other. Places you return to
    /// within the same run looked fine only because their stays happened to land
    /// on the same spot; a music school visited twice, once with a fix a couple
    /// of hundred metres out, did not.
    ///
    /// The pin goes where the place is, not where a particular fix landed. The
    /// stays keep their own coordinates: that is the record of where you
    /// actually were, and it is what says a fix was off in the first place.
    static func dayPins(
        for day: DayRecord,
        titles: [String: String],
        placeCoordinates: [String: CLLocationCoordinate2D]
    ) -> [VisitAnnotation] {
        var seen: Set<String> = []
        var pins: [VisitAnnotation] = []
        for run in PlaceVisitRun.coalesced(from: day.visits) {
            guard let visit = run.visits.first(where: { $0.coordinate != nil }),
                  let recorded = visit.coordinate else { continue }
            guard seen.insert(visit.placeKey).inserted else { continue }
            pins.append(
                pin(
                    visit: visit,
                    coordinate: placeCoordinates[visit.placeKey] ?? recorded,
                    titles: titles
                )
            )
        }
        return pins
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
        // A new name is a new width, and a label that fitted may not now.
        PinLabelLayout.apply(to: map)
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

/// A marker whose label can hang on any side of its pin.
protocol VisitMarkerLabelPlacing: AnyObject {
    /// The label's size as last laid out, or nil when the pin shows no label.
    var labelSize: CGSize? { get }
    var labelPlacement: PinLabelPlacement { get set }
    func layOutForPlacement()
}

/// Which side of its pin a place's name is written on.
enum PinLabelPlacement: CaseIterable, Equatable {
    case below, above, trailing, leading
}

/// Keeps place names from being written on top of each other.
///
/// Every label hangs below its pin until that would land it on another pin or
/// another label; then it tries above, then beside. Two places a minute's walk
/// apart — a supermarket and the liquor store next to it — sat one label exactly
/// over the other, because below is below for both. Worked out in screen space,
/// so it is redone as the map zooms: the same two pins need no help once they
/// are far enough apart on screen.
enum PinLabelLayout {
    struct Pin: Equatable {
        let id: String
        /// The pin's centre, in points, y growing downwards.
        let point: CGPoint
        let labelSize: CGSize?
    }

    /// Room kept between labels, so neighbours read as two chips, not one.
    static let clearance: CGFloat = 4

    static func place(
        _ pins: [Pin],
        pinSpan: CGFloat = MapVisitPinChrome.pinSpan,
        spacing: CGFloat = MapVisitPinChrome.labelSpacing
    ) -> [String: PinLabelPlacement] {
        // Top to bottom, then left to right: the same pins come out in the same
        // order at every zoom, so labels do not trade sides as the map moves.
        let ordered = pins.sorted {
            if $0.point.y != $1.point.y { return $0.point.y < $1.point.y }
            return $0.point.x < $1.point.x
        }
        var taken: [CGRect] = ordered.map { pin in
            CGRect(x: pin.point.x - pinSpan / 2, y: pin.point.y - pinSpan / 2, width: pinSpan, height: pinSpan)
        }
        var placements: [String: PinLabelPlacement] = [:]
        for pin in ordered {
            guard let size = pin.labelSize else { continue }
            let candidates = PinLabelPlacement.allCases.map { placement in
                (placement, rect(for: placement, size: size, at: pin.point, pinSpan: pinSpan, spacing: spacing))
            }
            let overlap = { (frame: CGRect) -> CGFloat in
                let padded = frame.insetBy(dx: -clearance, dy: -clearance)
                return taken.reduce(0) { total, other in
                    let shared = padded.intersection(other)
                    return shared.isNull ? total : total + shared.width * shared.height
                }
            }
            // The first side that is clear, or else the one that covers least.
            let chosen = candidates.first { overlap($0.1) == 0 }
                ?? candidates.min { overlap($0.1) < overlap($1.1) }!
            placements[pin.id] = chosen.0
            taken.append(chosen.1)
        }
        return placements
    }

    /// Where a label of `size` sits for a pin centred on `point`.
    static func rect(
        for placement: PinLabelPlacement,
        size: CGSize,
        at point: CGPoint,
        pinSpan: CGFloat = MapVisitPinChrome.pinSpan,
        spacing: CGFloat = MapVisitPinChrome.labelSpacing
    ) -> CGRect {
        let reach = pinSpan / 2 + spacing
        switch placement {
        case .below:
            return CGRect(x: point.x - size.width / 2, y: point.y + reach, width: size.width, height: size.height)
        case .above:
            return CGRect(x: point.x - size.width / 2, y: point.y - reach - size.height, width: size.width, height: size.height)
        case .trailing:
            return CGRect(x: point.x + reach, y: point.y - size.height / 2, width: size.width, height: size.height)
        case .leading:
            return CGRect(x: point.x - reach - size.width, y: point.y - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// Place every label on `map` as it is drawn right now.
    static func apply(to map: MKMapView) {
        var markers: [String: (VisitMarkerLabelPlacing)] = [:]
        var pins: [Pin] = []
        for annotation in map.annotations {
            guard let pin = annotation as? VisitAnnotation,
                  let marker = map.view(for: pin) as? VisitMarkerLabelPlacing else { continue }
            var point = map.convert(pin.coordinate, toPointTo: map)
            #if os(macOS)
            // AppKit counts up from the bottom; the layout counts down.
            if !map.isFlipped { point.y = map.bounds.height - point.y }
            #endif
            let id = "\(ObjectIdentifier(pin).hashValue)"
            markers[id] = marker
            pins.append(Pin(id: id, point: point, labelSize: marker.labelSize))
        }
        for (id, placement) in place(pins) {
            guard let marker = markers[id], marker.labelPlacement != placement else { continue }
            marker.labelPlacement = placement
            marker.layOutForPlacement()
        }
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
        case .walking, .cycling: return true
        case .automobile, .raw: return false
        }
    }
}
