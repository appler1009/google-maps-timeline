#if os(iOS)
import SwiftUI
import MapKit
import UIKit
import QuartzCore

struct TimelineKitMap: UIViewRepresentable {
    var generation: UInt64
    var region: MKCoordinateRegion
    var animated: Bool
    var dayID: Date?
    var placeID: String?
    var hoverID: String?
    var day: DayRecord?
    var place: PlaceRecord?
    var hovered: TimelineVisit?
    var routed: [RoutedHop]
    var routeGeneration: UInt64
    var visitFocusID: String?
    var onSelectVisit: (String) -> Void
    /// Points of map the legend sheet covers at the bottom.
    var legendCoverage: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = true
        map.showsScale = true
        map.overrideUserInterfaceStyle = .dark
        TimelineMapChrome.apply(to: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.sync(
            map: map,
            generation: generation,
            region: region,
            animated: animated,
            dayID: dayID,
            placeID: placeID,
            hoverID: hoverID,
            day: day,
            place: place,
            hovered: hovered,
            routed: routed,
            routeGeneration: routeGeneration,
            visitFocusID: visitFocusID,
            onSelectVisit: onSelectVisit,
            legendCoverage: legendCoverage
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var lastDayID: Date?
        private var lastPlaceID: String?
        private var lastGeneration: UInt64 = .max
        private var hoverOverlay: MKCircle?

        private var lastHoverID: String?
        private var lastRouteGeneration: UInt64 = 0
        private var lastVisitFocusID: String?
        private var lastRegion: MKCoordinateRegion?
        private var lastLegendCoverage: CGFloat = -1
        /// Set once the user pans or zooms by hand: from then on the map is
        /// theirs until the next deliberate focus.
        private var userAdjusted = false
        private var programmaticChanges = 0
        private var overlayRenderers: [ObjectIdentifier: MKOverlayRenderer] = [:]
        private var contentTick: UInt64 = 0
        private var pathTick: UInt64 = 0
        private var annotationFadeIn = false
        private var contentInFlight = false
        private var latestDay: DayRecord?
        private var latestPlace: PlaceRecord?
        private var latestRouted: [RoutedHop] = []
        private var latestRouteGeneration: UInt64 = 0
        private var latestVisitFocusID: String?
        var onSelectVisit: ((String) -> Void)?

        func sync(
            map: MKMapView,
            generation: UInt64,
            region: MKCoordinateRegion,
            animated: Bool,
            dayID: Date?,
            placeID: String?,
            hoverID: String?,
            day: DayRecord?,
            place: PlaceRecord?,
            hovered: TimelineVisit?,
            routed: [RoutedHop],
            routeGeneration: UInt64,
            visitFocusID: String?,
            onSelectVisit: @escaping (String) -> Void,
            legendCoverage: CGFloat
        ) {
            self.onSelectVisit = onSelectVisit
            latestDay = day
            latestPlace = place
            latestRouted = routed
            latestRouteGeneration = routeGeneration
            latestVisitFocusID = visitFocusID
            if dayID != lastDayID || placeID != lastPlaceID {
                lastDayID = dayID
                lastPlaceID = placeID
                lastHoverID = nil
                pathTick &+= 1
                contentInFlight = true
                crossfade(map: map) {
                    self.contentInFlight = false
                    self.rebuild(
                        map: map,
                        day: self.latestDay,
                        place: self.latestPlace,
                        routed: self.latestRouted
                    )
                    self.lastRouteGeneration = self.latestRouteGeneration
                    self.lastVisitFocusID = self.latestVisitFocusID
                }
            } else if routeGeneration != lastRouteGeneration || visitFocusID != lastVisitFocusID {
                if contentInFlight { return }
                lastRouteGeneration = routeGeneration
                lastVisitFocusID = visitFocusID
                crossfadePaths(map: map, day: latestDay, routed: latestRouted)
            }
            if generation != lastGeneration {
                lastGeneration = generation
                lastRegion = region
                userAdjusted = false
                lastLegendCoverage = legendCoverage
                applyRegion(map: map, region: region, animated: animated)
            } else if legendCoverage != lastLegendCoverage {
                let first = lastLegendCoverage < 0
                lastLegendCoverage = legendCoverage
                if !first, !userAdjusted, let region = lastRegion {
                    applyRegion(map: map, region: region, animated: true)
                }
            }
            if hoverID != lastHoverID {
                lastHoverID = hoverID
                updateHover(map: map, visit: hovered)
            }
        }

        private func applyRegion(map: MKMapView, region: MKCoordinateRegion, animated: Bool) {
            let apply = { [weak self] in
                guard let self else { return }
                self.programmaticChanges += 1
                map.setVisibleMapRect(
                    Self.mapRect(for: region),
                    edgePadding: self.edgePadding(for: map),
                    animated: animated
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.45 : 0.05)) {
                    self.programmaticChanges = max(0, self.programmaticChanges - 1)
                }
            }
            if map.bounds.width < 8 {
                DispatchQueue.main.async(execute: apply)
            } else {
                apply()
            }
        }

        /// Keep the day clear of the top chrome and the legend sheet, so it is
        /// centred in the part of the map you can actually see.
        private func edgePadding(for map: MKMapView) -> UIEdgeInsets {
            let bottom = min(lastLegendCoverage, map.bounds.height * 0.6)
            return UIEdgeInsets(
                top: map.safeAreaInsets.top + 56,
                left: 24,
                bottom: max(map.safeAreaInsets.bottom, bottom),
                right: 24
            )
        }

        private static func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
            let a = MKMapPoint(CLLocationCoordinate2D(
                latitude: region.center.latitude + region.span.latitudeDelta / 2,
                longitude: region.center.longitude - region.span.longitudeDelta / 2
            ))
            let b = MKMapPoint(CLLocationCoordinate2D(
                latitude: region.center.latitude - region.span.latitudeDelta / 2,
                longitude: region.center.longitude + region.span.longitudeDelta / 2
            ))
            return MKMapRect(
                x: min(a.x, b.x),
                y: min(a.y, b.y),
                width: abs(a.x - b.x),
                height: abs(a.y - b.y)
            )
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard programmaticChanges == 0 else { return }
            let touching = mapView.subviews.first?.gestureRecognizers?.contains {
                $0.state == .began || $0.state == .changed || $0.state == .ended
            }
            if touching == true { userAdjusted = true }
        }

