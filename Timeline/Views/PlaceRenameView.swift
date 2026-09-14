import SwiftUI
import MapKit

struct PlaceRenameView: View {
    let place: PlaceRecord
    let initialName: String
    let visitedPlaces: [(id: String, title: String, visitCount: Int, coordinate: CLLocationCoordinate2D)]
    var onSave: (String) -> Void
    var onMerge: (String) -> Void
    var onCancel: () -> Void

    @State private var draft: String
    @State private var suggester = PlaceNameSuggester()
    @State private var list: SuggestionList = .history
    @State private var highlightedIndex: Int?
    @State private var pendingMerge: PlaceNameSuggestion?
    @FocusState private var nameFocused: Bool

    private enum SuggestionList: String, CaseIterable, Identifiable {
        case history
        case nearby

        var id: String { rawValue }

        var title: String {
            switch self {
            case .history: "History"
            case .nearby: "Nearby"
            }
        }
    }

    init(
        place: PlaceRecord,
        initialName: String,
        visitedPlaces: [(id: String, title: String, visitCount: Int, coordinate: CLLocationCoordinate2D)],
        onSave: @escaping (String) -> Void,
        onMerge: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.place = place
        self.initialName = initialName
        self.visitedPlaces = visitedPlaces
        self.onSave = onSave
        self.onMerge = onMerge
        self.onCancel = onCancel
        let seed = initialName == "Unnamed place" ? "" : initialName
        _draft = State(initialValue: seed)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Place name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .regular, design: .serif))
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(commitFromKeyboard)
                        .accessibilityIdentifier("place-rename-field")
                        .onKeyPress(.escape) {
                            dismissFromEscape()
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            moveHighlight(by: 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveHighlight(by: -1)
                            return .handled
                        }
                        .padding(12)
                        .background(Palette.inkLift, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(footerText)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                suggestionTabs
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 6)

                Text(listCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                ScrollViewReader { proxy in
                    List {
                        suggestionRows
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #endif
                    .frame(maxHeight: .infinity)
                    .onChange(of: highlightedIndex) { _, index in
                        guard let index, visibleSuggestions.indices.contains(index) else { return }
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(visibleSuggestions[index].id, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("Rename Place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .confirmationDialog(
                "Merge into \(pendingMerge?.title ?? "")?",
                isPresented: Binding(
                    get: { pendingMerge != nil },
                    set: { if !$0 { pendingMerge = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Merge", role: .destructive) {
                    if let target = pendingMerge?.targetPlaceID { onMerge(target) }
                    pendingMerge = nil
                }
                Button("Cancel", role: .cancel) { pendingMerge = nil }
            } message: {
                Text(mergeWarning)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                }
            }
            .onKeyPress(.downArrow) {
                moveHighlight(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveHighlight(by: -1)
                return .handled
            }
            .onKeyPress(.return) {
                if applyHighlightedSuggestion() {
                    return .handled
                }
                return .ignored
            }
        }
        .foregroundStyle(Palette.parchment)
        .dismissesOnEscape(isEnabled: pendingMerge == nil, onCancel)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 520, idealHeight: 560)
        #endif
        .onAppear {
            if let coordinate = place.coordinate
                ?? place.recentVisits.compactMap(\.coordinate).first
            {
                suggester.configure(
                    around: coordinate,
                    excludingPlaceID: place.id,
                    visitedPlaces: visitedPlaces
                )
            }
            suggester.updateQuery(draft)
            nameFocused = true
        }
        .onChange(of: draft) { _, newValue in
            suggester.updateQuery(newValue)
        }
        .onChange(of: list) { _, _ in
            highlightedIndex = nil
        }
        .onChange(of: visibleSuggestions) { _, newValue in
            if let highlightedIndex, newValue.indices.contains(highlightedIndex) {
                return
            }
            self.highlightedIndex = nil
        }
    }

    private var visibleSuggestions: [PlaceNameSuggestion] {
        switch list {
        case .history: suggester.historySuggestions
        case .nearby: suggester.nearbySuggestions
        }
    }

    private var listCaption: String {
        switch list {
        case .history:
            "Places you've been near here. Choosing one merges into it."
        case .nearby:
            "Places close by that you haven't been. Choosing one names this place."
        }
    }

    private var suggestionTabs: some View {
        HStack(spacing: 0) {
            tabButton(.history, count: suggester.historySuggestions.count)
            tabButton(.nearby, count: suggester.nearbySuggestions.count)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestion lists")
    }

    private func tabButton(_ tab: SuggestionList, count: Int) -> some View {
        let selected = list == tab
        return Button {
            list = tab
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(selected ? Palette.ink : Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(selected ? Palette.parchment : Palette.parchment.opacity(0.12))
                            )
                    } else if tab == .nearby && suggester.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .foregroundStyle(selected ? Palette.parchment : Palette.muted)
                Rectangle()
                    .fill(selected ? Palette.copper : Palette.rule.opacity(0.45))
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab == .history ? "History, places you've been" : "Nearby, places you haven't been")
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(tab == .history ? "place-rename-tab-history" : "place-rename-tab-nearby")
    }

    @ViewBuilder
    private var suggestionRows: some View {
        if visibleSuggestions.isEmpty {
            if list == .nearby && suggester.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking up nearby places…")
                        .foregroundStyle(Palette.muted)
                }
            } else {
                Text(emptyListText)
                    .foregroundStyle(Palette.muted)
            }
        } else {
            ForEach(Array(visibleSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    applySuggestion(suggestion)
                } label: {
                    suggestionRow(suggestion, highlighted: highlightedIndex == index)
                }
                .buttonStyle(.plain)
                .listRowBackground(rowBackground(highlighted: highlightedIndex == index))
                .accessibilityLabel(suggestion.accessibilityLabel)
                .accessibilityAddTraits(highlightedIndex == index ? .isSelected : [])
                .id(suggestion.id)
            }
        }
    }

    private var emptyListText: String {
        let typed = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch list {
        case .history:
            if !suggester.nearbySuggestions.isEmpty {
                return "Nothing in your history matches. Nearby has places you haven't been to."
            }
            return typed ? "Nothing in your history matches." : "No places you've been nearby."
        case .nearby:
            return typed ? "No nearby matches." : "Nothing nearby you haven't already been to."
        }
    }

    /// Escape closes a merge confirmation first. The next one closes the sheet.
    private func dismissFromEscape() {
        if pendingMerge != nil {
            pendingMerge = nil
            return
        }
        onCancel()
    }

    private var footerText: String {
        #if os(macOS)
        "History first, then nearby places you haven't been. Use ↑↓ then Return to choose. Clear the name to restore the default label."
        #else
        "History first, then nearby places you haven't been. Clear the name to restore the default label."
        #endif
    }

    private func suggestionRow(_ suggestion: PlaceNameSuggestion, highlighted: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName(for: suggestion.source))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor(for: suggestion.source))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.parchment)
                    .multilineTextAlignment(.leading)
                if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            if suggestion.source == .visited {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.copper.opacity(0.85))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .opacity(highlighted ? 1 : 0.96)
    }

    private func rowBackground(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(highlighted ? Palette.parchment.opacity(0.16) : Color.clear)
    }

    private func iconName(for source: PlaceNameSuggestion.Source) -> String {
        switch source {
        case .visited: return "mappin.and.ellipse"
        case .map: return "building.2"
        case .address: return "signpost.right"
        }
    }

    private func iconColor(for source: PlaceNameSuggestion.Source) -> Color {
        switch source {
        case .visited: return Palette.copper
        case .map: return Palette.water
        case .address: return Palette.muted
        }
    }

    private func moveHighlight(by delta: Int) {
        let items = visibleSuggestions
        guard !items.isEmpty else {
            highlightedIndex = nil
            return
        }
        if let current = highlightedIndex {
            highlightedIndex = min(max(current + delta, 0), items.count - 1)
        } else {
            highlightedIndex = delta > 0 ? 0 : items.count - 1
        }
    }

    @discardableResult
    private func applyHighlightedSuggestion() -> Bool {
        guard let highlightedIndex,
              visibleSuggestions.indices.contains(highlightedIndex)
        else { return false }
        applySuggestion(visibleSuggestions[highlightedIndex])
        return true
    }

    private func commitFromKeyboard() {
        if applyHighlightedSuggestion() { return }
        save()
    }

    private func applySuggestion(_ suggestion: PlaceNameSuggestion) {
        if let targetPlaceID = suggestion.targetPlaceID {
            // Picking a place you have been to is a merge, and a merge discards
            // the other place. Ask first when the one being discarded is the one
            // holding the history.
            if PlaceGuessRanker.foldsAwayTheLargerHistory(
                source: place.visitCount,
                target: suggestion.visitCount
            ) {
                pendingMerge = suggestion
                return
            }
            onMerge(targetPlaceID)
            return
        }
        draft = suggestion.title
        onSave(suggestion.title)
    }

    private var mergeWarning: String {
        guard let pendingMerge else { return "" }
        let mine = place.visitCount
        let theirs = pendingMerge.visitCount
        return """
        \(initialName) has \(mine) \(mine == 1 ? "stay" : "stays") and \(pendingMerge.title) has \(theirs). \
        Merging moves all of them to \(pendingMerge.title) and drops the name \(initialName).
        """
    }

    private func save() {
        onSave(draft)
    }
}

extension View {
    /// Full rename UI with nearby / autocomplete suggestions (sheet on both platforms).
    func placeRenameSheet(
        placeID: Binding<String?>,
        store: TimelineStore
    ) -> some View {
        sheet(isPresented: Binding(
            get: { placeID.wrappedValue != nil },
            set: { if !$0 { placeID.wrappedValue = nil } }
        )) {
            if let id = placeID.wrappedValue, let place = store.place(for: id) {
                PlaceRenameView(
                    place: place,
                    initialName: store.displayName(for: place),
                    visitedPlaces: store.visitedPlaceNameCandidates(excluding: id)
                ) { name in
                    store.renamePlace(id: id, to: name)
                    placeID.wrappedValue = nil
                } onMerge: { targetID in
                    store.mergePlace(from: id, into: targetID)
                    placeID.wrappedValue = nil
                } onCancel: {
                    placeID.wrappedValue = nil
                }
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
            }
        }
    }
}
