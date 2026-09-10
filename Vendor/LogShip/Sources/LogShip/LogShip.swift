import Foundation

/// Delivery status a host app can read to confirm log shipping is actually working, rather than
/// just hoping — `LogShip` itself never surfaces a failure (see below), so without this there's no
/// way to distinguish "quietly fine" from "quietly broken" short of inspecting the collector
/// directly.
public struct LogShipStatus: Sendable {
  public let isConfigured: Bool
  public let pendingEntries: Int
  public let lastFlushAt: Date?
  /// `nil` until the first flush attempt ever completes (success or failure).
  public let lastFlushSucceeded: Bool?
  /// Set only when `lastFlushSucceeded` is `false` — the HTTP status or error description.
  public let lastFlushError: String?
}

/// Tiny client for shipping log entries to a running LogDock collector over HTTP. Foundation +
/// URLSession only — no dependency on LogDockCore/sqlite/MCP, so an app adopting this doesn't pull
/// in anything beyond what it already links.
///
/// Never throws and never blocks the caller: a logging aid must not be able to affect the host
/// app's behavior. Failures (collector unreachable, bad token, etc.) are dropped silently from the
/// caller's perspective — but recorded internally so `status()` can report them.
public actor LogShip {
  public static let shared = LogShip()

  private var collectorURL: URL?
  private var token: String = ""
  private var source: String = "unknown"
  private var buffer: [IncomingLogEntry] = []
  private var flushTask: Task<Void, Never>?
  private var lastFlushAt: Date?
  private var lastFlushSucceeded: Bool?
  private var lastFlushError: String?

  /// Entries are held here until a flush, so a burst of log calls never blocks on the network.
  private static let maxBatchSize = 20
  private static let flushInterval: TimeInterval = 2.0

  /// Read once, from the host app's own bundle — this module links directly into the caller's
  /// process, so `Bundle.main` here is Lux/LuxCompanion, not some bundle of LogShip's own. Attached
  /// to every entry so a version regression (or "which build is this from") is visible in the
  /// query itself, not something the reader has to separately infer from a timestamp.
  private static let appVersionMetadata: [String: String] = {
    let info = Bundle.main.infoDictionary
    var tags: [String: String] = [:]
    if let version = info?["CFBundleShortVersionString"] as? String { tags["appVersion"] = version }
    if let build = info?["CFBundleVersion"] as? String { tags["appBuild"] = build }
    return tags
  }()

  private init() {}

  /// Call once at app launch. `collectorURL` is the LogDock intake base, e.g.
  /// `http://192.168.1.23:8737`. `source` identifies this app/process in queries (e.g.
  /// `"lux-mac"`, `"lux-companion-ios"`).
  public func configure(collectorURL: URL, token: String, source: String) {
    self.collectorURL = collectorURL
    self.token = token
    self.source = source
    scheduleFlush()
  }

  public func debug(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
    enqueue(level: "debug", message: message(), metadata: metadata)
  }

  public func info(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
    enqueue(level: "info", message: message(), metadata: metadata)
  }

  public func warning(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
    enqueue(level: "warning", message: message(), metadata: metadata)
  }

  public func error(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
    enqueue(level: "error", message: message(), metadata: metadata)
  }

  /// Generic entry point for callers with a dynamic level string (e.g. an existing logging
  /// facade that already has its own `.debug/.info/.warning/.error` API and just wants to also
  /// forward through here).
  public func log(level: String, message: String, metadata: [String: String]? = nil) {
    enqueue(level: level, message: message, metadata: metadata)
  }

  /// Current delivery status — read this from a settings/debug screen to confirm shipping is
  /// actually reaching the collector, rather than only inferring it from the collector's own
  /// stored logs (which, notably, can't show you *this* app's status if delivery itself is broken).
  public func status() -> LogShipStatus {
    LogShipStatus(
      isConfigured: collectorURL != nil,
      pendingEntries: buffer.count,
      lastFlushAt: lastFlushAt,
      lastFlushSucceeded: lastFlushSucceeded,
      lastFlushError: lastFlushError)
  }

  private func enqueue(level: String, message: String, metadata: [String: String]?) {
    guard collectorURL != nil else { return }
    // Caller-supplied keys win on collision — an explicit metadata value is more specific than
    // the ambient app-version tag.
    let merged = Self.appVersionMetadata.merging(metadata ?? [:]) { _, new in new }
    let tags = merged.isEmpty ? nil : merged
    buffer.append(IncomingLogEntry(level: level, message: message, timestamp: Date(), metadata: tags))
    if buffer.count >= Self.maxBatchSize {
      Task { await self.flush() }
    }
  }

  private func scheduleFlush() {
    flushTask?.cancel()
    flushTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(Self.flushInterval * 1_000_000_000))
        await self?.flush()
      }
    }
  }

  private func flush() async {
    guard let collectorURL, !buffer.isEmpty else { return }
    let entries = buffer
    buffer.removeAll()

    var request = URLRequest(url: collectorURL.appendingPathComponent("v1/ingest"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let payload = IngestPayload(source: source, entries: entries)
    guard let body = try? makeEncoder().encode(payload) else {
      recordFlushResult(succeeded: false, error: "failed to encode payload")
      return
    }
    request.httpBody = body
    request.timeoutInterval = 5

    // Best-effort: if this fails, the entries are simply gone. That's the right tradeoff for a
    // debug aid — retrying/queuing indefinitely risks unbounded memory growth if the collector is
    // down for a while. The outcome is still recorded (not re-thrown) so `status()` can report it.
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode
        recordFlushResult(succeeded: false, error: "HTTP \(code.map(String.init) ?? "?")")
        return
      }
      recordFlushResult(succeeded: true, error: nil)
    } catch {
      recordFlushResult(succeeded: false, error: error.localizedDescription)
    }
  }

  private func recordFlushResult(succeeded: Bool, error: String?) {
    lastFlushAt = Date()
    lastFlushSucceeded = succeeded
    lastFlushError = error
  }

  private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

private struct IngestPayload: Encodable {
  let source: String
  let entries: [IncomingLogEntry]
}

/// Mirrors `LogDockCore.IncomingLogEntry` — duplicated here (not shared) so `LogShip` has zero
/// dependency on `LogDockCore`.
struct IncomingLogEntry: Encodable {
  let level: String
  let message: String
  let timestamp: Date?
  let metadata: [String: String]?
}