        private func crossfade(map: MKMapView, rebuild: @escaping () -> Void) {
            contentTick &+= 1
            let tick = contentTick
            let vacant = map.overlays.isEmpty && map.annotations.isEmpty
            let install = {
                guard tick == self.contentTick else { return }
                self.annotationFadeIn = true
                rebuild()
                for annotation in map.annotations {
                    map.view(for: annotation)?.alpha = 1
                }
                for overlay in map.overlays {
                    self.overlayRenderers[ObjectIdentifier(overlay)]?.alpha = 0
                }
                self.fadeMap(map, to: 1, duration: 0.32, token: tick)
            }
            if vacant {
                install()
                return
            }
            fadeMap(map, to: 0, duration: 0.18, token: tick, completion: install)
        }

        private func crossfadePaths(map: MKMapView, day: DayRecord?, routed: [RoutedHop]) {
            pathTick &+= 1
            let tick = pathTick
            let stale = map.overlays.filter { $0 is KindPolyline }
            fadeOverlays(stale, to: 0, duration: 0.16, stillCurrent: { tick == self.pathTick }) {
                guard tick == self.pathTick else { return }
                map.removeOverlays(stale)
                stale.forEach { self.overlayRenderers.removeValue(forKey: ObjectIdentifier($0)) }
                guard let day = self.latestDay else { return }
                self.addDayPaths(map: map, day: day, routed: self.latestRouted)
                let fresh = map.overlays.filter { $0 is KindPolyline }
                fresh.forEach { self.overlayRenderers[ObjectIdentifier($0)]?.alpha = 0 }
                self.fadeOverlays(fresh, to: 1, duration: 0.28, stillCurrent: { tick == self.pathTick })
            }
        }

