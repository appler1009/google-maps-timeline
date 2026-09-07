import SwiftUI
import MapKit
import QuartzCore
#if os(macOS)
import AppKit
#endif

struct MapCanvasView: View {
    @Environment(TimelineStore.self) private var store

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
            if store.selectedDay != nil || store.selectedPlace != nil {
                SelectionCard()
                    #if os(iOS)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .safeAreaPadding(.bottom)
                    #else
                    .padding(16)
                    .id(store.selectedDayID ?? store.selectedPlaceID.map { _ in Date.distantPast })
                    #endif
                    .transition(.opacity)
            }
        }
        .background(Palette.ink)
        #if os(macOS)
        .ignoresSafeArea(.container, edges: .top)
        #else
        .ignoresSafeArea()
        #endif
    }

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
        .background(Palette.ink.opacity(0.35))
        .allowsHitTesting(false)
    }
}

private struct TimelineKitMapHost: View {
    @Environment(TimelineStore.self) private var store

    var body: some View {
            TimelineKitMap(
            generation: store.focusGeneration,
            region: store.focusRegion,
            animated: store.focusAnimated,
            dayID: store.selectedDayID,
            placeID: store.selectedPlaceID,
            hoverID: store.hoveredVisitID,
            day: store.selectedDay,
            place: store.selectedPlace,
            hovered: store.hoveredVisit,
            routed: store.routesForDisplay,
            routeGeneration: store.routeGeneration,
            visitFocusID: store.selectedVisitID,
            onSelectVisit: { store.focusVisit(id: $0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
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
    var onSelectVisit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsTraffic = false
        map.showsCompass = true
        map.showsZoomControls = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.appearance = NSAppearance(named: .darkAqua)
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
            onSelectVisit: @escaping (String) -> Void
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
                lastRouteGeneration = routeGeneration
                lastVisitFocusID = visitFocusID
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
                lastRouteGeneration = routeGeneration
                lastVisitFocusID = visitFocusID
                if contentInFlight { return }
                crossfadePaths(map: map, day: latestDay, routed: latestRouted)
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
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for annotation in map.annotations {
                    map.view(for: annotation)?.animator().alphaValue = alpha
                }
            }
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

        private func addDayPaths(map: MKMapView, day: DayRecord, routed: [RoutedHop]) {
            if !routed.isEmpty {
                for hop in routed where hop.points.count >= 2 {
                    addPolyline(map: map, points: hop.points, kind: hop.kind)
                }
                return
            }
            for path in day.paths where path.points.count >= 2 {
                addPolyline(map: map, points: path.points, kind: path.kind)
            }
            for line in day.activityLines {
                addPolyline(map: map, points: [line.start, line.end], kind: line.kind)
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
                circleRenderer.fillColor = NSColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 0.22)
                circleRenderer.strokeColor = NSColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 0.85)
                circleRenderer.lineWidth = 1.5
                renderer = circleRenderer
            } else if let line = overlay as? KindPolyline {
                let polylineRenderer = MKPolylineRenderer(polyline: line)
                switch line.kind {
                case .walking:
                    polylineRenderer.strokeColor = NSColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 0.95)
                    polylineRenderer.lineWidth = 2.5
                    polylineRenderer.lineCap = .round
                    polylineRenderer.lineJoin = .round
                case .cycling:
                    polylineRenderer.strokeColor = NSColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 0.9)
                    polylineRenderer.lineWidth = 2.6
                    polylineRenderer.lineDashPattern = [9, 5]
                    polylineRenderer.lineCap = .round
                    polylineRenderer.lineJoin = .round
                case .raw:
                    polylineRenderer.strokeColor = NSColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 0.55)
                    polylineRenderer.lineWidth = 2
                    polylineRenderer.lineDashPattern = [5, 5]
                case .automobile:
                    polylineRenderer.strokeColor = NSColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 1)
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

final class KindPolyline: MKPolyline {
    var kind: TravelKind = .automobile
}

final class VisitAnnotation: MKPointAnnotation {
    var semantic: String?
    var visitID: String?
}

#if os(macOS)
private final class VisitMarkerView: MKAnnotationView {
    private let dot = NSView()
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .none
        canShowCallout = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.borderWidth = 1.5
        dot.layer?.borderColor = NSColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 0.9).cgColor
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 1)
        label.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        label.drawsBackground = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 8
        label.layer?.masksToBounds = true
        addSubview(dot)
        addSubview(glyph)
        addSubview(label)
        frame = CGRect(x: 0, y: 0, width: 120, height: 40)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ annotation: VisitAnnotation?) {
        label.stringValue = annotation?.title ?? "Place"
        let color: NSColor
        switch annotation?.semantic {
        case "Home": color = NSColor(red: 0.72, green: 0.42, blue: 0.22, alpha: 1)
        case "Work": color = NSColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 1)
        default: color = NSColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 1)
        }
        if let name = TimelineParser.symbolName(annotation?.semantic) {
            glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: annotation?.title)
            glyph.contentTintColor = color
            glyph.isHidden = false
            dot.isHidden = true
        } else {
            glyph.isHidden = true
            dot.isHidden = false
            dot.layer?.backgroundColor = color.cgColor
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pin: CGFloat = glyph.isHidden ? 12 : 16
        let pinFrame = CGRect(x: (bounds.width - pin) / 2, y: 18, width: pin, height: pin)
        dot.frame = pinFrame
        glyph.frame = pinFrame
        label.sizeToFit()
        let labelSize = label.frame.size
        label.frame = CGRect(
            x: (bounds.width - labelSize.width) / 2 - 4,
            y: 0,
            width: labelSize.width + 8,
            height: labelSize.height + 2
        )
        centerOffset = CGPoint(x: 0, y: -8)
    }
}
#endif

