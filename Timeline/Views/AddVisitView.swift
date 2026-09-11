import SwiftUI
import CoreLocation
import MapKit

/// Add a stay the recorder could not have seen.
///
/// A two-minute school drop-off never becomes a `CLVisit`, but the drive around
/// it was recorded — so picking the place is usually enough, and the times can be
/// read back out of the movement. The search is the same one the rename sheet
/// uses, so the suggestions agree with what renaming would have offered.
struct AddVisitView: View {
    let day: Date
    let store: TimelineStore
    var onDone: () -> Void

    @State private var suggester = PlaceNameSuggester()
    @State private var query = ""
    @State private var chosen: PlaceNameSuggestion?
    @State private var start = Date()
    @State private var end = Date()
    @State private var basis: VisitTimingGuesser.Guess.Basis?
    @State private var isGuessing = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search for a place", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .accessibilityIdentifier("add-visit-search")
                        .onChange(of: query) { _, value in
                            suggester.updateQuery(value)
                        }
                } header: {
                    Text("Place")
                } footer: {
                    Text(chosen == nil ? "Pick where you stopped." : "")
                }

                if let chosen {
                    Section("Chosen") {
                        LabeledContent(chosen.title) {
                            Button("Change") {
                                self.chosen = nil
                                searchFocused = true
                            }
                        }
                    }

                    Section {
                        DatePicker("Arrived", selection: $start, displayedComponents: [.hourAndMinute])
                            .accessibilityIdentifier("add-visit-start")
                        DatePicker("Left", selection: $end, in: start..., displayedComponents: [.hourAndMinute])
                            .accessibilityIdentifier("add-visit-end")
                    } header: {
                        Text("When")
                    } footer: {
                        Text(timingExplanation)
                    }
                } else {
                    suggestionList
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a Stay")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(chosen == nil)
                        .accessibilityIdentifier("add-visit-save")
                }
            }
            .onAppear(perform: configureSearch)
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
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
                    .accessibilityIdentifier("add-visit-suggestion")
                }
            }
        }
    }

    private var timingExplanation: String {
        if isGuessing { return "Reading the day's movement…" }
        switch basis {
        case .stopped:
            return "Taken from where the day's movement slows to a stop near here."
        case .droveBy:
            return "The day's movement passes here without stopping, so this is a short stay around that moment. Adjust it if you were longer."
        case .unknown, nil:
            return "Nothing recorded nearby, so this is a guess in the day's biggest gap. Set the times yourself."
        }
    }

    private func configureSearch() {
        let centre = store.day(for: day)?.region.center
            ?? store.parsed?.places.compactMap(\.coordinate).first
            ?? CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12)
        suggester.configure(
            around: centre,
            excludingPlaceID: "",
            visitedPlaces: store.visitedPlaceNameCandidates(excluding: "")
        )
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        start = noon
        end = noon.addingTimeInterval(VisitTimingGuesser.blindDuration)
        searchFocused = true
    }

    private func choose(_ suggestion: PlaceNameSuggestion) {
        chosen = suggestion
        query = suggestion.title
        guard let coordinate = coordinate(of: suggestion) else { return }
        isGuessing = true
        Task {
            let guess = await store.suggestedTiming(for: coordinate, on: day)
            start = guess.start
            end = guess.end
            basis = guess.basis
            isGuessing = false
        }
    }

    /// Visited suggestions carry a place we already know; map results carry the
    /// coordinate in their id, which is where the search put it.
    private func coordinate(of suggestion: PlaceNameSuggestion) -> CLLocationCoordinate2D? {
        if let id = suggestion.targetPlaceID, let place = store.place(for: id), let coordinate = place.coordinate {
            return coordinate
        }
        let parts = suggestion.id.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        let pair = parts[1].split(separator: ",")
        guard pair.count == 2, let latitude = Double(pair[0]), let longitude = Double(pair[1]) else {
            return nil
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private func save() {
        guard let chosen else { return }
        let coordinate = self.coordinate(of: chosen)
            ?? store.day(for: day)?.region.center
            ?? CLLocationCoordinate2D(latitude: 49.25, longitude: -123.12)
        store.addVisit(
            name: chosen.title,
            coordinate: coordinate,
            start: start,
            end: end,
            mergingInto: chosen.targetPlaceID
        )
        onDone()
    }
}

extension View {
    /// Kept as a modifier rather than an inline sheet: SelectionCard's body is
    /// already at the edge of what the type checker will do in one piece.
    func addVisitSheet(day: Binding<Date?>, store: TimelineStore) -> some View {
        sheet(isPresented: Binding(
            get: { day.wrappedValue != nil },
            set: { if !$0 { day.wrappedValue = nil } }
        )) {
            if let value = day.wrappedValue {
                AddVisitView(day: value, store: store) { day.wrappedValue = nil }
                    #if os(macOS)
                    .frame(width: 460, height: 520)
                    #endif
            }
        }
    }
}
