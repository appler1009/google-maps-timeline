import Foundation
import LogShip
#if canImport(Darwin)
import Darwin
#endif

/// Fire-and-forget LogDock shipping. Inert when no collector/token is available.
enum TimelineLog {
    #if os(iOS)
    static let source = "timeline-ios"
    #else
    static let source = "timeline-mac"
    #endif

    private static let intakeDefaultsKey = "Timeline.logdock.intake"
    private static let kvsIntakeKey = "logdock.intake.v1"
    private static let defaultLocalURL = URL(string: "http://127.0.0.1:8737")!
    private static let configureLock = NSLock()
    private static var didStartConfigure = false

    static func start() {
        Task { await bootstrap() }
    }

    static func bootstrap() async {
        await configureIfPossible()
        await MainActor.run { publishIntakeForPeersIfNeeded() }
        let status = await LogShip.shared.status()
        if status.isConfigured {
            info("logship ready", ["source": source])
            info("app launch")
        } else {
            NSLog("[TimelineLog] LogShip not configured (no LogDock URL/token)")
        }
    }

    static func debug(_ message: String, _ metadata: [String: String]? = nil) {
        Task {
            await configureIfPossible()
            await LogShip.shared.debug(message, metadata: metadata)
        }
    }

    static func info(_ message: String, _ metadata: [String: String]? = nil) {
        Task {
            await configureIfPossible()
            await LogShip.shared.info(message, metadata: metadata)
        }
    }

    static func warning(_ message: String, _ metadata: [String: String]? = nil) {
        Task {
            await configureIfPossible()
            await LogShip.shared.warning(message, metadata: metadata)
        }
    }

    static func error(_ message: String, _ metadata: [String: String]? = nil) {
        Task {
            await configureIfPossible()
            await LogShip.shared.error(message, metadata: metadata)
        }
    }

    /// Re-read intake config (e.g. after an external KVS change published a Mac LAN URL).
    static func refreshConfiguration() {
        Task { await configureIfPossible(force: true) }
    }

    @MainActor
    static func publishIntakeForPeersIfNeeded() {
        #if os(macOS)
        guard let token = collectorToken() else { return }
        let lan = primaryIPv4Address().map { "http://\($0):8737" } ?? defaultLocalURL.absoluteString
        let payload: [String: String] = ["url": lan, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let store = NSUbiquitousKeyValueStore.default
        store.set(data, forKey: kvsIntakeKey)
        _ = store.synchronize()
        UserDefaults.standard.set(data, forKey: intakeDefaultsKey)
        #endif
    }

    private static func configureIfPossible(force: Bool = false) async {
        if !force {
            configureLock.lock()
            let already = didStartConfigure
            if !already { didStartConfigure = true }
            configureLock.unlock()
            if already, await LogShip.shared.status().isConfigured { return }
        }
        guard let resolved = resolveIntake() else { return }
        await LogShip.shared.configure(
            collectorURL: resolved.url,
            token: resolved.token,
            source: source
        )
    }

    private static func resolveIntake() -> (url: URL, token: String)? {
        let environment = ProcessInfo.processInfo.environment
        if let url = environment["TIMELINE_LOGDOCK_URL"].flatMap(URL.init(string:)),
           let token = environment["TIMELINE_LOGDOCK_TOKEN"], !token.isEmpty
        {
            return (url, token)
        }

        if let pair = intake(from: UserDefaults.standard.data(forKey: intakeDefaultsKey)) {
            return pair
        }

        let kvs = NSUbiquitousKeyValueStore.default
        _ = kvs.synchronize()
        if let pair = intake(from: kvs.data(forKey: kvsIntakeKey)) {
            UserDefaults.standard.set(kvs.data(forKey: kvsIntakeKey), forKey: intakeDefaultsKey)
            return pair
        }

        #if os(macOS)
        if let token = collectorToken() {
            return (defaultLocalURL, token)
        }
        #endif
        return nil
    }

    private static func intake(from data: Data?) -> (url: URL, token: String)? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let urlString = json["url"], let url = URL(string: urlString),
              let token = json["token"], !token.isEmpty
        else { return nil }
        return (url, token)
    }

    /// LogDock stores its bearer token in plain preferences (not Keychain).
    private static func collectorToken() -> String? {
        CFPreferencesCopyAppValue("LogDock.token" as CFString, "com.logdock.app" as CFString) as? String
    }

    private static func primaryIPv4Address() -> String? {
        var addresses: [String: String] = [:]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let interface = current.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name != "lo0" else { continue }

            var addr = interface.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    getnameinfo(
                        sockaddrPointer,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                }
            }
            guard result == 0 else { continue }
            addresses[name] = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        return addresses["en0"] ?? addresses.values.first
    }
}