        private func fadeMap(_ map: MKMapView, to alpha: CGFloat, duration: TimeInterval, token: UInt64, completion: (() -> Void)? = nil) {
            fadeOverlays(map.overlays, to: alpha, duration: duration, stillCurrent: { token == self.contentTick }, completion: completion)
        }

        private func fadeOverlays(
            _ overlays: [MKOverlay],
            to alpha: CGFloat,
            duration: TimeInterval,
            stillCurrent: @escaping () -> Bool,
            completion: (() -> Void)? = nil
        ) {
            let renderers = overlays.compactMap { overlayRenderers[ObjectIdentifier($0)] }
            guard !renderers.isEmpty else {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    guard stillCurrent() else { return }
                    completion?()
                }
                return
            }
            let start = renderers.map(\.alpha)
            let begun = CACurrentMediaTime()
            func frame() {
                guard stillCurrent() else { return }
                let u = min(1, (CACurrentMediaTime() - begun) / duration)
                let t = u * u * (3 - 2 * u)
                for (index, renderer) in renderers.enumerated() {
                    renderer.alpha = start[index] + (alpha - start[index]) * t
                }
                if u < 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: frame)
                } else {
                    completion?()
                }
            }
            frame()
        }

        private func rebuild(map: MKMapView, day: DayRecord?, place: PlaceRecord?, routed: [RoutedHop]) {
            overlayRenderers.removeAll(keepingCapacity: true)
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            hoverOverlay = nil

            if let day {
                addDayPaths(map: map, day: day, routed: routed)
                for visit in day.visits {
                    guard let coordinate = visit.coordinate else { continue }
                    let pin = VisitAnnotation()
                    pin.coordinate = coordinate
                    pin.title = TimelineParser.semanticTitle(visit.semanticType) ?? "Place"
                    pin.semantic = visit.semanticType
                    pin.visitID = visit.id
                    map.addAnnotation(pin)
                }
            } else if let place, let coordinate = place.coordinate {
                let pin = VisitAnnotation()
                pin.coordinate = coordinate
                pin.title = TimelineParser.semanticTitle(place.semanticType) ?? "Place"
                pin.semantic = place.semanticType
                map.addAnnotation(pin)
            }
        }

        private func addDayPaths(map: MKMapView, day _: DayRecord, routed: [RoutedHop]) {
            for hop in routed where hop.points.count >= 2 {
                addPolyline(map: map, points: hop.points, kind: hop.kind)
            }
        }

        private func addPolyline(map: MKMapView, points: [CLLocationCoordinate2D], kind: TravelKind) {
            var coords = points
            let overlay = KindPolyline(coordinates: &coords, count: coords.count)
            overlay.kind = kind
            map.addOverlay(overlay, level: .aboveRoads)
        }

        private func updateHover(map: MKMapView, visit: TimelineVisit?) {
            if let hoverOverlay {
                map.removeOverlay(hoverOverlay)
                self.hoverOverlay = nil
            }
            guard let visit, let coordinate = visit.coordinate else { return }
            let radius = max(60.0, min(220.0, (visit.duration / 60) * 1.5 + 50))
            let circle = MKCircle(center: coordinate, radius: radius)
            hoverOverlay = circle
            map.addOverlay(circle, level: .aboveLabels)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer: MKOverlayRenderer
            if let circle = overlay as? MKCircle {
                let circleRenderer = MKCircleRenderer(circle: circle)
                circleRenderer.fillColor = UIColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 0.22)
                circleRenderer.strokeColor = UIColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 0.85)
                circleRenderer.lineWidth = 1.5
                renderer = circleRenderer
            } else if let line = overlay as? KindPolyline {
                let polylineRenderer = MKPolylineRenderer(polyline: line)
                switch line.kind {
                case .walking:
                    polylineRenderer.strokeColor = UIColor(red: 0.55, green: 0.82, blue: 0.74, alpha: 1)
                    polylineRenderer.lineWidth = 3
                    polylineRenderer.lineDashPattern = [7, 5]
                    polylineRenderer.lineCap = .round
                    polylineRenderer.lineJoin = .round
                case .cycling:
                    polylineRenderer.strokeColor = UIColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 0.9)
                    polylineRenderer.lineWidth = 2.6
                    polylineRenderer.lineDashPattern = [9, 5]
                    polylineRenderer.lineCap = .round
                    polylineRenderer.lineJoin = .round
                case .raw:
                    polylineRenderer.strokeColor = UIColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 0.55)
                    polylineRenderer.lineWidth = 2
                    polylineRenderer.lineDashPattern = [5, 5]
                case .automobile:
                    polylineRenderer.strokeColor = UIColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 1)
                    polylineRenderer.lineWidth = 3.5
                    polylineRenderer.lineCap = .round
                    polylineRenderer.lineJoin = .round
                }
                renderer = polylineRenderer
            } else {
                renderer = MKOverlayRenderer(overlay: overlay)
            }
            overlayRenderers[ObjectIdentifier(overlay)] = renderer
            return renderer
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            guard annotationFadeIn else { return }
            annotationFadeIn = false
            for view in views { view.alpha = 0 }
            UIView.animate(withDuration: 0.32, delay: 0, options: .curveEaseInOut) {
                for view in views { view.alpha = 1 }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let id = "visit"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? VisitMarkerView
                ?? VisitMarkerView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.alpha = 1
            view.apply(annotation as? VisitAnnotation)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            mapView.deselectAnnotation(view.annotation, animated: false)
            if let visitID = (view.annotation as? VisitAnnotation)?.visitID {
                onSelectVisit?(visitID)
                return
            }
            guard let coordinate = view.annotation?.coordinate else { return }
            mapView.setRegion(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.0028, longitudeDelta: 0.0028)
                ),
                animated: true
            )
        }
    }
}

