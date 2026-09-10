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
    @State private var highlightedIndex: Int?
    @FocusState private var nameFocused: Bool

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
            ScrollViewReader { proxy in
                List {
                    Section {
                        TextField("Place name", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 17, weight: .regular, design: .serif))
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(commitFromKeyboard)
                            .accessibilityIdentifier("place-rename-field")
                            .onKeyPress(.downArrow) {
                                moveHighlight(by: 1)
                                return .handled
                            }
                            .onKeyPress(.upArrow) {
                                moveHighlight(by: -1)
                                return .handled
                            }
                    } footer: {
                        Text(footerText)
                    }

                    if !suggester.suggestions.isEmpty || suggester.isLoading {
                        Section("Suggestions") {
                            if suggester.isLoading && suggester.suggestions.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Looking up nearby places…")
                                        .foregroundStyle(Palette.muted)
                                }
                            }
                            ForEach(Array(suggester.suggestions.enumerated()), id: \.element.id) { index, suggestion in
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
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .onChange(of: highlightedIndex) { _, index in
                    guard let index, suggester.suggestions.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(suggester.suggestions[index].id, anchor: .center)
                    }
                }
            }
            .navigationTitle("Rename Place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
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
        .onChange(of: suggester.suggestions) { _, newValue in
            if let highlightedIndex, newValue.indices.contains(highlightedIndex) {
                return
            }
            self.highlightedIndex = nil
        }
    }

    private var footerText: String {
        #if os(macOS)
        "Suggestions nearby prefer places you visit often. Choosing a starred visit merges into that place. Use ↑↓ then Return to choose. Clear the name to restore the default label."
        #else
        "Suggestions nearby prefer places you visit often. Choosing a starred visit merges into that place. Clear the name to restore the default label."
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
        let items = suggester.suggestions
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
              suggester.suggestions.indices.contains(highlightedIndex)
        else { return false }
        applySuggestion(suggester.suggestions[highlightedIndex])
        return true
    }

    private func commitFromKeyboard() {
        if applyHighlightedSuggestion() { return }
        save()
    }

    private func applySuggestion(_ suggestion: PlaceNameSuggestion) {
        if let targetPlaceID = suggestion.targetPlaceID {
            onMerge(targetPlaceID)
            return
        }
        draft = suggestion.title
        onSave(suggestion.title)
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
