import Foundation
import CloudKit
import CoreLocation

/// Rows in, `CKRecord`s out, and back again.
///
/// This is the half of CloudKit worth testing: the engine itself is glue that
/// only misbehaves against the live service, but a field that round-trips wrong
/// corrupts the library on the other device, silently.
///
/// The record name is the row id itself. That works because ids are content
/// hashes (`Geo.segmentID`) rather than autoincrement integers, so both devices
/// independently mint the same name for the same stay and a re-send is a no-op.
enum TimelineRecordMapper {
    static let zoneName = "timeline"

    enum Field {
        static let start = "start"
        static let end = "end"
        static let latitude = "lat"
        static let longitude = "lon"
        static let placeKey = "placeKey"
        static let semanticType = "semanticType"
        static let source = "source"
        static let distance = "distance"
        static let startLatitude = "startLat"
        static let startLongitude = "startLon"
        static let endLatitude = "endLat"
        static let endLongitude = "endLon"
        static let kind = "kind"
        static let points = "points"
        static let name = "name"
        static let toKey = "toKey"
        static let updatedAt = "updatedAt"
    }

    /// Record types are the change kinds, capitalised — CloudKit convention, and
    /// it keeps the two lists impossible to drift apart.
    static func recordType(for kind: ChangeKind) -> String {
        switch kind {
        case .visit: return "Visit"
        case .activity: return "Activity"
        case .path: return "Path"
        case .placeName: return "PlaceName"
        case .placeMerge: return "PlaceMerge"
        }
    }

    static func kind(forRecordType type: String) -> ChangeKind? {
        ChangeKind.allCases.first { recordType(for: $0) == type }
    }

