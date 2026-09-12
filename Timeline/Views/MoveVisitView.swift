import SwiftUI
import CoreLocation

/// Re-attach one stay to a different place.
///
/// Not a rename and not a merge. Renaming relabels every other stay at that
/// place; merging folds the two places together for good. This is for the stay
/// that simply landed on the wrong neighbour, which is what coarse fixes do.
struct MoveVisitView: View {
    let visit: TimelineVisit
    let store: TimelineStore
    var onDone: () -> Void

    @State private var suggester = PlaceNameSuggester()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search for a place", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .accessibilityIdentifier("move-visit-search")
                        .onChange(of: query) { _, value in
                            suggester.updateQuery(value)
                        }
                } header: {
                    Text("Move this stay to")
                } footer: {
                    Text("Only this stay moves. Everything else at \(currentName) stays where it is.")
                }

                if suggester.isLoading && suggester.suggestions.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking up nearby places…").foregroundStyle(Palette.muted)
                        }
                    }
                }

                if !suggester.suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggester.suggestions) { suggestion in
                            Button {
                                move(to: suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title).foregroundStyle(Palette.parchment)
                                    if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                                        Text(subtitle).font(.caption).foregroundStyle(Palette.muted)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("move-visit-suggestion")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Move Stay")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
            }
            .onAppear(perform: configureSearch)
        }
    }

    private var currentName: String {
        guard let place = store.place(for: visit.placeKey) else { return "this place" }
        return store.displayName(for: place)
    }

    private func configureSearch() {
        let centre = visit.coordinate
            ?? store.place(for: visit.placeKey)?.coordinate
            ?? CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12)
        suggester.configure(
            around: centre,
            // The place it is wrongly attached to is not a useful suggestion.
            excludingPlaceID: visit.placeKey,
            visitedPlaces: store.visitedPlaceNameCandidates(excluding: visit.placeKey)
        )
        searchFocused = true
    }

    private func move(to suggestion: PlaceNameSuggestion) {
        Task {
            // Moving onto a place we already hold needs no lookup; a typed result
            // does, since the completer gives a name without a position.
            let resolved = suggestion.targetPlaceID == nil
                ? await suggester.coordinate(for: suggestion)
                : store.place(for: suggestion.targetPlaceID!)?.coordinate
            guard let coordinate = resolved ?? visit.coordinate else { return }
            store.moveVisit(
                visit.id,
                toPlaceNamed: suggestion.title,
                coordinate: coordinate,
                existingPlaceID: suggestion.targetPlaceID
            )
            onDone()
        }
    }
}

extension View {
    /// A modifier rather than an inline sheet, to keep SelectionCard's body inside
    /// what the type checker will take in one piece.
    func moveVisitSheet(visit: Binding<TimelineVisit?>, store: TimelineStore) -> some View {
        sheet(isPresented: Binding(
            get: { visit.wrappedValue != nil },
            set: { if !$0 { visit.wrappedValue = nil } }
        )) {
            if let value = visit.wrappedValue {
                MoveVisitView(visit: value, store: store) { visit.wrappedValue = nil }
                    #if os(macOS)
                    .frame(width: 460, height: 520)
                    #endif
            }
        }
    }
}
