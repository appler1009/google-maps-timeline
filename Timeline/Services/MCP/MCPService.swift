import Foundation

/// A tool an agent can call, and the shape of what it takes.
struct MCPTool: Sendable {
    var name: String
    var description: String
    /// JSON Schema for the arguments, as MCP clients expect.
    var schema: MCPValue
}

/// What actually does the work. Kept behind a protocol so the protocol layer can
/// be tested without a library behind it.
protocol MCPToolProviding: Sendable {
    func tools() async -> [MCPTool]
    func call(_ name: String, arguments: MCPValue) async throws -> MCPValue
}

struct MCPToolFailure: Error, Equatable {
    var message: String
}

/// Everything the server does, with the socket taken away.
///
/// Routing, pairing and the protocol all live here as one function from request
/// to response, so the parts worth being sure about — that an unpaired agent
/// gets nothing, that a revoked one stops working — are tested directly rather
/// than through a port.
actor MCPService {
    /// What this speaks. MCP clients send their own and take the server's.
    static let protocolVersion = "2025-06-18"

    private var pairing: MCPPairing
    private let tools: MCPToolProviding
    private let onPairingStarted: @Sendable (MCPPairing.Request) -> Void
    private let onClientsChanged: @Sendable ([MCPPairing.Client]) -> Void

    init(
        pairing: MCPPairing = MCPPairing(),
        tools: MCPToolProviding,
        onPairingStarted: @escaping @Sendable (MCPPairing.Request) -> Void = { _ in },
        onClientsChanged: @escaping @Sendable ([MCPPairing.Client]) -> Void = { _ in }
    ) {
        self.pairing = pairing
        self.tools = tools
        self.onPairingStarted = onPairingStarted
        self.onClientsChanged = onClientsChanged
    }

    var pairedClients: [MCPPairing.Client] { pairing.clients }

    func revoke(clientID: String) {
        pairing.revoke(clientID: clientID)
        onClientsChanged(pairing.clients)
    }

    // MARK: - Routing

    func handle(_ request: MCPHTTP.Request, now: Date = Date()) async -> MCPHTTP.Response {
        switch (request.method, request.path) {
        case ("POST", "/pair/start"): return startPairing(request, now: now)
        case ("POST", "/pair/claim"): return claimPairing(request, now: now)
        case ("POST", "/mcp"): return await callMCP(request, now: now)
        case ("GET", "/health"): return .json(["ok": true, "protocol": Self.protocolVersion])
        default: return .error(404, "no such path")
        }
    }

    // MARK: - Pairing

    private func startPairing(_ request: MCPHTTP.Request, now: Date) -> MCPHTTP.Response {
        let body = MCPValue.parse(request.body) ?? .object([:])
        let name = body["client_name"]?.stringValue ?? "An agent"
        let started = pairing.start(clientName: name, now: now)
        // The code is shown on screen, never returned: returning it would make
        // the whole exchange pointless.
        onPairingStarted(started)
        return .json([
            "pairing_id": started.id,
            "expires_in": Int(MCPPairing.codeLifetime),
            "instruction": "Timeline is showing a six-digit code. Ask the person at the Mac to read it out, then call /pair/claim."
        ])
    }

    private func claimPairing(_ request: MCPHTTP.Request, now: Date) -> MCPHTTP.Response {
        let body = MCPValue.parse(request.body) ?? .object([:])
        guard let id = body["pairing_id"]?.stringValue,
              let code = body["code"]?.stringValue else {
            return .error(400, "pairing_id and code are both required")
        }
        do {
            let (token, client) = try pairing.claim(requestID: id, code: code, now: now)
            onClientsChanged(pairing.clients)
            return .json(["token": token, "client_id": client.id, "client_name": client.name])
        } catch let failure as MCPPairing.Failure {
            switch failure {
            case .unknownRequest: return .error(404, "that pairing is not in progress")
            case .expired: return .error(410, "the code expired — start again")
            case .tooManyAttempts: return .error(429, "too many wrong codes — start again")
            case let .wrongCode(left): return .error(401, "wrong code — \(left) attempts left")
            }
        } catch {
            return .error(500, "pairing failed")
        }
    }

    // MARK: - MCP

    private func callMCP(_ request: MCPHTTP.Request, now: Date) async -> MCPHTTP.Response {
        guard let token = request.bearerToken, pairing.authorize(token: token, now: now) != nil else {
            return .error(401, "not paired — call /pair/start")
        }
        onClientsChanged(pairing.clients)
        guard let message = MCPValue.parse(request.body), let method = message["method"]?.stringValue else {
            return .json(Self.rpcError(id: .null, code: -32_700, message: "could not parse that"))
        }
        let id = message["id"] ?? .null

        switch method {
        case "initialize":
            return .json(Self.rpcResult(id: id, result: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": "timeline", "version": "1"])
            ])))

        case "notifications/initialized", "notifications/cancelled":
            // Notifications carry no id and expect no answer.
            return MCPHTTP.Response(status: 202, body: Data())

        case "ping":
            return .json(Self.rpcResult(id: id, result: .object([:])))

        case "tools/list":
            let described = await tools.tools().map { tool in
                MCPValue.object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.schema
                ])
            }
            return .json(Self.rpcResult(id: id, result: .object(["tools": .array(described)])))

        case "tools/call":
            guard let name = message["params"]?["name"]?.stringValue else {
                return .json(Self.rpcError(id: id, code: -32_602, message: "no tool named"))
            }
            let arguments = message["params"]?["arguments"] ?? .object([:])
            do {
                let answer = try await tools.call(name, arguments: arguments)
                return .json(Self.rpcResult(id: id, result: .object([
                    "content": .array([.object([
                        "type": "text",
                        "text": .string(Self.text(answer))
                    ])]),
                    "isError": .bool(false)
                ])))
            } catch let failure as MCPToolFailure {
                // A tool that refuses is not a protocol error: the agent is told
                // what went wrong and can try something else.
                return .json(Self.rpcResult(id: id, result: .object([
                    "content": .array([.object(["type": "text", "text": .string(failure.message)])]),
                    "isError": .bool(true)
                ])))
            } catch {
                return .json(Self.rpcError(id: id, code: -32_603, message: "\(error)"))
            }

        default:
            return .json(Self.rpcError(id: id, code: -32_601, message: "no such method: \(method)"))
        }
    }

    // MARK: - JSON-RPC

    static func rpcResult(id: MCPValue, result: MCPValue) -> Any {
        MCPValue.object(["jsonrpc": "2.0", "id": id, "result": result]).json
    }

    static func rpcError(id: MCPValue, code: Int, message: String) -> Any {
        MCPValue.object([
            "jsonrpc": "2.0",
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)])
        ]).json
    }

    private static func text(_ value: MCPValue) -> String {
        if case let .string(plain) = value { return plain }
        let data = (try? JSONSerialization.data(
            withJSONObject: value.json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
