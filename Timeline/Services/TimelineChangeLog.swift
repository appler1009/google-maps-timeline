import Foundation

/// Which table a change came from. The raw values are written to the database and
/// will end up in record types and file payloads, so they are part of the format.
enum ChangeKind: String, CaseIterable, Sendable {
    case visit
    case activity
    case path
    case placeName
    case placeMerge
}

enum ChangeOperation: String, Sendable {
    case upsert
    case delete
}

/// Whether a write came from this device or arrived from somewhere else.
///
/// Remote writes must not be logged, or pulling a change would immediately queue
/// it to be pushed back out — the echo loop that makes naive sync layers loop
/// forever.
enum ChangeOrigin: Sendable {
    case local
    case remote
}

/// One row waiting to be sent somewhere.
struct PendingChange: Equatable, Sendable {
    let kind: ChangeKind
    let rowID: String
    let operation: ChangeOperation
    /// Monotonic across the library. Re-changing a row moves it to a new seq, so
    /// an acknowledgement for the old one cannot swallow the new edit.
    let seq: Int64
    let changedAt: Date
}

/// A batch of pending changes with the rows they refer to, ready to hand to
/// whatever does the sending — a CloudKit record batch, or a delta file.
struct ChangeBatch: Sendable {
    var changes: [PendingChange] = []
    var visits: [TimelineVisit] = []
    var activities: [TimelineActivity] = []
    var paths: [TimelinePath] = []
    var names: [String: PlaceIdentityName] = [:]
    var merges: [String: PlaceIdentityMerge] = [:]

    var isEmpty: Bool { changes.isEmpty }
    var count: Int { changes.count }

    /// Rows named by a change but missing from the tables — deleted between the
    /// log write and the read. They acknowledge like anything else.
    var deletions: [PendingChange] {
        changes.filter { $0.operation == .delete }
    }
}
