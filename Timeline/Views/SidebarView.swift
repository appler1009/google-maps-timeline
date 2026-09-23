import SwiftUI

struct SidebarView: View {
    @Environment(TimelineStore.self) private var store
    @Binding var importerPresented: Bool
    @State private var renamingPlaceID: String?
    /// The place whose "Set location…" was chosen.
    @State private var relocatingPlaceID: String?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            sidebarChrome
            Divider().opacity(0.35)
            Group {
                if store.isLoading || !store.hasCheckedLibrary {
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
        .setPlaceLocationSheet(placeID: $relocatingPlaceID, store: store)
    }

    /// Dates / Places and the year–month filters as one sidebar header strip.
    /// Symbols need the platform segmented control; SwiftUI's picker drops them.
    private var sidebarChrome: some View {
        VStack(spacing: 10) {
            tabPicker
            if store.tab == .dates {
                dateFilters
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var tabPicker: some View {
        // SwiftUI's segmented Picker only forwards titles to the system control,
        // so symbols never appear. Platform segmented controls set both.
        SidebarTabSegmentedControl(
            selection: Binding(
                get: { store.tab },
                set: { store.selectTab($0) }
            )
        )
        .frame(maxWidth: .infinity)
        .frame(height: tabControlHeight)
        .accessibilityLabel("Dates or Places")
    }

    private var dateFilters: some View {
        // Explicit halves — bordered menus on macOS ignore maxWidth and stay
        // title-sized, so GeometryReader is what lines them up with Dates/Places.
        GeometryReader { geo in
            let half = max(0, (geo.size.width - 8) / 2)
            HStack(spacing: 8) {
                filterMenu("Year", selection: Bindable(store).filterYear) {
                    Text("All years").tag(0)
                    ForEach(store.availableYears, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .frame(width: half, height: filterRowHeight)

                filterMenu("Month", selection: Bindable(store).filterMonth) {
                    Text("All months").tag(0)
                    ForEach(store.availableMonths, id: \.self) { month in
                        Text(Self.monthName(month)).tag(month)
                    }
                }
                .frame(width: half, height: filterRowHeight)
            }
        }
        .frame(height: filterRowHeight)
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
        Menu {
            Picker(title, selection: selection) {
                content()
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text(filterCaption(title, selection.wrappedValue))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: filterLabelSize, weight: .medium))
            .foregroundStyle(Palette.parchment)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: filterCornerRadius, style: .continuous)
                .fill(filterFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: filterCornerRadius, style: .continuous)
                .strokeBorder(Palette.parchment.opacity(0.14), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabControlHeight: CGFloat {
        #if os(iOS)
        32
        #else
        28
        #endif
    }

    private var filterRowHeight: CGFloat {
        #if os(iOS)
        36
        #else
        28
        #endif
    }

    private var filterLabelSize: CGFloat {
        #if os(iOS)
        15
        #else
        13
        #endif
    }

    private var filterCornerRadius: CGFloat {
        #if os(iOS)
        8
        #else
        6
        #endif
    }

    private var filterFill: Color {
        #if os(iOS)
        Palette.parchment.opacity(0.10)
        #else
        Palette.parchment.opacity(0.08)
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
            Text(store.isLoading ? "Reading export" : "Opening your library")
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
            .id(store.dateListIdentity)
            .onChange(of: store.selectedDayID) { _, _ in
                store.handleDaySelectionChange()
            }
            .onChange(of: store.dateListIdentity) { _, _ in
                scrollDatesToSelection(proxy)
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
                    showsActions: store.showsPlaceActions(place),
                    onRename: {
                        renamingPlaceID = place.id
                    },
                    onSetLocation: {
                        relocatingPlaceID = place.id
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
    var onSetLocation: (() -> Void)?

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
                PlaceActionsMenu(
                    placeID: place.id,
                    onRename: { onRename?() },
                    onSetLocation: { onSetLocation?() }
                )
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

/// Overflow menu for place rename / unmerge, shared by the Places list and map legend.
struct PlaceActionsMenu: View {
    @Environment(TimelineStore.self) private var store
    let placeID: String
    var onRename: () -> Void
    var onSetLocation: (() -> Void)?

    private var mergedSources: [(id: String, title: String)] {
        store.sourcesMerged(into: placeID)
    }

    var body: some View {
        Menu {
            if let place = store.place(for: placeID), store.canRename(place) {
                Button("Rename…", action: onRename)
            }
            if let onSetLocation {
                Button(
                    store.hasCorrectedLocation(placeID) ? "Change location…" : "Set location…",
                    action: onSetLocation
                )
            }
            if !mergedSources.isEmpty {
                Menu("Unmerge") {
                    ForEach(mergedSources, id: \.id) { source in
                        Button(source.title) {
                            store.unmergePlace(from: source.id)
                        }
                    }
                }
            }
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

#if os(macOS)
import AppKit

/// System segmented control with a symbol and title on each segment.
///
/// SwiftUI's `.pickerStyle(.segmented)` only forwards the title string to
/// `NSSegmentedControl`, which is why calendar / map-pin never appeared.
struct SidebarTabSegmentedControl: NSViewRepresentable {
    @Binding var selection: SidebarTab

    func makeNSView(context: Context) -> NSSegmentedControl {
        let tabs = SidebarTab.allCases
        let control = NSSegmentedControl(
            labels: tabs.map(\.rawValue),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.segmentStyle = .rounded
        control.segmentDistribution = .fill
        control.controlSize = .large
        let symbol = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        for (index, tab) in tabs.enumerated() {
            if let image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.rawValue)?
                .withSymbolConfiguration(symbol)
            {
                control.setImage(image, forSegment: index)
            }
            control.setLabel(tab.rawValue, forSegment: index)
            control.setToolTip(tab.rawValue, forSegment: index)
        }
        control.selectedSegment = tabs.firstIndex(of: selection) ?? 0
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = SidebarTab.allCases.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<SidebarTab>

        init(selection: Binding<SidebarTab>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            let tabs = SidebarTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = tabs[sender.selectedSegment]
        }
    }
}
#elseif os(iOS)
import UIKit

/// System segmented control with a symbol and title on each segment.
///
/// UIKit's `UISegmentedControl` accepts either a title or an image per segment,
/// not both — so each segment is a single template image of the symbol and
/// label drawn together. SwiftUI's segmented `Picker` drops symbols the same
/// way the Mac one did.
struct SidebarTabSegmentedControl: UIViewRepresentable {
    @Binding var selection: SidebarTab

    func makeUIView(context: Context) -> UISegmentedControl {
        let tabs = SidebarTab.allCases
        let control = UISegmentedControl(items: tabs.map(Self.segmentImage(for:)))
        control.selectedSegmentIndex = tabs.firstIndex(of: selection) ?? 0
        control.apportionsSegmentWidthsByContent = false
        control.selectedSegmentTintColor = UIColor(Palette.parchment.opacity(0.28))
        control.setTitleTextAttributes(
            [.foregroundColor: UIColor(Palette.parchment)],
            for: .normal
        )
        control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.changed(_:)),
            for: .valueChanged
        )
        control.accessibilityLabel = "Dates or Places"
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = SidebarTab.allCases.firstIndex(of: selection) ?? 0
        if control.selectedSegmentIndex != index {
            control.selectedSegmentIndex = index
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    /// Symbol + title as one template image so the segment can tint with the control.
    private static func segmentImage(for tab: SidebarTab) -> UIImage {
        let font = UIFont.systemFont(ofSize: 13, weight: .medium)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let symbol = UIImage(systemName: tab.symbolName, withConfiguration: symbolConfig)
            ?? UIImage()
        let title = tab.rawValue as NSString
        let titleSize = title.size(withAttributes: [.font: font])
        let spacing: CGFloat = 5
        let size = CGSize(
            width: ceil(symbol.size.width + spacing + titleSize.width),
            height: ceil(max(symbol.size.height, titleSize.height))
        )
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            let iconOrigin = CGPoint(x: 0, y: (size.height - symbol.size.height) / 2)
            symbol.draw(at: iconOrigin)
            title.draw(
                at: CGPoint(x: symbol.size.width + spacing, y: (size.height - titleSize.height) / 2),
                withAttributes: [
                    .font: font,
                    .foregroundColor: UIColor.black,
                ]
            )
        }
        let image = rendered.withRenderingMode(.alwaysTemplate)
        // Drawn text is not readable text: without this the segment is a button
        // with no name, to VoiceOver and to the UI tests alike.
        image.accessibilityLabel = tab.rawValue
        return image
    }

    final class Coordinator: NSObject {
        var selection: Binding<SidebarTab>

        init(selection: Binding<SidebarTab>) {
            self.selection = selection
        }

        @objc func changed(_ sender: UISegmentedControl) {
            let tabs = SidebarTab.allCases
            guard tabs.indices.contains(sender.selectedSegmentIndex) else { return }
            selection.wrappedValue = tabs[sender.selectedSegmentIndex]
        }
    }
}
#endif
