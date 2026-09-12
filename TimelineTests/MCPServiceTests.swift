import XCTest
@testable import Timeline

/// The server with the socket taken away: who gets in, and what the protocol
/// answers.
final class MCPServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Records what it was asked, and can be told to refuse.
    private struct StubTools: MCPToolProviding {
        var refuses = false
        let seen = Recorder()

        final class Recorder: @unchecked Sendable {
            private(set) var calls: [(String, MCPValue)] = []
            func record(_ name: String, _ arguments: MCPValue) { calls.append((name, arguments)) }
        }

        func tools() async -> [MCPTool] {
            [MCPTool(name: "day", description: "One day", schema: .object(["type": "object"]))]
        }

        func call(_ name: String, arguments: MCPValue) async throws -> MCPValue {
            seen.record(name, arguments)
            if refuses { throw MCPToolFailure(message: "no such day") }
            return .object(["stays": .array([.string("home")])])
        }
    }

    private func post(_ path: String, _ body: [String: Any], token: String? = nil) -> MCPHTTP.Request {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return MCPHTTP.Request(
            method: "POST",
            path: path,
            headers: headers,
            body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        )
    }

    private func decode(_ response: MCPHTTP.Response) -> MCPValue {
        MCPValue.parse(response.body) ?? .null
    }

    /// The code is shown on the Mac. Returning it to the caller would make the
    /// whole exchange pointless.
    func testStartingAPairingNeverReturnsTheCode() async throws {
        let shown = ShownCode()
        let service = MCPService(tools: StubTools(), onPairingStarted: { shown.set($0.code) })

        let response = await service.handle(post("/pair/start", ["client_name": "Claude Code"]), now: now)
        let body = decode(response)

        XCTAssertNotNil(body["pairing_id"]?.stringValue)
        XCTAssertNotNil(shown.code, "the app is asked to show it")
        let text = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains(shown.code ?? "!"), "and it is not in the answer")
    }

    func testAnAgentThatCannotReadTheScreenGetsNothing() async throws {
        let service = MCPService(tools: StubTools())
        let start = decode(await service.handle(post("/pair/start", [:]), now: now))
        let id = try XCTUnwrap(start["pairing_id"]?.stringValue)

        let refused = await service.handle(post("/pair/claim", ["pairing_id": id, "code": "000000"]), now: now)
        XCTAssertEqual(refused.status, 401)

        let unpaired = await service.handle(post("/mcp", ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]), now: now)
        XCTAssertEqual(unpaired.status, 401, "and the tools stay shut")
    }

    func testARevokedAgentStopsWorking() async throws {
        let shown = ShownCode()
        let service = MCPService(tools: StubTools(), onPairingStarted: { shown.set($0.code) })
        let start = decode(await service.handle(post("/pair/start", [:]), now: now))
        let id = try XCTUnwrap(start["pairing_id"]?.stringValue)
        let code = try XCTUnwrap(shown.code)

        let claimed = decode(await service.handle(post("/pair/claim", ["pairing_id": id, "code": code]), now: now))
        let token = try XCTUnwrap(claimed["token"]?.stringValue)
        let clientID = try XCTUnwrap(claimed["client_id"]?.stringValue)

        let listed = await service.handle(
            post("/mcp", ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], token: token),
            now: now
        )
        XCTAssertEqual(listed.status, 200)

        await service.revoke(clientID: clientID)
        let after = await service.handle(
            post("/mcp", ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: token),
            now: now
        )
        XCTAssertEqual(after.status, 401)
    }

    func testTheHandshakeAnswersWithWhatItSpeaks() async throws {
        let (service, token) = try await paired()
        let response = decode(await service.handle(
            post("/mcp", ["jsonrpc": "2.0", "id": 1, "method": "initialize"], token: token),
            now: now
        ))
        XCTAssertEqual(response["result"]?["protocolVersion"]?.stringValue, MCPService.protocolVersion)
        XCTAssertNotNil(response["result"]?["capabilities"]?["tools"])
    }

    func testToolsAreListedAndCalled() async throws {
        let (service, token) = try await paired()

        let listed = decode(await service.handle(
            post("/mcp", ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], token: token),
            now: now
        ))
        XCTAssertEqual(listed["result"]?["tools"]?.arrayValue?.first?["name"]?.stringValue, "day")

        let called = decode(await service.handle(
            post("/mcp", [
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": "day", "arguments": ["date": "2026-09-11"]]
            ], token: token),
            now: now
        ))
        XCTAssertEqual(called["result"]?["isError"]?.boolValue, false)
        let text = try XCTUnwrap(called["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains("home"))
    }

    /// A tool that refuses is not a broken connection. The agent is told what
    /// went wrong and can try something else.
    func testAToolRefusingIsReportedWithoutBreakingTheCall() async throws {
        let (service, token) = try await paired(tools: StubTools(refuses: true))
        let called = decode(await service.handle(
            post("/mcp", [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "day", "arguments": [:]]
            ], token: token),
            now: now
        ))
        XCTAssertNil(called["error"], "not a protocol failure")
        XCTAssertEqual(called["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(
            called["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
            "no such day"
        )
    }

    func testAnUnknownMethodIsReportedProperly() async throws {
        let (service, token) = try await paired()
        let response = decode(await service.handle(
            post("/mcp", ["jsonrpc": "2.0", "id": 9, "method": "wat"], token: token),
            now: now
        ))
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_601)
        XCTAssertEqual(response["id"]?.intValue, 9)
    }

    // MARK: - Helpers

    private final class ShownCode: @unchecked Sendable {
        private(set) var code: String?
        func set(_ value: String) { code = value }
    }

    private func paired(tools: MCPToolProviding = StubTools()) async throws -> (MCPService, String) {
        let shown = ShownCode()
        let service = MCPService(tools: tools, onPairingStarted: { shown.set($0.code) })
        let start = decode(await service.handle(post("/pair/start", [:]), now: now))
        let id = try XCTUnwrap(start["pairing_id"]?.stringValue)
        let code = try XCTUnwrap(shown.code)
        let claimed = decode(await service.handle(post("/pair/claim", ["pairing_id": id, "code": code]), now: now))
        return (service, try XCTUnwrap(claimed["token"]?.stringValue))
    }
}
