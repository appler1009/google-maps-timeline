import Foundation
import Network

/// The socket half: bytes in, bytes out, nothing else.
///
/// Everything that could be got wrong — who is allowed in, what the protocol
/// says, what the tools do — lives in `MCPService`, which needs no socket to
/// test. This listens on the loopback interface only, so nothing off the machine
/// can reach it at all.
actor MCPServer {
    static let defaultPort: UInt16 = 8787

    private let service: MCPService
    private var listener: NWListener?
    private(set) var port: UInt16?

    init(service: MCPService) {
        self.service = service
    }

    var isRunning: Bool { listener != nil }

    func start(port requested: UInt16 = MCPServer.defaultPort) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // Loopback only. An agent helping with your day has no business being
        // reachable from the network.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: requested) ?? .any
        )
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.note(state) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        self.port = requested
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        TimelineLog.info("mcp server stopped")
    }

    private func note(_ state: NWListener.State) {
        switch state {
        case .ready:
            TimelineLog.info("mcp server listening", ["port": "\(port ?? 0)"])
        case let .failed(error):
            TimelineLog.error("mcp server failed", ["error": "\(error)"])
            listener = nil
            port = nil
        default:
            break
        }
    }

    // MARK: - One request per connection

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        Task { await Self.serve(connection, with: service) }
    }

    private static func serve(_ connection: NWConnection, with service: MCPService) async {
        defer { connection.cancel() }
        var buffer = Data()
        while true {
            guard let chunk = try? await receive(on: connection) else { return }
            guard !chunk.isEmpty else {
                // The peer finished without a whole request; nothing to answer.
                return
            }
            buffer.append(chunk)
            switch MCPHTTP.parse(buffer) {
            case .incomplete:
                continue
            case let .failed(reason):
                _ = try? await send(MCPHTTP.Response.error(400, reason).wireFormat, on: connection)
                return
            case let .complete(request, _):
                let response = await service.handle(request)
                _ = try? await send(response.wireFormat, on: connection)
                return
            }
        }
    }

    private static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
