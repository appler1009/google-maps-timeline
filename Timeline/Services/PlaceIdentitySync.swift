import Foundation

struct PlaceIdentityName: Hashable, Sendable {
    var name: String
    var updatedAt: TimeInterval
}

struct PlaceIdentityMerge: Hashable, Sendable {
    var toKey: String
    var updatedAt: TimeInterval
}

struct PlaceIdentitySnapshot: Hashable, Sendable {
    var names: [String: PlaceIdentityName]
    var merges: [String: PlaceIdentityMerge]

    static let empty = PlaceIdentitySnapshot(names: [:], merges: [:])
}

extension Dictionary where Key == String, Value == String {
    func resolvedMerges() -> [String: String] {
        var resolved: [String: String] = [:]
        for key in keys {
            var current = key
            var seen: Set<String> = [key]
            while let next = self[current], !seen.contains(next) {
                seen.insert(next)
                current = next
            }
            if current != key {
                resolved[key] = current
            }
        }
        return resolved
    }
}

/// Syncs custom place names and merges through iCloud Key-Value Store.
@MainActor
final class PlaceIdentitySync {
    static let shared = PlaceIdentitySync()

    private static let storageKey = "placeIdentity.v1"
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    private init() {}

    func start(onChange: @escaping () -> Void) {
        guard observer == nil else { return }
        _ = store.synchronize()
        let remote = pull()
        TimelineLog.info(
            "place-identity sync started",
            [
                "names": "\(remote.names.count)",
                "merges": "\(remote.merges.count)",
                "bytes": "\(store.data(forKey: Self.storageKey)?.count ?? 0)",
            ]
        )
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { notification in
            let reason = (notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int)
                .map(String.init) ?? "?"
            let keys = (notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            TimelineLog.info(
                "place-identity KVS external change",
                ["reason": reason, "keys": keys.joined(separator: ",")]
            )
            if keys.contains("logdock.intake.v1") {
                TimelineLog.refreshConfiguration()
            }
            onChange()
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func synchronize() {
        _ = store.synchronize()
    }

    func pull() -> PlaceIdentitySnapshot {
        decode(store.data(forKey: Self.storageKey))
    }

    func push(_ snapshot: PlaceIdentitySnapshot) {
        let before = pull()
        let merged = Self.merged(local: snapshot, remote: before)
        let data = encode(merged)
        store.set(data, forKey: Self.storageKey)
        let ok = store.synchronize()
        TimelineLog.info(
            "place-identity push",
            [
                "localNames": "\(snapshot.names.count)",
                "localMerges": "\(snapshot.merges.count)",
                "remoteNames": "\(before.names.count)",
                "remoteMerges": "\(before.merges.count)",
                "mergedNames": "\(merged.names.count)",
                "mergedMerges": "\(merged.merges.count)",
                "bytes": "\(data.count)",
                "synchronize": ok ? "1" : "0",
            ]
        )
    }

    /// Last-write-wins merge of local and remote identity records.
    static func merged(local: PlaceIdentitySnapshot, remote: PlaceIdentitySnapshot) -> PlaceIdentitySnapshot {
        var names = remote.names
        for (key, value) in local.names {
            if let existing = names[key], existing.updatedAt > value.updatedAt { continue }
            names[key] = value
        }
        var merges = remote.merges
        for (key, value) in local.merges {
            if let existing = merges[key], existing.updatedAt > value.updatedAt { continue }
            merges[key] = value
        }
        return PlaceIdentitySnapshot(names: names, merges: merges)
    }

    private func encode(_ snapshot: PlaceIdentitySnapshot) -> Data {
        var names: [String: [String: Any]] = [:]
        for (key, value) in snapshot.names {
            names[key] = ["name": value.name, "updatedAt": value.updatedAt]
        }
        var merges: [String: [String: Any]] = [:]
        for (key, value) in snapshot.merges {
            merges[key] = ["toKey": value.toKey, "updatedAt": value.updatedAt]
        }
        let payload: [String: Any] = ["names": names, "merges": merges]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    private func decode(_ data: Data?) -> PlaceIdentitySnapshot {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }

        var names: [String: PlaceIdentityName] = [:]
        if let raw = json["names"] as? [String: [String: Any]] {
            for (key, value) in raw {
                let name = value["name"] as? String ?? ""
                let updatedAt = value["updatedAt"] as? TimeInterval ?? 0
                names[key] = PlaceIdentityName(name: name, updatedAt: updatedAt)
            }
        }

        var merges: [String: PlaceIdentityMerge] = [:]
        if let raw = json["merges"] as? [String: [String: Any]] {
            for (key, value) in raw {
                guard let toKey = value["toKey"] as? String else { continue }
                let updatedAt = value["updatedAt"] as? TimeInterval ?? 0
                merges[key] = PlaceIdentityMerge(toKey: toKey, updatedAt: updatedAt)
            }
        }
        return PlaceIdentitySnapshot(names: names, merges: merges)
    }
}
