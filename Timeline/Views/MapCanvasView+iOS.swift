#if os(iOS)
import SwiftUI
import MapKit
import UIKit
import QuartzCore

/// Holds space in the SwiftUI hierarchy and only mounts `MKMapView` once layout has a
/// non-empty size. Creating MapKit at 0×0 trips Debug Metal validation fatally.
final class TimelineMapHostView: UIView {
    private(set) var mapView: MKMapView?
    var onMapReady: ((MKMapView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Require a comfortable size — mid-animation frames of a few points still
        // produce invalid Metal drawables under MapKit.
        guard bounds.width >= 32, bounds.height >= 32 else {
            tearDownMap()
            return
        }
        if mapView == nil {
            let map = MKMapView(frame: bounds)
            map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            map.isPitchEnabled = false
            map.isRotateEnabled = false
            map.showsCompass = true
            map.showsScale = false
            map.overrideUserInterfaceStyle = .dark
            TimelineMapChrome.apply(to: map)
            addSubview(map)
            mapView = map
            onMapReady?(map)
            TimelineLog.debug("ios map mounted", ["w": "\(Int(bounds.width))", "h": "\(Int(bounds.height))"])
        }
        mapView?.frame = bounds
        mapView?.isHidden = false
    }

    private func tearDownMap() {
        guard let map = mapView else { return }
        map.delegate = nil
        map.removeFromSuperview()
        mapView = nil
        TimelineLog.debug("ios map torn down (undersized host)")
    }
}

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
    var placeNameGeneration: UInt64
    var annotationTitles: [String: String]
    var onSelectVisit: (String) -> Void
    /// Points of map the legend sheet covers at the bottom.
    var legendCoverage: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Clearance below the safe area for the day title / day-step chrome.
    private static let topChromeClearance: CGFloat = 56
    private static let scaleTag = 917_001

    func makeUIView(context: Context) -> TimelineMapHostView {
        TimelineMapHostView()
    }

