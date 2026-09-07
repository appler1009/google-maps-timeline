import SwiftUI
import MapKit
import AppKit

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
                    .padding(20)
            }
        }
        .background(Palette.ink)
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
            hovered: store.hoveredVisit
        )
    }
}

private struct TimelineKitMap: NSViewRepresentable {
    var generation: UInt64
    var region: MKCoordinateRegion
    var animated: Bool
    var dayID: Date?
    var placeID: String?
    var hoverID: String?
    var day: DayRecord?
    var place: PlaceRecord?
    var hovered: TimelineVisit?

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
            hovered: hovered
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var lastDayID: Date?
        private var lastPlaceID: String?
        private var lastGeneration: UInt64 = .max
        private var hoverOverlay: MKCircle?

        private var lastHoverID: String?

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
            hovered: TimelineVisit?
        ) {
            if dayID != lastDayID || placeID != lastPlaceID {
                lastDayID = dayID
                lastPlaceID = placeID
                rebuild(map: map, day: day, place: place)
                lastHoverID = nil
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

        private func rebuild(map: MKMapView, day: DayRecord?, place: PlaceRecord?) {
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            hoverOverlay = nil

            if let day {
                for path in day.paths where path.points.count >= 2 {
                    addPolyline(map: map, points: path.points, dashed: false)
                }
                for line in day.activityLines {
                    addPolyline(map: map, points: [line.start, line.end], dashed: true)
                }
                for visit in day.visits {
                    guard let coordinate = visit.coordinate else { continue }
                    let pin = VisitAnnotation()
                    pin.coordinate = coordinate
                    pin.title = TimelineParser.semanticTitle(visit.semanticType) ?? "Place"
                    pin.semantic = visit.semanticType
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

        private func addPolyline(map: MKMapView, points: [CLLocationCoordinate2D], dashed: Bool) {
            var coords = points
            let overlay: MKPolyline = dashed
                ? DashPolyline(coordinates: &coords, count: coords.count)
                : PathPolyline(coordinates: &coords, count: coords.count)
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
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = NSColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 0.22)
                renderer.strokeColor = NSColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 0.85)
                renderer.lineWidth = 1.5
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                if overlay is DashPolyline {
                    renderer.strokeColor = NSColor(red: 0.16, green: 0.45, blue: 0.42, alpha: 0.55)
                    renderer.lineWidth = 2
                    renderer.lineDashPattern = [5, 5]
                } else {
                    renderer.strokeColor = NSColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 1)
                    renderer.lineWidth = 3.5
                    renderer.lineCap = .round
                    renderer.lineJoin = .round
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
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

private final class PathPolyline: MKPolyline {}
private final class DashPolyline: MKPolyline {}

private final class VisitAnnotation: MKPointAnnotation {
    var semantic: String?
}

private final class VisitMarkerView: MKAnnotationView {
    private let dot = NSView()
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
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 1)
        label.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        label.drawsBackground = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 8
        label.layer?.masksToBounds = true
        addSubview(dot)
        addSubview(label)
        frame = CGRect(x: 0, y: 0, width: 120, height: 36)
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
        dot.layer?.backgroundColor = color.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 12
        dot.frame = CGRect(x: (bounds.width - size) / 2, y: 16, width: size, height: size)
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

struct SelectionCard: View {
    @Environment(TimelineStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let day = store.selectedDay {
                Text(TimelineStore.dayTitle(day.day))
                    .font(.system(size: 20, weight: .regular, design: .serif))
                Text(daySummary(day))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Divider().overlay(Palette.rule.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(day.visits) { visit in
                        legendRow(
                            time: visit.start.formatted(date: .omitted, time: .shortened),
                            title: placeTitle(visit),
                            duration: Self.duration(visit.duration),
                            highlighted: store.hoveredVisitID == visit.id,
                            details: store.details(for: visit.placeKey)
                        )
                        .onHover { hovering in
                            store.hoveredVisitID = hovering ? visit.id : nil
                        }
                        .onTapGesture {
                            store.hoveredVisitID = visit.id
                            store.focus(visit: visit)
                        }
                    }
                }
                .onHover { hovering in
                    if !hovering { store.hoveredVisitID = nil }
                }
            } else if let place = store.selectedPlace {
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
                Divider().overlay(Palette.rule.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(place.recentVisits) { visit in
                        legendRow(
                            time: visit.start.formatted(date: .abbreviated, time: .shortened),
                            title: nil,
                            duration: Self.duration(visit.duration),
                            highlighted: store.hoveredVisitID == visit.id,
                            details: store.details(for: place.id)
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
                .onHover { hovering in
                    if !hovering { store.hoveredVisitID = nil }
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.parchment.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .foregroundStyle(Palette.parchment)
        .onDisappear { store.hoveredVisitID = nil }
    }

    @ViewBuilder
    private func legendRow(time: String, title: String?, duration: String, highlighted: Bool, details: PlaceDetails?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(time)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(highlighted ? Palette.parchment : Palette.muted)
                    .frame(width: title == nil ? 120 : 58, alignment: .leading)
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
            if highlighted, let details {
                PlaceBalloon(title: title ?? details.title, details: details, semantic: nil, compact: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Palette.parchment.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .help(Self.helpText(details: details))
    }

    private static func helpText(details: PlaceDetails?) -> String {
        guard let details else { return "" }
        return [details.category, details.address].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
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

struct PlaceBalloon: View {
    let title: String
    let details: PlaceDetails?
    var semantic: String?
    var compact = false

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 3) {
                if let category = details?.category, !category.isEmpty {
                    Text(category)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(Palette.water)
                }
                if let address = details?.address, !address.isEmpty, address != title {
                    Text(address)
                        .font(.system(size: compact ? 10 : 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let semantic = TimelineParser.semanticTitle(semantic),
                   let business = details?.title, details?.isBusiness == true, business != semantic {
                    Text(business)
                        .font(.system(size: compact ? 10 : 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(compact ? 0 : 8)
            .frame(maxWidth: compact ? .infinity : 220, alignment: .leading)
            .background {
                if !compact {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
        }
    }

    private var hasContent: Bool {
        if let category = details?.category, !category.isEmpty { return true }
        if let address = details?.address, !address.isEmpty, address != title { return true }
        if let semantic = TimelineParser.semanticTitle(semantic),
           let business = details?.title, details?.isBusiness == true, business != semantic {
            return true
        }
        return false
    }
}
