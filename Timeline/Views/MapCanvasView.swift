import SwiftUI
import MapKit
import QuartzCore
#if os(macOS)
import AppKit
#endif

struct MapCanvasView: View {
    @Environment(TimelineStore.self) private var store
    #if os(iOS)
    @Environment(\.compactMapDismiss) private var compactMapDismiss
    #endif
    @Bindable private var lux = LuxPhotoLink.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if store.parsed != nil {
                TimelineKitMapHost()
            } else if store.isLoading {
                ProgressView("Reading export")
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyMap
            }
            #if os(macOS)
            if store.activeDay != nil || store.activePlace != nil {
                SelectionCard()
                    .padding(16)
                    .id(store.tab == .dates
                        ? (store.selectedDayID.map { "day-\($0.timeIntervalSince1970)" } ?? "day")
                        : (store.selectedPlaceID.map { "place-\($0)" } ?? "place"))
                    .transition(.opacity)
            }

            LuxPhotoViewerOverlay()
                .zIndex(100)
            #endif
        }
        .onChange(of: store.selectedDayID) { _, _ in
            // Paint cached strips before SelectionCard remounts its body.
            lux.refreshPhotos(for: store.activeDay)
            lux.dismissViewer()
        }
        .onChange(of: store.tab) { _, _ in
            lux.refreshPhotos(for: store.activeDay)
            lux.dismissViewer()
        }
        #if os(iOS)
        .overlay(alignment: .top) { iosTopChrome }
        .overlay {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if store.activeDay != nil || store.activePlace != nil {
                        SelectionCard(
                            viewportHeight: geo.size.height,
                            safeAreaTop: geo.safeAreaInsets.top
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: iosViewerPresented) {
            if let photos = lux.viewerPhotos, !photos.isEmpty {
                VisitPhotoViewer(
                    photos: photos,
                    index: $lux.viewerIndex,
                    onDismiss: { lux.dismissViewer() }
                )
            }
        }
        #endif
    }

    #if os(iOS)
    private var iosViewerPresented: Binding<Bool> {
        Binding(
            get: { lux.viewerPhotos != nil },
            set: { if !$0 { lux.dismissViewer() } }
        )
    }
    #endif

    #if os(iOS)
    private var iosTopChrome: some View {
        HStack(alignment: .center, spacing: 8) {
            if let compactMapDismiss {
                Button(action: compactMapDismiss) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to list")
                .accessibilityIdentifier("back-to-list")
                .mapGlassCard(cornerRadius: 10)
            }

            if let day = store.activeDay {
                Button {
                    store.clearVisitFocus()
                } label: {
                    Text(TimelineStore.dayTitle(day.day))
                        .font(.system(size: 17, weight: .regular, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Recentre the map on this day")
                .accessibilityIdentifier("selected-day-title")
                .mapGlassCard(cornerRadius: 10)

                HStack(spacing: 0) {
                    Button {
                        store.stepDay(by: 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canStepToOlderDay)
                    .opacity(store.canStepToOlderDay ? 1 : 0.28)
                    .accessibilityLabel("Previous day")

                    Rectangle()
                        .fill(Palette.parchment.opacity(0.14))
                        .frame(width: 1, height: 20)

                    Button {
                        store.stepDay(by: -1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canStepToNewerDay)
                    .opacity(store.canStepToNewerDay ? 1 : 0.28)
                    .accessibilityLabel("Next day")
                }
                .mapGlassCard(cornerRadius: 10)
            } else if let place = store.activePlace {
                Button {
                    store.focus(place: place)
                } label: {
                    Text(store.displayName(for: place))
                        .font(.system(size: 17, weight: .regular, design: .serif))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Recentre the map on this place")
                .mapGlassCard(cornerRadius: 10)
            } else {
                Spacer()
            }
        }
        .glassCluster(spacing: 8)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .foregroundStyle(Palette.parchment)
    }
    #endif

    private var emptyMap: some View {
        VStack(spacing: 8) {
            Image(systemName: "map")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Palette.muted)
            Text("The map waits for a day or a place.")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(Palette.parchment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct UITestMapPins: View {
    var day: DayRecord?
    var place: PlaceRecord?
    var routeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(routeCount) routes")
                .accessibilityIdentifier("map-route-count")
            if let day {
                ForEach(PlaceVisitRun.coalesced(from: day.visits)) { run in
                    if let visit = run.visits.first(where: { $0.coordinate != nil }),
                       let coordinate = visit.coordinate {
                        Text(Self.coordinateID(coordinate))
                            .accessibilityIdentifier(Self.coordinateID(coordinate))
                            .accessibilityLabel(TimelineParser.semanticTitle(visit.semanticType) ?? "Place")
                    }
                }
            } else if let place, let coordinate = place.coordinate {
                Text(Self.coordinateID(coordinate))
                    .accessibilityIdentifier(Self.coordinateID(coordinate))
                    .accessibilityLabel(TimelineParser.semanticTitle(place.semanticType) ?? "Place")
            }
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(Palette.muted)
        .accessibilityElement(children: .contain)
        .allowsHitTesting(false)
    }

    private static func coordinateID(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "map-marker-%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }
}

private struct TimelineKitMapHost: View {
    @Environment(TimelineStore.self) private var store

    var body: some View {
        // Avoid creating MKMapView at 0×0 — Debug Metal validation asserts when MapKit
        // tries to draw into a CAMetalLayer with an empty drawable.
        GeometryReader { geo in
            if geo.size.width > 1, geo.size.height > 1 {
                TimelineKitMap(
                    generation: store.focusGeneration,
                    region: store.focusRegion,
                    animated: store.focusAnimated,
                    dayID: store.tab == .dates ? store.selectedDayID : nil,
                    placeID: store.tab == .places ? store.selectedPlaceID : nil,
                    hoverID: store.hoveredVisitID,
                    day: store.activeDay,
                    place: store.activePlace,
                    hovered: store.hoveredVisit,
                    routed: store.routesForDisplay,
                    routeGeneration: store.routeGeneration,
                    visitFocusID: store.selectedVisitID,
                    placeNameGeneration: store.placeNameGeneration,
                    annotationTitles: store.mapAnnotationTitles(),
                    onSelectVisit: { store.focusVisit(id: $0) },
                    legendCoverage: store.legendCoverage
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("timeline-map")
        .accessibilityValue("\(store.routesForDisplay.count) routes")
        .overlay(alignment: .topLeading) {
            if TimelineLaunch.isUITesting {
                UITestMapPins(
                    day: store.activeDay,
                    place: store.activePlace,
                    routeCount: store.routesForDisplay.count
                )
            }
        }
        #if os(iOS)
        .ignoresSafeArea()
        #else
        .ignoresSafeArea(.container, edges: .top)
        #endif
    }
}

#if os(macOS)
struct TimelineKitMap: NSViewRepresentable {
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
    /// Unused on macOS, where the legend sits beside the map rather than over it.
    var legendCoverage: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = true
        map.showsZoomControls = true
        map.showsScale = true
        map.appearance = NSAppearance(named: .darkAqua)
        TimelineMapChrome.apply(to: map)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
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
            onSelectVisit: onSelectVisit
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
        private var lastPlaceNameGeneration: UInt64 = .max
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
            onSelectVisit: @escaping (String) -> Void
        ) {
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
                lastRouteGeneration = routeGeneration
                lastVisitFocusID = visitFocusID
                lastPlaceNameGeneration = placeNameGeneration
                lastHoverID = nil
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
                lastRouteGeneration = routeGeneration
                lastVisitFocusID = visitFocusID
                if contentInFlight { return }
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
                applyRegion(map: map, region: region, animated: animated)
            }
            if hoverID != lastHoverID {
                lastHoverID = hoverID
                updateHover(map: map, visit: hovered)
            }
        }

        private func applyRegion(map: MKMapView, region: MKCoordinateRegion, animated: Bool) {
            let apply = { map.setRegion(region, animated: animated) }
            if map.bounds.width < 8 {
                DispatchQueue.main.async(execute: apply)
            } else {
                apply()
            }
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
                    map.view(for: annotation)?.alphaValue = 1
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
                circleRenderer.fillColor = Palette.ns(Palette.path, alpha: 0.22)
                circleRenderer.strokeColor = Palette.ns(Palette.parchment, alpha: 0.85)
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
            for view in views { view.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for view in views { view.animator().alphaValue = 1 }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let id = "visit"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? VisitMarkerView
                ?? VisitMarkerView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.alphaValue = 1
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
#endif

enum TimelineMapChrome {
    static func apply(to map: MKMapView) {
        map.showsTraffic = false
        map.pointOfInterestFilter = .excludingAll
        let config = MKHybridMapConfiguration(elevationStyle: .realistic)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        map.preferredConfiguration = config
    }
}

#if os(macOS)
private final class VisitMarkerView: MKAnnotationView, VisitMarkerTitleUpdating {
    private let hosting = NSHostingView(rootView: MapVisitPinChrome(title: nil, semantic: nil))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .none
        canShowCallout = false
        // Match iOS: without a clear host, alpha label fills composite onto an
        // opaque NSHostingView backdrop and look solid over the map.
        wantsLayer = true
        layer?.backgroundColor = .clear
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = [.intrinsicContentSize]
        }
        hosting.frame = .zero
        addSubview(hosting)
        bounds.size = CGSize(width: MapVisitPinChrome.pinSpan, height: MapVisitPinChrome.pinSpan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func apply(_ annotation: VisitAnnotation?) {
        hosting.rootView = MapVisitPinChrome(title: annotation?.title, semantic: annotation?.semantic)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = hosting.fittingSize
        let width = max(MapVisitPinChrome.pinSpan, size.width)
        let height = max(MapVisitPinChrome.pinSpan, size.height)
        bounds.size = CGSize(width: width, height: height)
        hosting.frame = CGRect(origin: .zero, size: bounds.size)
        // Keep the glass pin centered on the coordinate; label hangs below.
        centerOffset = CGPoint(x: 0, y: height / 2 - MapVisitPinChrome.pinSpan / 2)
    }
}
#endif

struct SelectionCard: View {
    @Environment(TimelineStore.self) private var store
    @State private var renamingPlaceID: String?
    /// The day whose "Add a stay" was tapped.
    @State private var addingStayOn: Date?
    /// The stay whose "Move to another place" was chosen.
    @State private var movingVisit: TimelineVisit?
    @Bindable private var lux = LuxPhotoLink.shared
    #if os(iOS)
    /// Full map canvas height — used to stretch the open sheet under the top chrome.
    var viewportHeight: CGFloat = 0
    var safeAreaTop: CGFloat = 0
    @State private var sheetTier: LegendSheetTier = .low
    @State private var drag: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    #endif

    /// Secondary legend copy — brighter than `Palette.muted` so times/dates stay readable on glass.
    private static let secondary = Palette.parchment.opacity(0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 10) {
                grabber
                if let day = store.activeDay {
                    HStack {
                        Text(daySummary(day))
                            .font(.system(size: 12))
                            .foregroundStyle(Self.secondary)
                        Spacer(minLength: 8)
                        rerouteControl(for: day)
                            .opacity(bodyReveal)
                            .allowsHitTesting(bodyReveal > 0.35)
                    }
                } else if let place = store.activePlace {
                    HStack(alignment: .center, spacing: 8) {
                        Text(store.subtitle(for: place))
                            .font(.system(size: 12))
                            .foregroundStyle(Self.secondary)
                        Spacer(minLength: 8)
                        if store.showsPlaceActions(place) {
                            PlaceActionsMenu(placeID: place.id) {
                                renamingPlaceID = place.id
                            }
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            .contentShape(Rectangle())
            .gesture(iosCardGesture)
            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(Palette.rule.opacity(0.5))
                if let day = store.activeDay {
                    dayVisits(day)
                } else if let place = store.activePlace {
                    placeVisits(place)
                }
            }
            // Grow/shrink height instead of offsetting a fixed tall card, so a near-full
            // sheet does not leave an invisible hit target over the map when collapsed.
            .frame(height: displayedBodyHeight, alignment: .top)
            .clipped()
            .allowsHitTesting(bodyReveal > 0.35)
            #else
            if let day = store.activeDay {
                dayHeader(day)
                Divider().overlay(Palette.rule.opacity(0.5))
                dayVisits(day)
            } else if let place = store.activePlace {
                placeHeader(place)
                Divider().overlay(Palette.rule.opacity(0.5))
                placeVisits(place)
            }
            #endif
        }
        .padding(16)
        #if os(iOS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mapGlassCard()
        .animation(nil, value: drag)
        .onAppear { publishCoverage() }
        .onChange(of: sheetTier) { _, _ in publishCoverage() }
        .onChange(of: headerHeight) { _, _ in publishCoverage() }
        .onChange(of: viewportHeight) { _, _ in publishCoverage() }
        .onChange(of: safeAreaTop) { _, _ in publishCoverage() }
        .onDisappear { store.legendCoverage = 0 }
        #else
        .frame(maxWidth: 320, alignment: .leading)
        .mapGlassCard()
        #endif
        .foregroundStyle(Palette.parchment)
        .onDisappear { store.hoveredVisitID = nil }
        .placeRenameSheet(placeID: $renamingPlaceID, store: store)
        .addVisitSheet(day: $addingStayOn, store: store)
        .moveVisitSheet(visit: $movingVisit, store: store)
        .onAppear { lux.refreshPhotos(for: store.activeDay) }
        .onChange(of: store.selectedDayID) { _, _ in
            lux.refreshPhotos(for: store.activeDay)
        }
        .onChange(of: store.tab) { _, _ in
            lux.refreshPhotos(for: store.activeDay)
        }
        .onChange(of: lux.paired?.linkedLibraryIds) { _, _ in
            lux.refreshPhotos(for: store.activeDay)
        }
        .onChange(of: lux.isConnected) { _, connected in
            if connected { lux.refreshPhotos(for: store.activeDay) }
        }
    }

    #if os(iOS)
    private enum LegendSheetTier: Int, CaseIterable {
        case low = 0
        case medium = 1
        case high = 2
    }

    private static let iosCardPadding: CGFloat = 16
    private static let iosCardSpacing: CGFloat = 10
    /// Matches `iosTopChrome`: top pad + chip row + gap under the buttons.
    private static let iosTopChromeBlock: CGFloat = 8 + 36 + 8
    private static let iosBottomPad: CGFloat = 8
    private static let iosMinBodyHeight: CGFloat = 220

    /// Visit list height at the high tier — fills the map up to under the date chrome.
    private var highBodyHeight: CGFloat {
        let header = headerHeight > 1 ? headerHeight : 56
        let cardChrome = Self.iosCardPadding * 2 + header + Self.iosCardSpacing
        let topChrome = safeAreaTop + Self.iosTopChromeBlock
        let available = viewportHeight - topChrome - Self.iosBottomPad - cardChrome
        guard viewportHeight > 1 else { return 280 }
        return max(Self.iosMinBodyHeight, available)
    }

    /// Mid-map stop between peek and full.
    private var mediumBodyHeight: CGFloat {
        let high = highBodyHeight
        return max(Self.iosMinBodyHeight, (high * 0.5).rounded())
    }

    private var settledBodyHeight: CGFloat {
        switch sheetTier {
        case .low: return 0
        case .medium: return mediumBodyHeight
        case .high: return highBodyHeight
        }
    }

    private var displayedBodyHeight: CGFloat {
        min(highBodyHeight, max(0, settledBodyHeight - drag))
    }

    private var bodyReveal: CGFloat {
        displayedBodyHeight / max(mediumBodyHeight, 1)
    }

    /// Distance from the bottom of the map to the top of the card, for the
    /// settled state only — the map must not chase the sheet mid-drag.
    private func publishCoverage() {
        let visible = Self.iosCardPadding * 2 + headerHeight + Self.iosCardSpacing + settledBodyHeight
        store.legendCoverage = visible + 8
    }

    private func nearestTier(to height: CGFloat) -> LegendSheetTier {
        let targets: [(LegendSheetTier, CGFloat)] = [
            (.low, 0),
            (.medium, mediumBodyHeight),
            (.high, highBodyHeight),
        ]
        return targets.min(by: { abs($0.1 - height) < abs($1.1 - height) })?.0 ?? .low
    }

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Palette.parchment.opacity(0.35))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .accessibilityLabel(grabberAccessibilityLabel)
            .accessibilityIdentifier("legend-grabber")
            .onTapGesture {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    sheetTier = sheetTier == .high ? .low : LegendSheetTier(rawValue: sheetTier.rawValue + 1) ?? .high
                    drag = 0
                }
            }
    }

    private var grabberAccessibilityLabel: String {
        switch sheetTier {
        case .low: return "Expand legend"
        case .medium: return "Expand legend fully"
        case .high: return "Collapse legend"
        }
    }

    private var iosCardGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) + 16 { return }
                drag = dy
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if abs(dx) > abs(dy), abs(dx) > 48, store.activeDay != nil, abs(dy) < 50 {
                    drag = 0
                    store.stepDay(by: dx < 0 ? -1 : 1)
                    return
                }
                let projected = settledBodyHeight - predicted
                let next: LegendSheetTier
                if predicted < -140 {
                    next = LegendSheetTier(rawValue: min(LegendSheetTier.high.rawValue, sheetTier.rawValue + 1)) ?? .high
                } else if predicted > 140 {
                    next = LegendSheetTier(rawValue: max(LegendSheetTier.low.rawValue, sheetTier.rawValue - 1)) ?? .low
                } else {
                    next = nearestTier(to: projected)
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    sheetTier = next
                    drag = 0
                }
            }
    }
    #endif

    @ViewBuilder
    private func dayHeader(_ day: DayRecord) -> some View {
        #if os(iOS)
        HStack(spacing: 8) {
            Button {
                store.stepDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!store.canStepToNewerDay)
            .opacity(store.canStepToNewerDay ? 1 : 0.25)
            .accessibilityLabel("Newer day")

            VStack(alignment: .leading, spacing: 4) {
                Text(TimelineStore.dayTitle(day.day))
                    .font(.system(size: 18, weight: .regular, design: .serif))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .onTapGesture { store.clearVisitFocus() }
                Text(daySummary(day))
                    .font(.system(size: 12))
                    .foregroundStyle(Self.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.stepDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!store.canStepToOlderDay)
            .opacity(store.canStepToOlderDay ? 1 : 0.25)
            .accessibilityLabel("Older day")
        }
        #else
        Text(TimelineStore.dayTitle(day.day))
            .font(.system(size: 20, weight: .regular, design: .serif))
            .onTapGesture { store.clearVisitFocus() }
            .help("Show the full day’s routes")
            .accessibilityIdentifier("selected-day-title")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(daySummary(day))
                .font(.system(size: 12))
                .foregroundStyle(Self.secondary)
            Spacer(minLength: 8)
            rerouteControl(for: day)
                .help(store.directionsThrottled
                    ? "Apple Maps is rate-limiting directions. Existing routes were kept."
                    : "Ask Apple Maps again for road traces between this day’s stays")
        }
        #endif
    }

    private func rerouteControl(for day: DayRecord) -> some View {
        let tint: Color = store.directionsThrottled ? .red : Palette.parchment
        return Button {
            store.rerouteSelectedDay()
        } label: {
            Label("Re-route", systemImage: "arrow.triangle.swap")
                .font(.system(size: 11, weight: .semibold))
                .opacity(store.isRerouting ? 0 : 1)
                .overlay {
                    if store.isRerouting {
                        RerouteSpinner()
                    }
                }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
        .tint(tint)
        .disabled(store.isRerouting || day.visitCount < 2)
        .animation(.easeInOut(duration: 0.2), value: store.directionsThrottled)
        .accessibilityIdentifier("reroute-button")
        .accessibilityValue(store.directionsThrottled ? "Rate limited" : "")
    }

    @ViewBuilder
    private func dayVisits(_ day: DayRecord) -> some View {
        let groups = PlaceVisitRun.coalesced(from: day.visits)
        let rows = ForEach(groups) { group in
            let visit = group.representative
            VStack(alignment: .leading, spacing: 0) {
                legendRow(
                    time: visit.start.formatted(date: .omitted, time: .shortened),
                    title: placeTitle(visit),
                    duration: Self.duration(group.totalDuration),
                    highlighted: group.visits.contains {
                        $0.id == store.hoveredVisitID || $0.id == store.selectedVisitID
                    },
                    symbol: TimelineParser.symbolName(visit.semanticType)
                )
                VisitPhotoStrip(photos: lux.photosByVisitID[visit.id] ?? [])
            }
            .onHover { hovering in
                store.hoveredVisitID = hovering ? visit.id : nil
            }
            .onTapGesture {
                if let place = store.place(for: visit.placeKey) {
                    store.select(place: place)
                } else {
                    store.hoveredVisitID = visit.id
                    store.focus(visit: visit)
                }
            }
            .help("Show this place")
            .accessibilityIdentifier("legend-visit-\(visit.id)")
            .accessibilityHint("Opens the place for this stay")
            .contextMenu {
                if visit.isDerived {
                    // Nothing to move: this one was inferred from the absence of
                    // travel and has no row behind it.
                    Text("Filled in from the gap")
                } else {
                    Button("Move to another place…") {
                        movingVisit = visit
                    }
                }
            }
        }
        #if os(iOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                rows
                addStayRow(day)
            }
        }
        .scrollIndicators(.visible)
        #else
        VStack(alignment: .leading, spacing: 2) {
            rows
            addStayRow(day)
        }
        .onHover { hovering in
            if !hovering { store.hoveredVisitID = nil }
        }
        #endif
    }

    /// The recorder cannot see a two-minute drop-off, so the day's list is where
    /// you notice one is missing and where you add it.
    @ViewBuilder
    private func addStayRow(_ day: DayRecord) -> some View {
        Button {
            addingStayOn = day.day
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Palette.water)
                Text("Add a stay")
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Record a stop the app did not notice")
        .accessibilityIdentifier("add-stay")
    }

    @ViewBuilder
    private func placeHeader(_ place: PlaceRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayName(for: place))
                    .font(.system(size: 20, weight: .regular, design: .serif))
                Text(store.subtitle(for: place))
                    .font(.system(size: 12))
                    .foregroundStyle(Self.secondary)
                if let first = place.firstVisit, let last = place.lastVisit {
                    Text("From \(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12))
                        .foregroundStyle(Self.secondary)
                }
            }
            Spacer(minLength: 8)
            if store.showsPlaceActions(place) {
                PlaceActionsMenu(placeID: place.id) {
                    renamingPlaceID = place.id
                }
            }
        }
    }

    @ViewBuilder
    private func placeVisits(_ place: PlaceRecord) -> some View {
        let rows = Group {
            ForEach(place.recentVisits) { visit in
                legendRow(
                    time: visit.start.formatted(date: .abbreviated, time: .shortened),
                    title: nil,
                    duration: Self.duration(visit.duration),
                    highlighted: store.hoveredVisitID == visit.id
                )
                .onHover { hovering in
                    store.hoveredVisitID = hovering ? visit.id : nil
                }
                .onTapGesture {
                    let key = Calendar.current.startOfDay(for: visit.start)
                    if let day = store.day(for: key) {
                        store.select(day: day)
                    }
                }
            }
            if place.visitCount > place.recentVisits.count {
                Text("\(place.visitCount - place.recentVisits.count) older visits")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.secondary)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            }
        }
        #if os(iOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                rows
            }
        }
        .scrollIndicators(.visible)
        #else
        VStack(alignment: .leading, spacing: 2) {
            rows
        }
        .onHover { hovering in
            if !hovering { store.hoveredVisitID = nil }
        }
        #endif
    }

    private func legendRow(time: String, title: String?, duration: String, highlighted: Bool, symbol: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LegendLayout.hStackSpacing) {
            Text(time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(highlighted ? Palette.parchment : Self.secondary)
                .frame(width: title == nil ? 120 : LegendLayout.dayTimeColumnWidth, alignment: .leading)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(symbol == "house.fill" ? Palette.copper : Palette.water)
            }
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: highlighted ? .semibold : .medium))
                    .foregroundStyle(Palette.parchment)
                    .lineLimit(1)
            }
            Spacer()
            Text(duration)
                .font(.system(size: 11))
                .foregroundStyle(highlighted ? Palette.parchment : Self.secondary)
        }
        .padding(.horizontal, LegendLayout.rowHorizontalPadding)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Palette.parchment.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func daySummary(_ day: DayRecord) -> String {
        var parts: [String] = []
        parts.append("\(day.visitCount) place\(day.visitCount == 1 ? "" : "s")")
        if day.travelMeters > 1 {
            if day.travelMeters >= 1000 {
                parts.append(String(format: "%.1f km travelled", day.travelMeters / 1000))
            } else {
                parts.append(String(format: "%.0f m travelled", day.travelMeters))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func placeTitle(_ visit: TimelineVisit) -> String {
        store.displayName(placeKey: visit.placeKey, semanticType: visit.semanticType)
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return "\(hours)h" }
        return "\(hours)h \(rem)m"
    }
}

/// Spinning glyph with no AppKit bezel — `ProgressView` draws an opaque well on the legend.
private struct RerouteSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.85)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(turn / 0.85 * 360))
        }
        .accessibilityHidden(true)
    }
}