    private static func installScale(on map: MKMapView) {
        guard map.viewWithTag(Self.scaleTag) == nil else { return }
        let scale = MKScaleView(mapView: map)
        scale.tag = Self.scaleTag
        scale.legendAlignment = .leading
        scale.scaleVisibility = .adaptive
        scale.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(scale)
        NSLayoutConstraint.activate([
            scale.leadingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            scale.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: topChromeClearance),
            scale.trailingAnchor.constraint(lessThanOrEqualTo: map.safeAreaLayoutGuide.centerXAnchor),
        ])
    }

    func updateUIView(_ host: TimelineMapHostView, context: Context) {
        let apply: (MKMapView) -> Void = { map in
            if map.delegate !== context.coordinator {
                map.delegate = context.coordinator
                Self.installScale(on: map)
            }
            guard map.bounds.width >= 2, map.bounds.height >= 2 else { return }
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
                placeNameGeneration: placeNameGeneration,
                annotationTitles: annotationTitles,
                onSelectVisit: onSelectVisit,
                legendCoverage: legendCoverage
            )
        }
        if let map = host.mapView {
            apply(map)
        } else {
            host.onMapReady = apply
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var lastDayID: Date?
        private var lastPlaceID: String?
        private var lastGeneration: UInt64 = .max
        private var hoverOverlay: MKCircle?

        private var lastHoverID: String?
        private var lastRouteGeneration: UInt64 = 0
        private var lastVisitFocusID: String?
        private var lastPlaceNameGeneration: UInt64 = .max
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
        private var latestTitles: [String: String] = [:]
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
            placeNameGeneration: UInt64,
            annotationTitles: [String: String],
            onSelectVisit: @escaping (String) -> Void,
            legendCoverage: CGFloat
        ) {
            guard map.bounds.width >= 2, map.bounds.height >= 2 else { return }
            self.onSelectVisit = onSelectVisit
            latestDay = day
            latestPlace = place
            latestRouted = routed
            latestRouteGeneration = routeGeneration
            latestVisitFocusID = visitFocusID
            latestTitles = annotationTitles
            if dayID != lastDayID || placeID != lastPlaceID {
                lastDayID = dayID
                lastPlaceID = placeID
                lastHoverID = nil
                lastPlaceNameGeneration = placeNameGeneration
                pathTick &+= 1
                contentInFlight = true
                crossfade(map: map) {
                    self.contentInFlight = false
                    self.rebuild(
                        map: map,
                        day: self.latestDay,
                        place: self.latestPlace,
                        routed: self.latestRouted,
                        titles: self.latestTitles
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
            if placeNameGeneration != lastPlaceNameGeneration {
                lastPlaceNameGeneration = placeNameGeneration
                if !contentInFlight {
                    TimelineMapPlotter.applyTitles(annotationTitles, to: map)
                }
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
            guard map.bounds.width >= 2, map.bounds.height >= 2 else { return }
            let apply = { [weak self] in
                guard let self else { return }
                guard map.bounds.width >= 2, map.bounds.height >= 2 else { return }
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
                top: map.safeAreaInsets.top + TimelineKitMap.topChromeClearance,
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

        private func rebuild(
            map: MKMapView,
            day: DayRecord?,
            place: PlaceRecord?,
            routed: [RoutedHop],
            titles: [String: String]
        ) {
            overlayRenderers.removeAll(keepingCapacity: true)
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            hoverOverlay = nil

            if let day {
                TimelineMapPlotter.install(on: map, day: day, place: nil, routed: routed, titles: titles)
            } else if let place {
                TimelineMapPlotter.install(on: map, day: nil, place: place, routed: [], titles: titles)
            }
        }

        private func addDayPaths(map: MKMapView, day _: DayRecord, routed: [RoutedHop]) {
            TimelineMapPlotter.addDayPaths(map: map, routed: routed)
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
                circleRenderer.fillColor = Palette.ui(Palette.path, alpha: 0.22)
                circleRenderer.strokeColor = Palette.ui(Palette.parchment, alpha: 0.85)
                circleRenderer.lineWidth = 1.5
                renderer = circleRenderer
            } else if let line = overlay as? KindPolyline {
                let polylineRenderer = MKPolylineRenderer(polyline: line)
                TimelineMapPlotter.configure(polylineRenderer, for: line)
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

private final class VisitMarkerView: MKAnnotationView, VisitMarkerTitleUpdating {
    private let hostingController = UIHostingController(rootView: MapVisitPinChrome(title: nil, semantic: nil))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .none
        canShowCallout = false
        clipsToBounds = false
        // Safe-area insets on the hosting view push the pin down inside the
        // annotation bounds; centerOffset then anchors the wrong point, so marks
        // drift south when zoomed out (macOS NSHostingView has no safe area).
        if #available(iOS 16.4, *) {
            hostingController.safeAreaRegions = []
        }
        hostingController.sizingOptions = [.intrinsicContentSize]
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        hostingController.view.isUserInteractionEnabled = false
        hostingController.view.insetsLayoutMarginsFromSafeArea = false
        hostingController.view.preservesSuperviewLayoutMargins = false
        hostingController.view.layoutMargins = .zero
        addSubview(hostingController.view)
        bounds.size = CGSize(width: MapVisitPinChrome.pinSpan, height: MapVisitPinChrome.pinSpan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ annotation: VisitAnnotation?) {
        isAccessibilityElement = true
        let title = annotation?.title ?? "Place"
        accessibilityLabel = title
        if let coordinate = annotation?.coordinate {
            accessibilityIdentifier = String(format: "map-marker-%.6f,%.6f", coordinate.latitude, coordinate.longitude)
            accessibilityValue = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
        } else {
            accessibilityIdentifier = "map-marker"
            accessibilityValue = nil
        }
        hostingController.rootView = MapVisitPinChrome(title: annotation?.title, semantic: annotation?.semantic)
        hostingController.view.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = hostingController.sizeThatFits(in: CGSize(width: 320, height: 200))
        let width = max(MapVisitPinChrome.pinSpan, size.width)
        let height = max(MapVisitPinChrome.pinSpan, size.height)
        bounds.size = CGSize(width: width, height: height)
        // Top-align the chrome so the pin sits at the top of the annotation view.
        hostingController.view.frame = CGRect(
            x: (width - size.width) / 2,
            y: 0,
            width: size.width,
            height: size.height
        )
        // Positive y moves the view down; shift so the pin center (not the
        // label-inclusive view center) stays on the coordinate.
        centerOffset = CGPoint(x: 0, y: height / 2 - MapVisitPinChrome.pinSpan / 2)
    }
}
#endif