    static func recordID(for change: PendingChange, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: change.rowID, zoneID: zoneID)
    }

    /// The record to write fields onto.
    ///
    /// `base` is the last record CloudKit acknowledged, rebuilt from its archived
    /// system fields. Using it carries the change tag forward, which is what makes
    /// the save an *update*. A fresh CKRecord has no tag, so the server reads it
    /// as an insert and refuses it the moment the row exists.
    static func canvas(
        base: CKRecord?,
        type: String,
        recordName: String,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord {
        if let base, base.recordType == type, base.recordID.recordName == recordName {
            return base
        }
        return CKRecord(recordType: type, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
    }

    /// Rebuild a record from the system fields we stored for it.
    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        return record
    }

    /// Keep only the system fields: the values are in the library already, and
    /// storing them twice invites the two copies to disagree.
    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    // MARK: - Row → record

    static func record(for visit: TimelineVisit, in zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = canvas(base: base, type: recordType(for: .visit), recordName: visit.id, in: zoneID)
        record[Field.start] = visit.start as NSDate
        record[Field.end] = visit.end as NSDate
        record[Field.placeKey] = visit.placeKey as NSString
        if let coordinate = visit.coordinate {
            record[Field.latitude] = coordinate.latitude as NSNumber
            record[Field.longitude] = coordinate.longitude as NSNumber
        }
        if let type = visit.semanticType {
            record[Field.semanticType] = type as NSString
        }
        return record
    }

    static func record(for activity: TimelineActivity, in zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = canvas(base: base, type: recordType(for: .activity), recordName: activity.id, in: zoneID)
        record[Field.start] = activity.start as NSDate
        record[Field.end] = activity.end as NSDate
        record[Field.distance] = activity.distance as NSNumber
        record[Field.kind] = activity.kind.stored as NSString
        if let start = activity.startCoordinate {
            record[Field.startLatitude] = start.latitude as NSNumber
            record[Field.startLongitude] = start.longitude as NSNumber
        }
        if let end = activity.endCoordinate {
            record[Field.endLatitude] = end.latitude as NSNumber
            record[Field.endLongitude] = end.longitude as NSNumber
        }
        return record
    }

    /// Points travel as the same packed blob the database stores — 16 bytes a
    /// point, so even a full-trace day stays far inside CloudKit's 1 MB record
    /// limit once `MotionSegmenter` has thinned it.
    static func record(for path: TimelinePath, in zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let record = canvas(base: base, type: recordType(for: .path), recordName: path.id, in: zoneID)
        record[Field.start] = path.start as NSDate
        record[Field.end] = path.end as NSDate
        record[Field.kind] = path.kind.stored as NSString
        record[Field.points] = CoordBlob.pack(path.points) as NSData
        return record
    }

    static func record(
        forPlaceKey key: String,
        name: PlaceIdentityName,
        in zoneID: CKRecordZone.ID,
        base: CKRecord? = nil
    ) -> CKRecord {
        let record = canvas(base: base, type: recordType(for: .placeName), recordName: key, in: zoneID)
        record[Field.name] = name.name as NSString
        record[Field.updatedAt] = name.updatedAt as NSNumber
        return record
    }

    static func record(
        forPlaceKey key: String,
        merge: PlaceIdentityMerge,
        in zoneID: CKRecordZone.ID,
        base: CKRecord? = nil
    ) -> CKRecord {
        let record = canvas(base: base, type: recordType(for: .placeMerge), recordName: key, in: zoneID)
        record[Field.toKey] = merge.toKey as NSString
        record[Field.updatedAt] = merge.updatedAt as NSNumber
        return record
    }

    // MARK: - Record → row

    static func visit(from record: CKRecord) -> TimelineVisit? {
        guard record.recordType == recordType(for: .visit),
              let start = record[Field.start] as? Date,
              let end = record[Field.end] as? Date,
              let placeKey = record[Field.placeKey] as? String else { return nil }
        return TimelineVisit(
            id: record.recordID.recordName,
            start: start,
            end: end,
            coordinate: coordinate(record, Field.latitude, Field.longitude),
            semanticType: record[Field.semanticType] as? String,
            placeKey: placeKey
        )
    }

    static func activity(from record: CKRecord) -> TimelineActivity? {
        guard record.recordType == recordType(for: .activity),
              let start = record[Field.start] as? Date,
              let end = record[Field.end] as? Date else { return nil }
        return TimelineActivity(
            id: record.recordID.recordName,
            start: start,
            end: end,
            distance: record[Field.distance] as? Double ?? 0,
            startCoordinate: coordinate(record, Field.startLatitude, Field.startLongitude),
            endCoordinate: coordinate(record, Field.endLatitude, Field.endLongitude),
            kind: TravelKind(stored: record[Field.kind] as? String ?? "automobile")
        )
    }

    static func path(from record: CKRecord) -> TimelinePath? {
        guard record.recordType == recordType(for: .path),
              let start = record[Field.start] as? Date,
              let end = record[Field.end] as? Date,
              let data = record[Field.points] as? Data,
              let points = CoordBlob.unpack(data), points.count >= 2 else { return nil }
        return TimelinePath(
            id: record.recordID.recordName,
            start: start,
            end: end,
            points: points,
            kind: TravelKind(stored: record[Field.kind] as? String ?? "automobile")
        )
    }

    static func placeName(from record: CKRecord) -> (key: String, name: PlaceIdentityName)? {
        guard record.recordType == recordType(for: .placeName),
              let name = record[Field.name] as? String,
              let updatedAt = record[Field.updatedAt] as? Double else { return nil }
        return (record.recordID.recordName, PlaceIdentityName(name: name, updatedAt: updatedAt))
    }

    static func placeMerge(from record: CKRecord) -> (key: String, merge: PlaceIdentityMerge)? {
        guard record.recordType == recordType(for: .placeMerge),
              let toKey = record[Field.toKey] as? String,
              let updatedAt = record[Field.updatedAt] as? Double else { return nil }
        return (record.recordID.recordName, PlaceIdentityMerge(toKey: toKey, updatedAt: updatedAt))
    }

    /// Sort fetched records into the shapes the database writes.
    static func batch(from records: [CKRecord]) -> (
        rows: TimelineBatch,
        names: [String: PlaceIdentityName],
        merges: [String: PlaceIdentityMerge]
    ) {
        var rows = TimelineBatch(visits: [], activities: [], paths: [])
        var names: [String: PlaceIdentityName] = [:]
        var merges: [String: PlaceIdentityMerge] = [:]
        for record in records {
            switch kind(forRecordType: record.recordType) {
            case .visit:
                if let visit = visit(from: record) { rows.visits.append(visit) }
            case .activity:
                if let activity = activity(from: record) { rows.activities.append(activity) }
            case .path:
                if let path = path(from: record) { rows.paths.append(path) }
            case .placeName:
                if let parsed = placeName(from: record) { names[parsed.key] = parsed.name }
            case .placeMerge:
                if let parsed = placeMerge(from: record) { merges[parsed.key] = parsed.merge }
            case nil:
                continue
            }
        }
        return (rows, names, merges)
    }

    private static func coordinate(_ record: CKRecord, _ latField: String, _ lonField: String) -> CLLocationCoordinate2D? {
        guard let latitude = record[latField] as? Double, let longitude = record[lonField] as? Double else {
            return nil
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
}
