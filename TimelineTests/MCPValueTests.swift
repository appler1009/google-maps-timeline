import XCTest
@testable import Timeline

/// JSON in, the same JSON out. The subtle one is that 0 and 1 are numbers.
final class MCPValueTests: XCTestCase {
    private func roundTrip(_ text: String) -> MCPValue? {
        MCPValue.parse(Data(text.utf8))
    }

    /// A Swift Bool cast to CFTypeRef is always a CFBoolean, so asking the
    /// bridged value what it is turned every 0 and 1 into true and false. That
    /// rewrote JSON-RPC request ids, and a client that cannot match its answers
    /// to its questions is broken in a way that looks like nothing at all.
    func testZeroAndOneStayNumbers() {
        XCTAssertEqual(roundTrip("1"), .number(1))
        XCTAssertEqual(roundTrip("0"), .number(0))
        XCTAssertEqual(roundTrip("{\"id\":1}")?["id"]?.intValue, 1)
        XCTAssertEqual(roundTrip("{\"id\":0}")?["id"]?.intValue, 0)
    }

    func testBooleansStayBooleans() {
        XCTAssertEqual(roundTrip("true"), .bool(true))
        XCTAssertEqual(roundTrip("false"), .bool(false))
        XCTAssertEqual(roundTrip("{\"confirm\":true}")?["confirm"]?.boolValue, true)
    }

    func testAnIdSurvivesGoingBackOut() throws {
        let answer = MCPService.rpcResult(id: .number(7), result: .object([:]))
        let data = try JSONSerialization.data(withJSONObject: answer)
        XCTAssertEqual(MCPValue.parse(data)?["id"]?.intValue, 7)

        let stringID = MCPService.rpcResult(id: .string("abc"), result: .object([:]))
        let stringData = try JSONSerialization.data(withJSONObject: stringID)
        XCTAssertEqual(MCPValue.parse(stringData)?["id"]?.stringValue, "abc")
    }

    func testNestingAndNullSurvive() {
        let value = roundTrip("{\"a\":[1,{\"b\":null},\"c\"]}")
        XCTAssertEqual(value?["a"]?.arrayValue?.count, 3)
        XCTAssertEqual(value?["a"]?.arrayValue?[0].intValue, 1)
        XCTAssertEqual(value?["a"]?.arrayValue?[1]["b"], .null)
    }

    func testDatesAreReadHoweverAnAgentWritesThem() {
        XCTAssertNotNil(MCPValue.string("2026-09-11").dateValue)
        XCTAssertNotNil(MCPValue.string("2026-09-11T08:35:00Z").dateValue)
        XCTAssertEqual(MCPValue.number(1_800_000_000).dateValue, Date(timeIntervalSince1970: 1_800_000_000))
    }
}
