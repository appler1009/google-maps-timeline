import Foundation
import CoreLocation

/// What an agent can actually do with the library.
///
/// Everything goes through the same methods the app's own buttons call, so a
/// repair made by an agent is logged, syncs to the phone, and — for the ones
/// that move stays around — can be undone. That is the point of doing this in
/// the app rather than against the file: the app is the only writer, so there is
/// nothing to copy, quit, or race.
struct MCPTimelineTools: MCPToolProviding {
    let database: TimelineDatabase
    /// Somewhere for a repair to be re-sent from, since a change to rows whose
    /// records were already acknowledged goes nowhere on its own.
    var onChanged: @Sendable () -> Void = {}

    // MARK: - What is on offer

    func tools() async -> [MCPTool] {
        [
            MCPTool(
                name: "list_days",
                description: "Days in a range, each with how many stays and journeys it holds. Start here to find the day worth looking at.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "from": .object(["type": "string", "description": "yyyy-MM-dd, inclusive"]),
                        "to": .object(["type": "string", "description": "yyyy-MM-dd, inclusive"])
                    ]),
                    "required": .array(["from", "to"])
                ])
            ),
            MCPTool(
                name: "get_day",
                description: "One day in full: every stay with its id and place, every journey with its kind and distance. Stay ids from here are what move_stay takes.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "date": .object(["type": "string", "description": "yyyy-MM-dd"])
                    ]),
                    "required": .array(["date"])
                ])
            ),
            MCPTool(
                name: "search_places",
                description: "Places by name, with how many stays each holds and whether it was folded into another. Place ids from here are what the repair tools take.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "query": .object(["type": "string", "description": "part of a name; omit to list the most visited"]),
                        "near": .object([
                            "type": "object",
                            "description": "optional: only places within radius_m of this point",
                            "properties": .object([
                                "latitude": .object(["type": "number"]),
                                "longitude": .object(["type": "number"]),
                                "radius_m": .object(["type": "number"])
                            ])
                        ]),
                        "limit": .object(["type": "number", "description": "default 25"])
                    ])
                ])
            ),
            MCPTool(
                name: "get_place",
                description: "One place: where it is, how many stays it holds, what was folded into it, and when it was last visited.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["place_id": .object(["type": "string"])]),
                    "required": .array(["place_id"])
                ])
            ),
            MCPTool(
                name: "find_problems",
                description: "Look for the things that usually need cleaning up: places sitting on top of each other under different names, a much-visited place folded into a rarely-visited one, stays whose place is a long way from where the stay happened, and places with no name.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "limit": .object(["type": "number", "description": "default 20 of each kind"])
                    ])
                ])
            ),
            MCPTool(
                name: "move_stay",
                description: "Attach one stay to a different place. Only that stay moves; everything else at its old place stays put.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "stay_id": .object(["type": "string"]),
                        "place_id": .object(["type": "string"])
                    ]),
                    "required": .array(["stay_id", "place_id"])
                ])
            ),
            MCPTool(
                name: "rename_place",
                description: "Rename a place. Every stay there is shown under the new name.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "place_id": .object(["type": "string"]),
                        "name": .object(["type": "string"])
                    ]),
                    "required": .array(["place_id", "name"])
                ])
            ),
            MCPTool(
                name: "set_place_location",
                description: "Correct where a place is. Pins and the routes to and from it follow.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "place_id": .object(["type": "string"]),
                        "latitude": .object(["type": "number"]),
                        "longitude": .object(["type": "number"])
                    ]),
                    "required": .array(["place_id", "latitude", "longitude"])
                ])
            ),
            MCPTool(
                name: "merge_places",
                description: "Fold one place into another: its stays move across and its name is dropped. Refused when it would discard the place holding most of the history unless confirm is true, because that is almost always a mistake.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "from_place_id": .object(["type": "string"]),
                        "into_place_id": .object(["type": "string"]),
                        "confirm": .object(["type": "boolean", "description": "required to fold a much-visited place into a rarely-visited one"])
                    ]),
                    "required": .array(["from_place_id", "into_place_id"])
                ])
            ),
            MCPTool(
                name: "add_stay",
                description: "Record a stay that happened but was never captured. Give it a place by id, or a name and a point. Leave the times out and they are guessed from where the day's movement passed closest — which is usually right to within a few minutes.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "place_id": .object(["type": "string", "description": "an existing place; use this when it is somewhere already known"]),
                        "name": .object(["type": "string", "description": "a name, when the place is new"]),
                        "latitude": .object(["type": "number"]),
                        "longitude": .object(["type": "number"]),
                        "date": .object(["type": "string", "description": "yyyy-MM-dd; the day to guess within, if start and end are left out"]),
                        "start": .object(["type": "string", "description": "ISO-8601 or seconds since 1970"]),
                        "end": .object(["type": "string"])
                    ])
                ])
            ),
            MCPTool(
                name: "set_stay_times",
                description: "Correct when a stay began and ended.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "stay_id": .object(["type": "string"]),
                        "start": .object(["type": "string"]),
                        "end": .object(["type": "string"])
                    ]),
                    "required": .array(["stay_id", "start", "end"])
                ])
            ),
            MCPTool(
                name: "split_stay",
                description: "Cut one stay in two at a moment inside it. The first half keeps its id; the second becomes a new stay at the same place. For a long stretch that turns out to have had something in the middle of it.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "stay_id": .object(["type": "string"]),
                        "at": .object(["type": "string", "description": "a moment strictly inside the stay"])
                    ]),
                    "required": .array(["stay_id", "at"])
                ])
            ),
            MCPTool(
                name: "delete_stay",
                description: "Take a stay out of the timeline. It is not destroyed: it goes to the bin, in the order removed, and can be listed or put back.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "stay_id": .object(["type": "string"]),
                        "reason": .object(["type": "string", "description": "why, for whoever reads the bin later"])
                    ]),
                    "required": .array(["stay_id"])
                ])
            ),
            MCPTool(
                name: "stay_history",
                description: "Every version of a stay that something replaced, most recent first — deleted, retimed or split — with when and why. Nothing here is lost; restore_stay puts any of it back.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "stay_id": .object(["type": "string", "description": "narrow to one stay; omit for everything"]),
                        "only_deleted": .object(["type": "boolean", "description": "just the bin"]),
                        "limit": .object(["type": "number", "description": "default 50"])
                    ])
                ])
            ),
            MCPTool(
                name: "restore_stay",
                description: "Put a stay back as it was before the last thing that changed it — whether that was a delete, a retime or a split. Restoring is itself recorded, so it can be undone too.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["stay_id": .object(["type": "string"])]),
                    "required": .array(["stay_id"])
                ])
            ),
            MCPTool(
                name: "find_place_on_map",
                description: "Ask the map where a named place is. Use this before set_place_location or add_stay rather than guessing a coordinate.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "query": .object(["type": "string"]),
                        "near_place_id": .object(["type": "string", "description": "bias the search around a place already known"]),
                        "latitude": .object(["type": "number"]),
                        "longitude": .object(["type": "number"])
                    ]),
                    "required": .array(["query"])
                ])
            ),
            MCPTool(
                name: "stays_at_place",
                description: "Every stay at one place in a window, with how often and how long — for answering how much time somewhere takes up.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "place_id": .object(["type": "string"]),
                        "from": .object(["type": "string", "description": "yyyy-MM-dd; default the beginning of the library"]),
                        "to": .object(["type": "string", "description": "yyyy-MM-dd; default the end of the library"])
                    ]),
                    "required": .array(["place_id"])
                ])
            ),
            MCPTool(
                name: "unmerge_place",
                description: "Undo a fold: the stays go back to the place they were clustered under. The name is not recoverable, so the place comes back unnamed.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["place_id": .object(["type": "string"])]),
                    "required": .array(["place_id"])
                ])
            )
        ]
    }

    // MARK: - Doing it

    func call(_ name: String, arguments: MCPValue) async throws -> MCPValue {
        switch name {
        case "list_days": return try await listDays(arguments)
        case "get_day": return try await getDay(arguments)
        case "search_places": return try await searchPlaces(arguments)
        case "get_place": return try await getPlace(arguments)
        case "find_problems": return try await findProblems(arguments)
        case "move_stay": return try await moveStay(arguments)
        case "rename_place": return try await renamePlace(arguments)
        case "set_place_location": return try await setPlaceLocation(arguments)
        case "merge_places": return try await mergePlaces(arguments)
        case "unmerge_place": return try await unmergePlace(arguments)
        case "add_stay": return try await addStay(arguments)
        case "set_stay_times": return try await setStayTimes(arguments)
        case "split_stay": return try await splitStay(arguments)
        case "delete_stay": return try await deleteStay(arguments)
        case "stay_history": return try await stayHistory(arguments)
        case "restore_stay": return try await restoreStay(arguments)
        case "find_place_on_map": return try await findPlaceOnMap(arguments)
        case "stays_at_place": return try await staysAtPlace(arguments)
        default: throw MCPToolFailure(message: "no tool called \(name)")
        }
    }

    // MARK: - Browsing

    private func listDays(_ arguments: MCPValue) async throws -> MCPValue {
        let (from, to) = try range(arguments)
        let parsed = try await assembled()
        let names = try await placeNames()
        var described: [MCPValue] = []
        for day in parsed.days.sorted(by: { $0.day < $1.day }) where day.day >= from && day.day < to {
            let keys = Set(day.visits.map(\.placeKey)).sorted().prefix(8)
            let labels: [MCPValue] = keys.map { .string(names[$0] ?? $0) }
            described.append(.object([
                "date": .string(Self.day.string(from: day.day)),
                "stays": .number(Double(day.visits.count)),
                "journeys": .number(Double(day.activityLines.count)),
                "places": .array(labels)
            ]))
        }
        return .object(["days": .array(described)])
    }

    private func getDay(_ arguments: MCPValue) async throws -> MCPValue {
        guard let text = arguments["date"]?.stringValue, let day = Self.day.date(from: text) else {
            throw MCPToolFailure(message: "date must be yyyy-MM-dd")
        }
        let parsed = try await assembled()
        let found = parsed.days.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
        guard let record = found else {
            throw MCPToolFailure(message: "nothing recorded on \(text)")
        }
        let names = try await placeNames()

        var stays: [MCPValue] = []
        for visit in record.visits.sorted(by: { $0.start < $1.start }) {
            let label: String = names[visit.placeKey] ?? visit.semanticType ?? "unnamed"
            let minutes: Double = (visit.duration / 60).rounded()
            stays.append(.of([
                "stay_id": .string(visit.id),
                "from": .string(Self.clock.string(from: visit.start)),
                "to": .string(Self.clock.string(from: visit.end)),
                "minutes": .number(minutes),
                "place_id": .string(visit.placeKey),
                "place": .string(label),
                "latitude": visit.coordinate.map { MCPValue.number($0.latitude) },
                "longitude": visit.coordinate.map { MCPValue.number($0.longitude) },
                "derived": visit.isDerived ? MCPValue.bool(true) : nil,
                "in_progress": visit.isOpen ? MCPValue.bool(true) : nil
            ]))
        }

        var journeys: [MCPValue] = []
        for line in record.activityLines.sorted(by: { $0.at < $1.at }) {
            journeys.append(.object([
                "from": .string(Self.clock.string(from: line.at)),
                "to": .string(Self.clock.string(from: line.until)),
                "kind": .string(line.kind.stored)
            ]))
        }

        return .object([
            "date": .string(text),
            "stays": .array(stays),
            "journeys": .array(journeys)
        ])
    }

    private func searchPlaces(_ arguments: MCPValue) async throws -> MCPValue {
        let places = try await database.loadPlaces()
        let counts = try await database.stayCountsByPlace()
        let limit = arguments["limit"]?.intValue ?? 25
        let query = arguments["query"]?.stringValue?.lowercased()
        let near = arguments["near"]

        var matched = places.values.filter { place in
            if let query, !query.isEmpty {
                guard (place.name ?? "").lowercased().contains(query) else { return false }
            }
            if let near,
               let latitude = near["latitude"]?.doubleValue,
               let longitude = near["longitude"]?.doubleValue {
                guard let coordinate = place.coordinate else { return false }
                let radius = near["radius_m"]?.doubleValue ?? 500
                let centre = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                guard RoutePlanner.meters(centre, coordinate) <= radius else { return false }
            }
            return true
        }
        matched.sort { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }

        return .object([
            "places": .array(matched.prefix(limit).map { Self.describe($0, stays: counts[$0.id] ?? 0) })
        ])
    }

    private func getPlace(_ arguments: MCPValue) async throws -> MCPValue {
        let id = try placeID(arguments, "place_id")
        let places = try await database.loadPlaces()
        guard let place = places[id] else { throw MCPToolFailure(message: "no place with id \(id)") }
        let counts = try await database.stayCountsByPlace()
        let merges = try await database.loadPlaceMerges()
        let recent = try await database.visits(placeKey: id, since: .distantPast, limit: 10)

        var described = Self.describe(place, stays: counts[id] ?? 0).objectValue ?? [:]
        described["folded_in"] = .array(merges.filter { $0.value == id }.keys.sorted().map { .string($0) })
        described["recent_stays"] = .array(recent.sorted { $0.start > $1.start }.map { visit in
            .object([
                "stay_id": .string(visit.id),
                "start": .string(Self.stamp.string(from: visit.start)),
                "minutes": .number((visit.duration / 60).rounded())
            ])
        })
        return .object(described)
    }

    // MARK: - Diagnosing

    private func findProblems(_ arguments: MCPValue) async throws -> MCPValue {
        let limit = arguments["limit"]?.intValue ?? 20
        let places = try await database.loadPlaces()
        let counts = try await database.stayCountsByPlace()
        let merges = try await database.loadPlaceMerges()

        // The same name twice is the one worth acting on without thinking. A
        // plaza puts a bank, an off-licence and a supermarket within fifty
        // metres of each other and none of them is a duplicate, so distance
        // alone says almost nothing — it only means something when the names
        // agree, or when two things are close enough to be one doorway.
        var sameName: [MCPValue] = []
        var suspiciouslyClose: [MCPValue] = []
        let named = places.values.filter { $0.coordinate != nil && !($0.name ?? "").isEmpty }
        for (index, place) in named.enumerated() {
            for other in named.dropFirst(index + 1) {
                guard let here = place.coordinate, let there = other.coordinate else { continue }
                // Already folded into one another is not a duplicate — it is a
                // duplicate that was dealt with, and reporting it again asks for
                // the same work twice.
                guard merges[place.id] != other.id, merges[other.id] != place.id else { continue }
                let metres = RoutePlanner.meters(here, there)
                let matching = place.name?.caseInsensitiveCompare(other.name ?? "") == .orderedSame
                guard metres <= (matching ? Self.sameNameRadius : Self.sameDoorwayRadius) else { continue }
                let pair = MCPValue.object([
                    "a": .string(place.id), "a_name": .string(place.name ?? ""),
                    "a_stays": .number(Double(counts[place.id] ?? 0)),
                    "b": .string(other.id), "b_name": .string(other.name ?? ""),
                    "b_stays": .number(Double(counts[other.id] ?? 0)),
                    "metres_apart": .number(metres.rounded()),
                    "note": "merge_places folds one into the other — send the smaller into the larger"
                ])
                if matching { sameName.append(pair) } else { suspiciouslyClose.append(pair) }
            }
        }

        // A fold that swallowed the greater history.
        var lopsided: [MCPValue] = []
        for (from, into) in merges where !into.isEmpty {
            let source = counts[from] ?? 0
            let target = counts[into] ?? 0
            guard PlaceGuessRanker.foldsAwayTheLargerHistory(source: max(source, 1), target: target) else { continue }
            lopsided.append(.object([
                "folded": .string(from),
                "into": .string(into),
                "into_name": .string(places[into]?.name ?? ""),
                "note": "unmerge_place can undo this"
            ]))
        }

        // Places carrying real history with nothing to call them. A place that
        // knows it is home or work reads fine without a name of its own, so it
        // is not a problem to be fixed.
        let unnamed = places.values
            .filter { place in
                (place.name ?? "").isEmpty
                    && (place.semanticType ?? "").isEmpty
                    && (counts[place.id] ?? 0) >= 5
            }
            .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
            .prefix(limit)
            .map { Self.describe($0, stays: counts[$0.id] ?? 0) }

        // Named rows holding nothing. A place that was folded into another is
        // meant to be empty, so it does not count: what is left is the row that
        // lost its stays some other way and is now just a name on the map.
        let empty = places.values
            .filter { place in
                !(place.name ?? "").isEmpty
                    && (counts[place.id] ?? 0) == 0
                    && (merges[place.id] ?? "").isEmpty
            }
            .prefix(limit)
            .map { Self.describe($0, stays: 0) }

        return .object([
            "same_name_twice": .array(Array(sameName.prefix(limit))),
            "close_enough_to_be_one_doorway": .array(Array(suspiciouslyClose.prefix(limit))),
            "folds_that_swallowed_the_bigger_place": .array(Array(lopsided.prefix(limit))),
            "unnamed_places_with_history": .array(Array(unnamed)),
            "places_holding_nothing": .array(Array(empty))
        ])
    }

    /// Two rows with the same name this close are one place written twice.
    private static let sameNameRadius: Double = 150
    /// Different names need to be nearly touching before it means anything: a
    /// plaza is full of distinct shops fifty metres apart.
    private static let sameDoorwayRadius: Double = 20

    // MARK: - Fixing

    private func moveStay(_ arguments: MCPValue) async throws -> MCPValue {
        guard let stayID = arguments["stay_id"]?.stringValue, !stayID.isEmpty else {
            throw MCPToolFailure(message: "stay_id is required")
        }
        let placeID = try placeID(arguments, "place_id")
        let places = try await database.loadPlaces()
        guard let place = places[placeID] else { throw MCPToolFailure(message: "no place with id \(placeID)") }
        try await database.moveVisit(id: stayID, toPlaceKey: placeID)
        onChanged()
        return .object([
            "moved": .string(stayID),
            "to": .string(place.name ?? placeID)
        ])
    }

    private func renamePlace(_ arguments: MCPValue) async throws -> MCPValue {
        let id = try placeID(arguments, "place_id")
        guard let name = arguments["name"]?.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPToolFailure(message: "name is required")
        }
        try await database.setPlaceName(placeKey: id, name: name)
        onChanged()
        return .object(["renamed": .string(id), "to": .string(name)])
    }

    private func setPlaceLocation(_ arguments: MCPValue) async throws -> MCPValue {
        let id = try placeID(arguments, "place_id")
        guard let latitude = arguments["latitude"]?.doubleValue,
              let longitude = arguments["longitude"]?.doubleValue else {
            throw MCPToolFailure(message: "latitude and longitude are required")
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw MCPToolFailure(message: "that is not a point on earth")
        }
        try await database.setPlaceLocation(placeKey: id, coordinate: coordinate)
        onChanged()
        return .object(["moved": .string(id), "to": .array([.number(latitude), .number(longitude)])])
    }

    private func mergePlaces(_ arguments: MCPValue) async throws -> MCPValue {
        let from = try placeID(arguments, "from_place_id")
        let into = try placeID(arguments, "into_place_id")
        guard from != into else { throw MCPToolFailure(message: "those are the same place") }
        let places = try await database.loadPlaces()
        guard places[from] != nil else { throw MCPToolFailure(message: "no place with id \(from)") }
        guard let target = places[into] else { throw MCPToolFailure(message: "no place with id \(into)") }

        let counts = try await database.stayCountsByPlace()
        let source = counts[from] ?? 0
        let destination = counts[into] ?? 0
        // The same guard the rename sheet applies, for the same reason: this is
        // how seventy-nine stays at a supermarket ended up in an insurance
        // office. An agent has to mean it.
        if PlaceGuessRanker.foldsAwayTheLargerHistory(source: source, target: destination),
           arguments["confirm"]?.boolValue != true {
            throw MCPToolFailure(message: """
            Refusing: \(places[from]?.name ?? from) holds \(source) stays and \
            \(target.name ?? into) holds \(destination). Merging drops the larger \
            history. Merge the other way round, or pass confirm: true if this is \
            really what is wanted.
            """)
        }
        try await database.mergePlace(from: from, into: into, targetSemantic: target.semanticType)
        onChanged()
        return .object([
            "folded": .string(from),
            "into": .string(into),
            "stays_moved": .number(Double(source)),
            "undo_with": "unmerge_place"
        ])
    }

    private func unmergePlace(_ arguments: MCPValue) async throws -> MCPValue {
        let id = try placeID(arguments, "place_id")
        let merges = try await database.loadPlaceMerges()
        guard let into = merges[id], !into.isEmpty else {
            throw MCPToolFailure(message: "\(id) is not folded into anything")
        }
        try await database.unmergePlace(from: id)
        let counts = try await database.stayCountsByPlace()
        onChanged()
        return .object([
            "restored": .string(id),
            "was_folded_into": .string(into),
            "stays_back": .number(Double(counts[id] ?? 0)),
            "note": "the name was cleared by the merge and cannot be recovered — rename_place if it needs one"
        ])
    }

    // MARK: - Editing the day

    private func addStay(_ arguments: MCPValue) async throws -> MCPValue {
        let places = try await database.loadPlaces()
        let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Either somewhere already known, or a point with a name on it.
        var placeKey: String
        var coordinate: CLLocationCoordinate2D
        if let existing = arguments["place_id"]?.stringValue, !existing.isEmpty {
            guard let place = places[existing] else {
                throw MCPToolFailure(message: "no place with id \(existing)")
            }
            guard let known = place.coordinate else {
                throw MCPToolFailure(message: "\(place.name ?? existing) has no location — set_place_location first")
            }
            placeKey = existing
            coordinate = known
        } else if let latitude = arguments["latitude"]?.doubleValue,
                  let longitude = arguments["longitude"]?.doubleValue {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else {
                throw MCPToolFailure(message: "that is not a point on earth")
            }
            placeKey = Geo.placeKey(id: nil, coordinate: coordinate)
        } else {
            throw MCPToolFailure(message: "give either place_id, or latitude and longitude — find_place_on_map can supply the second")
        }

        // Times, or the day's movement asked where it passed closest.
        let start: Date
        let end: Date
        var basis = "given"
        if let from = arguments["start"]?.dateValue, let to = arguments["end"]?.dateValue, to > from {
            start = from
            end = to
        } else {
            guard let dayText = arguments["date"]?.stringValue, let day = Self.day.date(from: dayText) else {
                throw MCPToolFailure(message: "give start and end, or a date to guess the times within")
            }
            let guess = try await guessTiming(at: coordinate, on: day)
            start = guess.start
            end = guess.end
            basis = Self.describe(guess.basis)
        }

        let visit = TimelineVisit(
            id: Geo.segmentID("mv", Geo.millis(start), placeKey),
            start: start,
            end: max(end, start.addingTimeInterval(60)),
            coordinate: coordinate,
            semanticType: nil,
            placeKey: placeKey
        )
        try await database.record(
            batch: TimelineBatch(visits: [visit], activities: [], paths: []),
            source: .manual
        )
        if let name, !name.isEmpty, arguments["place_id"]?.stringValue == nil {
            try await database.setPlaceName(placeKey: placeKey, name: name)
        }
        onChanged()
        return .object([
            "stay_id": .string(visit.id),
            "place_id": .string(placeKey),
            "from": .string(Self.stamp.string(from: visit.start)),
            "to": .string(Self.stamp.string(from: visit.end)),
            "minutes": .number((visit.duration / 60).rounded()),
            "times": .string(basis)
        ])
    }

    private func setStayTimes(_ arguments: MCPValue) async throws -> MCPValue {
        guard let id = arguments["stay_id"]?.stringValue, !id.isEmpty else {
            throw MCPToolFailure(message: "stay_id is required")
        }
        guard let start = arguments["start"]?.dateValue, let end = arguments["end"]?.dateValue else {
            throw MCPToolFailure(message: "start and end are required")
        }
        guard end > start else { throw MCPToolFailure(message: "a stay has to end after it begins") }
        guard try await database.setVisitTimes(id: id, start: start, end: end) else {
            throw MCPToolFailure(message: "no stay with id \(id)")
        }
        onChanged()
        return .object([
            "stay_id": .string(id),
            "from": .string(Self.stamp.string(from: start)),
            "to": .string(Self.stamp.string(from: end))
        ])
    }

    private func splitStay(_ arguments: MCPValue) async throws -> MCPValue {
        guard let id = arguments["stay_id"]?.stringValue, !id.isEmpty else {
            throw MCPToolFailure(message: "stay_id is required")
        }
        guard let moment = arguments["at"]?.dateValue else {
            throw MCPToolFailure(message: "at is required")
        }
        guard let tail = try await database.splitVisit(id: id, at: moment) else {
            throw MCPToolFailure(message: "no stay with id \(id), or that moment is not inside it")
        }
        onChanged()
        return .object([
            "first_half": .string(id),
            "second_half": .string(tail.id),
            "split_at": .string(Self.stamp.string(from: moment))
        ])
    }

    private func deleteStay(_ arguments: MCPValue) async throws -> MCPValue {
        guard let id = arguments["stay_id"]?.stringValue, !id.isEmpty else {
            throw MCPToolFailure(message: "stay_id is required")
        }
        let reason = arguments["reason"]?.stringValue
        guard try await database.deleteVisit(id: id, reason: reason) else {
            throw MCPToolFailure(message: "no stay with id \(id)")
        }
        onChanged()
        return .object([
            "deleted": .string(id),
            "note": "kept in the bin — list_deleted_stays to see it, restore_stay to put it back"
        ])
    }

    private func stayHistory(_ arguments: MCPValue) async throws -> MCPValue {
        let limit = arguments["limit"]?.intValue ?? 50
        let onlyDeleted = arguments["only_deleted"]?.boolValue ?? false
        let stayID = arguments["stay_id"]?.stringValue
        let versions = try await database.visitHistory(id: stayID, onlyDeleted: onlyDeleted, limit: limit)
        let names = try await placeNames()
        let described = versions.map { version in
            MCPValue.of([
                "stay_id": .string(version.visit.id),
                "was_from": .string(Self.stamp.string(from: version.visit.start)),
                "was_to": .string(Self.stamp.string(from: version.visit.end)),
                "place": .string(names[version.visit.placeKey] ?? version.visit.placeKey),
                "change": .string(version.change.rawValue),
                "changed_at": .string(Self.stamp.string(from: version.changedAt)),
                "reason": version.reason.map { MCPValue.string($0) },
                "still_in_timeline": .bool(!version.isGone)
            ])
        }
        return .object(["versions": .array(described)])
    }

    private func restoreStay(_ arguments: MCPValue) async throws -> MCPValue {
        guard let id = arguments["stay_id"]?.stringValue, !id.isEmpty else {
            throw MCPToolFailure(message: "stay_id is required")
        }
        guard let restored = try await database.restoreVisit(id: id) else {
            throw MCPToolFailure(message: "no earlier version of \(id) was kept")
        }
        onChanged()
        return .object([
            "restored": .string(restored.id),
            "from": .string(Self.stamp.string(from: restored.start)),
            "to": .string(Self.stamp.string(from: restored.end))
        ])
    }

    // MARK: - Asking the map

    private func findPlaceOnMap(_ arguments: MCPValue) async throws -> MCPValue {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw MCPToolFailure(message: "query is required")
        }
        var centre: CLLocationCoordinate2D?
        if let id = arguments["near_place_id"]?.stringValue {
            centre = try await database.loadPlaces()[id]?.coordinate
        }
        if let latitude = arguments["latitude"]?.doubleValue,
           let longitude = arguments["longitude"]?.doubleValue {
            centre = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        // Failing that, search around the place visited most, which is very
        // likely the part of the world this library is about.
        if centre == nil {
            let counts = try await database.stayCountsByPlace()
            if let busiest = counts.max(by: { $0.value < $1.value })?.key {
                centre = try await database.loadPlaces()[busiest]?.coordinate
            }
        }
        let found = await MCPMapLookup.search(query: query, near: centre)
        guard !found.isEmpty else { throw MCPToolFailure(message: "the map found nothing for \(query)") }
        return .object(["results": .array(found.map { result in
            .of([
                "name": .string(result.name),
                "address": result.address.map { MCPValue.string($0) },
                "latitude": .number(result.coordinate.latitude),
                "longitude": .number(result.coordinate.longitude)
            ])
        })])
    }

    // MARK: - Counting

    private func staysAtPlace(_ arguments: MCPValue) async throws -> MCPValue {
        let id = try placeID(arguments, "place_id")
        let places = try await database.loadPlaces()
        guard let place = places[id] else { throw MCPToolFailure(message: "no place with id \(id)") }
        // Both ends open by default. Asking how often you go somewhere and
        // silently being given only part of the answer is worse than being
        // given all of it.
        let from = arguments["from"]?.stringValue.flatMap { Self.day.date(from: $0) } ?? .distantPast
        let to = arguments["to"]?.stringValue
            .flatMap { Self.day.date(from: $0) }
            .map { $0.addingTimeInterval(24 * 3_600) } ?? .distantFuture
        let stays = try await database.visits(placeKey: id, from: from, to: to)
        let minutes = stays.reduce(0.0) { $0 + $1.duration / 60 }
        let listed = stays.suffix(50).map { visit in
            MCPValue.object([
                "stay_id": .string(visit.id),
                "from": .string(Self.stamp.string(from: visit.start)),
                "minutes": .number((visit.duration / 60).rounded())
            ])
        }
        return .object([
            "place": .string(place.name ?? id),
            "stays": .number(Double(stays.count)),
            "total_hours": .number((minutes / 60).rounded()),
            "first": stays.first.map { .string(Self.stamp.string(from: $0.start)) } ?? .null,
            "last": stays.last.map { .string(Self.stamp.string(from: $0.start)) } ?? .null,
            "recent": .array(listed)
        ])
    }

    private func guessTiming(at coordinate: CLLocationCoordinate2D, on day: Date) async throws -> VisitTimingGuesser.Guess {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(24 * 3_600)
        let fixes = (try? await database.fixes(from: dayStart, to: dayEnd)) ?? []
        let parsed = try await assembled()
        let record = parsed.days.first { calendar.isDate($0.day, inSameDayAs: day) }
        let midpoint = VisitTimingGuesser.largestGapMidpoint(
            between: record?.visits ?? [],
            on: dayStart,
            calendar: calendar
        )
        return VisitTimingGuesser.guess(
            placeCoordinate: coordinate,
            fixes: fixes,
            paths: record?.paths ?? [],
            fallbackMidpoint: midpoint
        )
    }

    private static func describe(_ basis: VisitTimingGuesser.Guess.Basis) -> String {
        switch basis {
        case .stopped: return "guessed — the day's fixes show stopping there"
        case .droveBy: return "guessed — the day's movement passed close by"
        case .unknown: return "a placeholder — nothing that day went near it"
        }
    }

    // MARK: - Bits

    /// Display names by place id, which is where a name actually lives now.
    private func placeNames() async throws -> [String: String] {
        let places = try await database.loadPlaces()
        return places.compactMapValues { place in
            guard let name = place.name, !name.isEmpty else { return nil }
            return name
        }
    }

    private func assembled() async throws -> ParsedTimeline {
        guard let batch = try await database.loadBatch() else {
            throw MCPToolFailure(message: "the library is empty")
        }
        return TimelineParser.assemble(batch, sourceName: "library")
    }

    private func range(_ arguments: MCPValue) throws -> (Date, Date) {
        guard let fromText = arguments["from"]?.stringValue,
              let from = Self.day.date(from: fromText),
              let toText = arguments["to"]?.stringValue,
              let to = Self.day.date(from: toText) else {
            throw MCPToolFailure(message: "from and to must both be yyyy-MM-dd")
        }
        return (from, to.addingTimeInterval(24 * 3_600))
    }

    private func placeID(_ arguments: MCPValue, _ key: String) throws -> String {
        guard let id = arguments[key]?.stringValue, !id.isEmpty else {
            throw MCPToolFailure(message: "\(key) is required")
        }
        return id
    }

    private static func describe(_ place: PlaceEntity, stays: Int) -> MCPValue {
        .of([
            "place_id": .string(place.id),
            "name": place.name.map { .string($0) },
            "kind": place.semanticType.map { .string($0) },
            "stays": .number(Double(stays)),
            "latitude": place.coordinate.map { .number($0.latitude) },
            "longitude": place.coordinate.map { .number($0.longitude) },
            "folded_into": place.mergedInto.flatMap { $0.isEmpty ? nil : .string($0) }
        ])
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return formatter
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        return formatter
    }()
}
