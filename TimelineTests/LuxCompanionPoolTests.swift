import Network
import XCTest
@testable import Timeline

/// `LuxPhotoLink` replaces its client on every reconnect, and a dropped pool used to leave its
/// keep-alive connections open for the life of the process — 173 of them to Lux after four days,
/// enough that Lux could open no new network flow and the phone lost it. These run the real pool
/// over plain TCP against a minimal HTTP server that records what happens to each connection.
final class LuxCompanionPoolTests: XCTestCase {
    private var server: FakeLuxServer!

    override func setUp() async throws {
        server = try await FakeLuxServer.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    func testReleasingThePoolClosesItsConnections() async throws {
        var pool: LuxCompanionHTTPPool? = makePool()
        _ = try await pool?.request(method: "GET", path: "/v1/info", headers: [:])
        XCTAssertEqual(server.acceptedCount, 1)
        XCTAssertEqual(server.closedCount, 0, "a keep-alive connection must stay open while the pool is held")

        pool = nil

        let closed = await server.waitUntil(within: 3) { $0.closedCount == 1 }
        XCTAssertTrue(closed, "releasing the pool must close its connection, not leave it open")
    }

    func testRequestAfterTheServerClosesAnIdleConnectionReconnects() async throws {
        let pool = makePool()
        _ = try await pool.request(method: "GET", path: "/v1/info", headers: [:])

        // What Lux now does to a connection idle for 60s.
        server.closeAllConnections()
        _ = await server.waitUntil(within: 3) { $0.closedCount == 1 }

        let body = try await pool.request(method: "GET", path: "/v1/info", headers: [:])
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{}")
        XCTAssertEqual(server.acceptedCount, 2, "the dead connection must be replaced, not reused")
    }

    private func makePool() -> LuxCompanionHTTPPool {
        LuxCompanionHTTPPool(
            endpoint: .hostPort(host: "127.0.0.1", port: server.port),
            pinnedFingerprint: nil,
            size: 1,
            parameters: { .tcp }
        )
    }
}

/// Answers every request with `200 {}` on a keep-alive connection and counts connections accepted
/// and closed by the client.
private final class FakeLuxServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var accepted = 0
    private var closed = 0

    let port: NWEndpoint.Port

    private init(listener: NWListener, port: NWEndpoint.Port) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> FakeLuxServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let once = NSLock()
            var resumed = false
            listener.stateUpdateHandler = { state in
                once.lock()
                defer { once.unlock() }
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port!)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let server = FakeLuxServer(listener: listener, port: port)
        listener.newConnectionHandler = { [weak server] connection in
            server?.accept(connection)
        }
        return server
    }

    var acceptedCount: Int { lock.withLock { accepted } }
    var closedCount: Int { lock.withLock { closed } }

    func stop() {
        closeAllConnections()
        listener.cancel()
    }

    func closeAllConnections() {
        let open = lock.withLock { connections }
        open.forEach { $0.cancel() }
    }

    func waitUntil(within seconds: TimeInterval, _ condition: (FakeLuxServer) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(self) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition(self)
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            accepted += 1
            connections.append(connection)
        }
        connection.start(queue: .global())
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                self.lock.withLock { self.closed += 1 }
                connection.cancel()
                return
            }
            let terminator = Data("\r\n\r\n".utf8)
            while let end = buffer.range(of: terminator) {
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}"
                connection.send(content: Data(response.utf8), completion: .idempotent)
            }
            self.receive(on: connection, buffer: buffer)
        }
    }
}
