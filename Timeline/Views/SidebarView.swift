import SwiftUI

struct SidebarView: View {
    @Environment(TimelineStore.self) private var store
    @Binding var importerPresented: Bool
    @State private var renamingPlaceID: String?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            tabPicker
            if store.tab == .dates {
                dateFilters
            }
            Divider().opacity(0.35)
            Group {
                if store.isLoading {
                    loading
                } else if store.parsed == nil {
                    emptyLibrary
                } else {
                    ZStack {
                        datesList
                            .opacity(store.tab == .dates ? 1 : 0)
                            .allowsHitTesting(store.tab == .dates)
                            .accessibilityHidden(store.tab != .dates)
                            .zIndex(store.tab == .dates ? 1 : 0)

                        placesList
                            .opacity(store.tab == .places ? 1 : 0)
                            .allowsHitTesting(store.tab == .places)
                            .accessibilityHidden(store.tab != .places)
                            .zIndex(store.tab == .places ? 1 : 0)
                    }
                }
            }
        }
        .foregroundStyle(Palette.parchment)
        .placeRenameSheet(placeID: $renamingPlaceID, store: store)
    }

    private var tabPicker: some View {
        Picker("Section", selection: Binding(
            get: { store.tab },
            set: { store.selectTab($0) }
        )) {
            ForEach(SidebarTab.allCases) { tab in
                Text(tab.rawValue)
                    .tag(tab)
                    .accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
    }

    private var dateFilters: some View {
        HStack(spacing: 8) {
            filterMenu("Year", selection: Bindable(store).filterYear) {
                Text("All years").tag(0)
                ForEach(store.availableYears, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            filterMenu("Month", selection: Bindable(store).filterMonth) {
                Text("All months").tag(0)
                ForEach(store.availableMonths, id: \.self) { month in
                    Text(Self.monthName(month)).tag(month)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .onChange(of: store.filterYear) { _, _ in
            store.clampDateFilters()
        }
        .onChange(of: store.filterMonth) { _, _ in
            store.clampDateFilters()
        }
    }

    private func filterMenu<Content: View>(
        _ title: String,
        selection: Binding<Int>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(iOS)
        Menu {
            Picker(title, selection: selection) {
                content()
            }
        } label: {
            HStack(spacing: 6) {
                Text(filterCaption(title, selection.wrappedValue))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.parchment)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        #else
        Picker(title, selection: selection) {
            content()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Palette.parchment)
        .frame(maxWidth: .infinity)
        #endif
    }

    private func filterCaption(_ title: String, _ value: Int) -> String {
        if title == "Year" {
            return value == 0 ? "All years" : String(value)
        }
        return value == 0 ? "All months" : Self.monthName(value)
    }

    private static let monthNames = DateFormatter().monthSymbols ?? []

    private static func monthName(_ month: Int) -> String {
        guard month >= 1, month <= monthNames.count else { return "\(month)" }
        return monthNames[month - 1]
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
            .timelineGlassButton(prominent: true)
            .tint(Palette.water)
            .accessibilityIdentifier("open-timeline-empty")
            #if os(macOS)
            Button("Open Downloads/Timeline.json") {
                store.tryOpenDownloadsExample()
            }
            .timelineGlassButton()
            .foregroundStyle(Palette.parchment.opacity(0.85))
            #endif
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
        ScrollViewReader { proxy in
            List(selection: Bindable(store).selectedDayID) {
                let scale = store.distanceScaleMeters
                ForEach(store.monthGroups, id: \.month) { group in
                    Section {
                        ForEach(group.days) { day in
                            dayRow(day, scale: scale)
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
            .onChange(of: store.selectedDayID) { _, _ in
                store.handleDaySelectionChange()
            }
            .onChange(of: store.filterYear) { _, _ in
                scrollDatesToSelection(proxy)
            }
            .onChange(of: store.filterMonth) { _, _ in
                scrollDatesToSelection(proxy)
            }
        }
    }

    private func scrollDatesToSelection(_ proxy: ScrollViewProxy) {
        guard let id = store.selectedDayID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func dayRow(_ day: DayRecord, scale: Double) -> some View {
        DayRow(day: day, scaleMeters: scale)
            .tag(day.day)
            .id(day.day)
            .accessibilityIdentifier("day-row")
            .accessibilityValue(Self.dayRowID(day.day))
            .listRowBackground(rowBackground(isSelected: store.selectedDayID == day.day))
            .contentShape(Rectangle())
            .onTapGesture {
                store.select(day: day)
            }
    }

    private var placesList: some View {
        List(selection: Bindable(store).selectedPlaceID) {
            ForEach(store.filteredPlaces) { place in
                PlaceRow(
                    place: place,
                    title: store.displayName(for: place),
                    subtitle: store.subtitle(for: place),
                    showsActions: store.canRename(place),
                    onRename: {
                        renamingPlaceID = place.id
                    }
                )
                    .tag(place.id)
                    .id(place.id)
                    .listRowBackground(rowBackground(isSelected: store.selectedPlaceID == place.id))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.select(place: place)
                    }
                    .accessibilityIdentifier("place-\(place.id)")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: Bindable(store).search, prompt: "Find a place")
        .onChange(of: store.selectedPlaceID) { _, _ in
            store.handlePlaceSelectionChange()
        }
    }

    private static func dayRowID(_ day: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "day-%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Palette.parchment.opacity(0.14) : Color.clear)
            .padding(.vertical, 1)
    }
}

struct DayRow: View, Equatable {
    let day: DayRecord
    let scaleMeters: Double

    static func == (lhs: DayRow, rhs: DayRow) -> Bool {
        lhs.day.day == rhs.day.day
            && lhs.day.travelMeters == rhs.day.travelMeters
            && lhs.day.visitCount == rhs.day.visitCount
            && lhs.scaleMeters == rhs.scaleMeters
    }

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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("day-row")
        .accessibilityAddTraits(.isButton)
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
    var showsActions = false
    var onRename: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let symbol = TimelineParser.symbolName(place.semanticType) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pinColor)
                    .frame(width: 12)
            } else {
                Circle()
                    .fill(pinColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 12)
            }
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
            Spacer(minLength: 4)
            if showsActions {
                PlaceActionsMenu(placeID: place.id, onRename: { onRename?() })
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: showsActions ? .contain : .combine)
        .accessibilityIdentifier("place-\(place.id)")
        .accessibilityAddTraits(.isButton)
    }

    private var pinColor: Color {
        switch place.semanticType {
        case "Home": return Palette.copper
        case "Work": return Palette.water
        default: return Palette.parchment.opacity(0.55)
        }
    }
}

/// Overflow menu for place rename / future merge, shared by the Places list and map legend.
struct PlaceActionsMenu: View {
    let placeID: String
    var onRename: () -> Void

    var body: some View {
        Menu {
            Button("Rename…", action: onRename)
            Button("Merge Places…") {}
                .disabled(true)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Palette.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .buttonStyle(.plain)
        .accessibilityLabel("Place actions")
        .accessibilityIdentifier("place-actions-\(placeID)")
    }
}