private final class VisitMarkerView: MKAnnotationView {
    private let dot = UIView()
    private let glyph = UIImageView()
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .none
        canShowCallout = false
        dot.layer.cornerRadius = 6
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = UIColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 0.9).cgColor
        glyph.contentMode = .scaleAspectFit
        glyph.preferredSymbolConfiguration = .init(pointSize: 13, weight: .semibold)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = UIColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 1)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.textAlignment = .center
        clipsToBounds = false
        addSubview(dot)
        addSubview(glyph)
        addSubview(label)
        bounds.size = CGSize(width: 12, height: 12)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ annotation: VisitAnnotation?) {
        label.text = annotation?.title ?? "Place"
        let color: UIColor
        switch annotation?.semantic {
        case "Home": color = UIColor(red: 0.72, green: 0.42, blue: 0.22, alpha: 1)
        case "Work": color = UIColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 1)
        default: color = UIColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 1)
        }
        if let name = TimelineParser.symbolName(annotation?.semantic) {
            glyph.image = UIImage(systemName: name)
            glyph.tintColor = color
            glyph.isHidden = false
            dot.isHidden = true
        } else {
            glyph.isHidden = true
            dot.isHidden = false
            dot.backgroundColor = color
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pin: CGFloat = glyph.isHidden ? 12 : 16
        bounds.size = CGSize(width: pin, height: pin)
        let pinFrame = CGRect(x: 0, y: 0, width: pin, height: pin)
        dot.frame = pinFrame
        glyph.frame = pinFrame
        let labelSize = label.intrinsicContentSize
        let labelWidth = labelSize.width + 8
        let labelHeight = labelSize.height + 2
        label.frame = CGRect(
            x: (pin - labelWidth) / 2,
            y: pin + 4,
            width: labelWidth,
            height: labelHeight
        )
        centerOffset = .zero
    }
}
#endif