struct SelectionCard: View {
    @Environment(TimelineStore.self) private var store
    #if os(iOS)
    @State private var collapsed = true
    @State private var drag: CGFloat = 0
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 10) {
                grabber
                if let day = store.selectedDay {
                    dayHeader(day)
                } else if let place = store.selectedPlace {
                    placeHeader(place)
                }
            }
            .contentShape(Rectangle())
            .gesture(iosCardGesture)
            VStack(alignment: .leading, spacing: 10) {
                Divider().overlay(Palette.rule.opacity(0.5))
                if let day = store.selectedDay {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            store.rerouteSelectedDay()
                        } label: {
                            if store.isRerouting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Re-route", systemImage: "arrow.triangle.swap")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Palette.parchment)
                        .disabled(store.isRerouting || day.visitCount < 2)
                    }
                    dayVisits(day)
                } else if let place = store.selectedPlace {
                    placeVisits(place)
                }
            }
            .frame(height: Self.iosOpenBodyHeight, alignment: .top)
            .clipped()
            #else
            if let day = store.selectedDay {
                dayHeader(day)
                Divider().overlay(Palette.rule.opacity(0.5))
                dayVisits(day)
            } else if let place = store.selectedPlace {
                placeHeader(place)
                Divider().overlay(Palette.rule.opacity(0.5))
                placeVisits(place)
            }
            #endif
        }
        .padding(16)
        #if os(iOS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.inkLift, in: Self.legendShape)
        .overlay(Self.legendShape.stroke(Palette.parchment.opacity(0.12), lineWidth: 1))
        .offset(y: sheetHidden + sheetNudge)
        .padding(.bottom, -sheetHidden)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .animation(nil, value: drag)
        #else
        .frame(maxWidth: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: Self.legendShape)
        .overlay(Self.legendShape.stroke(Palette.parchment.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        #endif
        .foregroundStyle(Palette.parchment)
        .onDisappear { store.hoveredVisitID = nil }
    }

    private static let legendShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    #if os(iOS)
    private static let iosOpenBodyHeight: CGFloat = 280

    private var sheetExpansion: CGFloat {
        let range: CGFloat = 220
        if collapsed {
            return min(1, max(0, -drag / range))
        }
        return min(1, max(0, 1 - max(0, drag) / range))
    }

    private var sheetHidden: CGFloat {
        Self.iosOpenBodyHeight * (1 - sheetExpansion)
    }

    private var sheetNudge: CGFloat {
        if collapsed, drag > 0 { return min(24, drag * 0.16) }
        if !collapsed, drag < 0 { return max(-12, drag * 0.1) }
        return 0
    }

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Palette.parchment.opacity(0.35))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .accessibilityLabel(collapsed ? "Expand legend" : "Collapse legend")
            .onTapGesture {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    collapsed.toggle()
                    drag = 0
                }
            }
    }

    private var iosCardGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
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
                if abs(dx) > abs(dy), abs(dx) > 48, store.selectedDay != nil, abs(dy) < 50 {
                    drag = 0
                    store.stepDay(by: dx < 0 ? 1 : -1)
                    return
                }
                let collapse: Bool
                if collapsed {
                    collapse = predicted > -90 && sheetExpansion < 0.45
                } else {
                    collapse = predicted > 90 || sheetExpansion < 0.55
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    collapsed = collapse
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
                    .foregroundStyle(Palette.muted)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(daySummary(day))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Button {
                store.rerouteSelectedDay()
            } label: {
                if store.isRerouting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Re-route", systemImage: "arrow.triangle.swap")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.parchment)
            .disabled(store.isRerouting || day.visitCount < 2)
            .help("Ask Apple Maps again for road traces between this day’s stays")
        }
        #endif
    }

    @ViewBuilder
    private func dayVisits(_ day: DayRecord) -> some View {
        let rows = ForEach(day.visits) { visit in
            legendRow(
                time: visit.start.formatted(date: .omitted, time: .shortened),
                title: placeTitle(visit),
                duration: Self.duration(visit.duration),
                highlighted: store.hoveredVisitID == visit.id || store.selectedVisitID == visit.id,
                symbol: TimelineParser.symbolName(visit.semanticType)
            )
            .onHover { hovering in
                store.hoveredVisitID = hovering ? visit.id : nil
            }
            .onTapGesture {
                store.hoveredVisitID = visit.id
                store.focus(visit: visit)
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

    @ViewBuilder
    private func placeHeader(_ place: PlaceRecord) -> some View {
        Text(store.displayName(for: place))
            .font(.system(size: 20, weight: .regular, design: .serif))
        Text(store.subtitle(for: place))
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
        if let first = place.firstVisit, let last = place.lastVisit {
            Text("From \(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
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
                    .foregroundStyle(Palette.muted)
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
        HStack(alignment: .firstTextBaseline) {
            Text(time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(highlighted ? Palette.parchment : Palette.muted)
                .frame(width: title == nil ? 120 : 58, alignment: .leading)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(symbol == "house.fill" ? Palette.copper : Palette.water)
            }
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: highlighted ? .semibold : .medium))
                    .lineLimit(1)
            }
            Spacer()
            Text(duration)
                .font(.system(size: 11))
                .foregroundStyle(highlighted ? Palette.parchment : Palette.muted)
        }
        .padding(.horizontal, 6)
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
