import SwiftUI
import CoreLocation
import MapKit

/// Put a place where it really is.
///
/// Google ships one coordinate per Place ID and it is sometimes the wrong end of
/// the block; a recorded stay sits wherever the fix happened to land. Both are
/// assumptions the data made, and until now neither could be argued with.
struct SetPlaceLocationView: View {
    let place: PlaceRecord
    let store: TimelineStore
    var onDone: () -> Void

    @State private var suggester = PlaceNameSuggester()
    @State private var query = ""
    @State private var isResolving = false
    @State private var failedToResolve = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search for the real place", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .accessibilityIdentifier("set-location-search")
                        .onChange(of: query) { _, value in
                            suggester.updateQuery(value)
                        }
                } header: {
                    Text("Where is \(store.displayName(for: place))?")
                } footer: {
                    Text(footer)
                }

                if isResolving {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking it up…").foregroundStyle(Palette.muted)
                        }
                    }
                }

                if !suggester.suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggester.suggestions) { suggestion in
                            Button {
                                choose(suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title).foregroundStyle(Palette.parchment)
                                    if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                                        Text(subtitle).font(.caption).foregroundStyle(Palette.muted)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("set-location-suggestion")
                        }
                    }
                }

                if store.hasCorrectedLocation(place.id) {
                    Section {
                        Button("Put it back where the data said", role: .destructive) {
                            store.clearPlaceLocation(place.id)
                            onDone()
                        }
                        .accessibilityIdentifier("set-location-reset")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Set Location")
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

    private var footer: String {
        if failedToResolve {
            return "Could not find where that is. Try another result."
        }
        return "Every stay at this place moves with it. Nothing else changes."
    }

    private func configureSearch() {
        let centre = place.coordinate ?? CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12)
        suggester.configure(
            around: centre,
            excludingPlaceID: place.id,
            visitedPlaces: store.visitedPlaceNameCandidates(excluding: place.id)
        )
        query = store.displayName(for: place)
        suggester.updateQuery(query)
        searchFocused = true
    }

    private func choose(_ suggestion: PlaceNameSuggestion) {
        isResolving = true
        failedToResolve = false
        Task {
            // A typed result is a name and a subtitle; it has to be searched for
            // before it is a position.
            guard let coordinate = await suggester.coordinate(for: suggestion) else {
                isResolving = false
                failedToResolve = true
                return
            }
            store.setPlaceLocation(place.id, to: coordinate)
            isResolving = false
            onDone()
        }
    }
}

extension View {
    func setPlaceLocationSheet(placeID: Binding<String?>, store: TimelineStore) -> some View {
        sheet(isPresented: Binding(
            get: { placeID.wrappedValue != nil },
            set: { if !$0 { placeID.wrappedValue = nil } }
        )) {
            if let id = placeID.wrappedValue, let place = store.place(for: id) {
                SetPlaceLocationView(place: place, store: store) { placeID.wrappedValue = nil }
                    #if os(macOS)
                    .frame(width: 460, height: 520)
                    #endif
            }
        }
    }
}
