import SwiftUI
import MapKit

struct MapCanvasView: View {
    @EnvironmentObject private var store: TimelineStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            map
            if store.parsed == nil && !store.isLoading {
                emptyMap
            }
            if store.selectedDay != nil || store.selectedPlace != nil {
                SelectionCard()
                    .padding(20)
            }
        }
        .background(Palette.ink)
    }

    private var map: some View {
        Map(position: $store.cameraPosition) {
            if let day = store.selectedDay {
                ForEach(Array(day.paths.enumerated()), id: \.element.id) { _, path in
                    MapPolyline(coordinates: path.points)
                        .stroke(Palette.path, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                }
                ForEach(day.activities.filter { activity in
                    activity.startCoordinate != nil && activity.endCoordinate != nil
                }) { activity in
                    if let start = activity.startCoordinate, let end = activity.endCoordinate {
                        MapPolyline(coordinates: [start, end])
                            .stroke(Palette.water.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                    }
                }
                ForEach(day.visits) { visit in
                    if let coordinate = visit.coordinate {
                        let highlighted = store.hoveredVisitID == visit.id
                        Annotation(visitLabel(visit), coordinate: coordinate, anchor: .bottom) {
                            VisitPin(
                                title: visitLabel(visit),
                                semantic: visit.semanticType,
                                large: highlighted,
                                emphasized: highlighted,
                                dimmed: store.hoveredVisitID != nil && !highlighted
                            )
                        }
                    }
                }
                if let hovered = store.hoveredVisit, let coordinate = hovered.coordinate {
                    MapCircle(center: coordinate, radius: highlightRadius(for: hovered))
                        .foregroundStyle(Palette.path.opacity(0.28))
                        .stroke(Palette.parchment.opacity(0.85), lineWidth: 1.5)
                }
            } else if let place = store.selectedPlace, let coordinate = place.coordinate {
                let highlighted = store.hoveredVisitID != nil
                Annotation(store.displayName(for: place), coordinate: coordinate, anchor: .bottom) {
                    VisitPin(
                        title: store.displayName(for: place),
                        semantic: place.semanticType,
                        large: true,
                        emphasized: highlighted
                    )
                }
                if highlighted {
                    MapCircle(center: coordinate, radius: 90)
                        .foregroundStyle(Palette.path.opacity(0.28))
                        .stroke(Palette.parchment.opacity(0.85), lineWidth: 1.5)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea()
    }

    private func visitLabel(_ visit: TimelineVisit) -> String {
        if let semantic = TimelineParser.semanticTitle(visit.semanticType) {
            return semantic
        }
        if let named = store.placeNames[visit.placeKey] {
            return named
        }
        return visit.start.formatted(date: .omitted, time: .shortened)
    }

    private func highlightRadius(for visit: TimelineVisit) -> CLLocationDistance {
        max(60, min(220, (visit.duration / 60) * 1.5 + 50))
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

struct VisitPin: View {
    let title: String
    let semantic: String?
    var large = false
    var emphasized = false
    var dimmed = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if emphasized {
                    Circle()
                        .fill(color.opacity(0.35))
                        .frame(width: 28, height: 28)
                }
                Circle()
                    .fill(color)
                    .frame(width: pinSize, height: pinSize)
                    .shadow(color: .black.opacity(emphasized ? 0.5 : 0.35), radius: emphasized ? 6 : 3, y: 1)
                Circle()
                    .stroke(Palette.parchment.opacity(emphasized ? 1 : 0.9), lineWidth: emphasized ? 2.5 : 1.5)
                    .frame(width: pinSize, height: pinSize)
            }
            if !dimmed {
                Text(title)
                    .font(.system(size: emphasized ? 11 : 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .lineLimit(1)
            }
        }
        .opacity(dimmed ? 0.35 : 1)
        .scaleEffect(emphasized ? 1.15 : 1)
        .animation(.easeOut(duration: 0.15), value: emphasized)
        .animation(.easeOut(duration: 0.15), value: dimmed)
        .zIndex(emphasized ? 10 : 0)
    }

    private var pinSize: CGFloat {
        if emphasized { return 18 }
        return large ? 16 : 12
    }

    private var color: Color {
        switch semantic {
        case "Home": return Palette.copper
        case "Work": return Palette.water
        default: return Palette.path
        }
    }
}

struct SelectionCard: View {
    @EnvironmentObject private var store: TimelineStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let day = store.selectedDay {
                Text(TimelineStore.dayTitle(day.day))
                    .font(.system(size: 20, weight: .regular, design: .serif))
                Text(daySummary(day))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Divider().overlay(Palette.rule.opacity(0.5))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(day.visits) { visit in
                            legendRow(
                                time: visit.start.formatted(date: .omitted, time: .shortened),
                                title: placeTitle(visit),
                                duration: Self.duration(visit.duration),
                                highlighted: store.hoveredVisitID == visit.id
                            )
                            .onHover { hovering in
                                store.hoveredVisitID = hovering ? visit.id : nil
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(place.visits.prefix(20)) { visit in
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
                                if let day = store.parsed?.days.first(where: { Calendar.current.isDate($0.day, inSameDayAs: visit.start) }) {
                                    store.select(day: day)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
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
    private func legendRow(time: String, title: String?, duration: String, highlighted: Bool) -> some View {
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
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Palette.parchment.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: highlighted)
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
        if let semantic = TimelineParser.semanticTitle(visit.semanticType) { return semantic }
        if let named = store.placeNames[visit.placeKey] { return named }
        return "Stay"
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
