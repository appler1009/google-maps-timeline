import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: TimelineStore
    @Binding var importerPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            searchField
            Divider().overlay(Palette.rule)
            Group {
                if store.isLoading {
                    loading
                } else if store.parsed == nil {
                    emptyLibrary
                } else if store.tab == .dates {
                    datesList
                } else {
                    placesList
                }
            }
        }
        .background(Palette.ink)
        .foregroundStyle(Palette.parchment)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timeline")
                .font(.system(size: 26, weight: .bold, design: .serif))
                .foregroundStyle(Palette.parchment)
            Text(store.sourceName ?? "Open a Timeline.json export")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var tabPicker: some View {
        Picker("Sidebar", selection: $store.tab) {
            ForEach(SidebarTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onChange(of: store.tab) { _, newValue in
            store.search = ""
            if newValue == .dates {
                if store.selectedDay == nil, let day = store.parsed?.days.first {
                    store.select(day: day)
                } else if let day = store.selectedDay {
                    store.focus(day: day)
                }
            } else if store.selectedPlace == nil, let place = store.parsed?.places.first {
                store.select(place: place)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.muted)
            TextField(store.tab == .dates ? "Find a date" : "Find a place", text: $store.search)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.parchment)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.inkLift, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading export")
                .foregroundStyle(Palette.muted)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring in a Google Maps Timeline export to see days and places on the map.")
                .font(.callout)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Timeline.json") {
                importerPresented = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.water)
            Button("Open Downloads/Timeline.json") {
                store.tryOpenDownloadsExample()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.parchment.opacity(0.85))
            if let error = store.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Palette.copper)
            }
            Spacer()
        }
        .padding(16)
    }

    private var datesList: some View {
        List(selection: $store.selectedDayID) {
            ForEach(store.daysByMonth, id: \.month) { group in
                Section {
                    ForEach(group.days) { day in
                        DayRow(day: day, scaleMeters: store.distanceScaleMeters)
                            .tag(day.day)
                            .listRowBackground(rowBackground(isSelected: store.selectedDayID == day.day))
                    }
                } header: {
                    Text(TimelineStore.monthTitle(group.month))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onChange(of: store.selectedDayID) { _, newValue in
            if let day = store.parsed?.days.first(where: { $0.day == newValue }) {
                store.focus(day: day)
                store.selectedPlaceID = nil
            }
        }
    }

    private var placesList: some View {
        List(selection: $store.selectedPlaceID) {
            ForEach(store.filteredPlaces) { place in
                PlaceRow(place: place, title: store.displayName(for: place), subtitle: store.subtitle(for: place))
                    .tag(place.id)
                    .listRowBackground(rowBackground(isSelected: store.selectedPlaceID == place.id))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onChange(of: store.selectedPlaceID) { _, newValue in
            if let place = store.parsed?.places.first(where: { $0.id == newValue }) {
                store.select(place: place)
            }
        }
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Palette.inkLift : Color.clear)
            .padding(.vertical, 1)
    }
}

struct DayRow: View {
    let day: DayRecord
    let scaleMeters: Double

    private let barWidth: CGFloat = 58

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.parchment)
                Text(placeSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                distanceBar
                Text(distanceLabel)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .foregroundStyle(day.travelMeters > 1 ? distanceColor : Palette.muted.opacity(0.7))
                    .monospacedDigit()
            }
            .frame(width: barWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var placeSummary: String {
        "\(day.visitCount) place\(day.visitCount == 1 ? "" : "s")"
    }

    private var fraction: CGFloat {
        guard scaleMeters > 0, day.travelMeters > 1 else { return 0 }
        return min(1, CGFloat(day.travelMeters / scaleMeters))
    }

    private var distanceColor: Color {
        Palette.distance(meters: day.travelMeters)
    }

    private var distanceBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Palette.rule.opacity(0.55))
                .frame(width: barWidth, height: 5)
            Capsule()
                .fill(distanceColor)
                .frame(width: day.travelMeters > 1 ? max(4, barWidth * fraction) : 0, height: 5)
        }
        .frame(width: barWidth, height: 5, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var distanceLabel: String {
        guard day.travelMeters > 1 else { return "—" }
        if day.travelMeters >= 1000 {
            return String(format: "%.1f km", day.travelMeters / 1000)
        }
        return String(format: "%.0f m", day.travelMeters)
    }
}

struct PlaceRow: View {
    let place: PlaceRecord
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(pinColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.parchment)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var pinColor: Color {
        switch place.semanticType {
        case "Home": return Palette.copper
        case "Work": return Palette.water
        default: return Palette.parchment.opacity(0.55)
        }
    }
}
