import XCTest
@testable import Timeline

/// The awkward parts of reading a request off a socket, without a socket.
final class MCPHTTPTests: XCTestCase {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    func testReadsAPostWithABody() {
        let raw = bytes("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        guard case let .complete(request, consumed) = MCPHTTP.parse(raw) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.body, bytes("{}"))
        XCTAssertEqual(consumed, raw.count)
    }

    /// A body arrives in pieces. Answering before it is all here would act on
    /// half a request.
    func testWaitsForABodyThatHasNotAllArrived() {
        let head = bytes("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n")
        XCTAssertEqual(MCPHTTP.parse(head), .incomplete)
        XCTAssertEqual(MCPHTTP.parse(head + bytes("12345")), .incomplete)
        guard case .complete = MCPHTTP.parse(head + bytes("1234567890")) else {
            return XCTFail("expected a complete request once the body is whole")
        }
    }

    func testWaitsForHeadersThatHaveNotFinished() {
        XCTAssertEqual(MCPHTTP.parse(bytes("GET /pair HTTP/1.1\r\nHost: x")), .incomplete)
    }

    /// Header names are matched however the client chose to spell them.
    func testHeaderLookupIgnoresCase() {
        let raw = bytes("GET /x HTTP/1.1\r\nAuthorization: Bearer abc123\r\n\r\n")
        guard case let .complete(request, _) = MCPHTTP.parse(raw) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.header("AUTHORIZATION"), "Bearer abc123")
        XCTAssertEqual(request.bearerToken, "abc123")
    }

    func testATokenIsOnlyReadFromABearerHeader() {
        func token(_ header: String) -> String? {
            let raw = bytes("GET /x HTTP/1.1\r\nAuthorization: \(header)\r\n\r\n")
            guard case let .complete(request, _) = MCPHTTP.parse(raw) else { return nil }
            return request.bearerToken
        }
        XCTAssertEqual(token("Bearer abc"), "abc")
        XCTAssertEqual(token("bearer abc"), "abc")
        XCTAssertNil(token("Basic abc"))
        XCTAssertNil(token("abc"))
    }

    /// A client that claims a body larger than anything legitimate is refused
    /// rather than believed.
    func testAnAbsurdBodyLengthIsRefused() {
        let raw = bytes("POST /mcp HTTP/1.1\r\nContent-Length: \(MCPHTTP.maximumBodyBytes + 1)\r\n\r\n")
        XCTAssertEqual(MCPHTTP.parse(raw), .failed("body too large"))
    }

    /// Headers that never end must not be buffered forever.
    func testEndlessHeadersAreRefused() {
        let raw = bytes("GET /x HTTP/1.1\r\n" + String(repeating: "A", count: MCPHTTP.maximumHeaderBytes + 1))
        XCTAssertEqual(MCPHTTP.parse(raw), .failed("headers too long"))
    }

    func testGarbageIsRefusedRatherThanGuessedAt() {
        XCTAssertEqual(MCPHTTP.parse(bytes("nonsense\r\n\r\n")), .failed("malformed request line"))
    }

    func testTheResponseSaysHowLongItIs() {
        let response = MCPHTTP.Response.json(["ok": true])
        let wire = String(data: response.wireFormat, encoding: .utf8) ?? ""
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: \(response.body.count)\r\n"))
        XCTAssertTrue(wire.contains("Connection: close\r\n"))
    }

    func testAnErrorCarriesItsStatus() {
        let response = MCPHTTP.Response.error(401, "pair first")
        XCTAssertEqual(response.status, 401)
        let decoded = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: String]
        XCTAssertEqual(decoded?["error"], "pair first")
    }
}
