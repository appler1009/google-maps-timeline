import XCTest
@testable import Timeline

/// Letting an agent into years of location history is a decision only the person
/// at the machine can make, so the code on screen is the whole of the security.
/// These are the ways round it that must not work.
final class MCPPairingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnAgentThatRepeatsTheCodeIsLetIn() throws {
        var pairing = MCPPairing()
        let request = pairing.start(clientName: "Claude Code", now: now, code: "123456")
        let (token, client) = try pairing.claim(requestID: request.id, code: "123456", now: now)

        XCTAssertEqual(client.name, "Claude Code")
        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(pairing.authorize(token: token, now: now)?.id, client.id)
    }

    func testTheTokenItselfIsNeverStored() throws {
        var pairing = MCPPairing()
        let request = pairing.start(clientName: "agent", now: now, code: "123456")
        let (token, client) = try pairing.claim(requestID: request.id, code: "123456", now: now)

        XCTAssertNotEqual(client.tokenHash, token)
        XCTAssertEqual(client.tokenHash, MCPPairing.hash(token))
        XCTAssertNil(pairing.authorize(token: client.tokenHash, now: now), "the hash is not a key")
    }

    func testGuessingIsGivenFiveTriesAndNoMore() throws {
        var pairing = MCPPairing()
        let request = pairing.start(clientName: "agent", now: now, code: "123456")

        for attempt in 1..<MCPPairing.maximumAttempts {
            XCTAssertThrowsError(try pairing.claim(requestID: request.id, code: "000000", now: now)) { error in
                XCTAssertEqual(
                    error as? MCPPairing.Failure,
                    .wrongCode(attemptsLeft: MCPPairing.maximumAttempts - attempt)
                )
            }
        }
        XCTAssertThrowsError(try pairing.claim(requestID: request.id, code: "000000", now: now)) { error in
            XCTAssertEqual(error as? MCPPairing.Failure, .tooManyAttempts)
        }
        // And the right code no longer helps: the request is gone.
        XCTAssertThrowsError(try pairing.claim(requestID: request.id, code: "123456", now: now)) { error in
            XCTAssertEqual(error as? MCPPairing.Failure, .unknownRequest)
        }
    }

    /// A code left on screen is not a standing invitation.
    func testACodeGoesStale() throws {
        var pairing = MCPPairing()
        let request = pairing.start(clientName: "agent", now: now, code: "123456")
        let later = now.addingTimeInterval(MCPPairing.codeLifetime + 1)

        XCTAssertThrowsError(try pairing.claim(requestID: request.id, code: "123456", now: later)) { error in
            XCTAssertEqual(error as? MCPPairing.Failure, .expired)
        }
    }

    func testRevokingShutsAnAgentOut() throws {
        var pairing = MCPPairing()
        let request = pairing.start(clientName: "agent", now: now, code: "123456")
        let (token, client) = try pairing.claim(requestID: request.id, code: "123456", now: now)
        XCTAssertNotNil(pairing.authorize(token: token, now: now))

        pairing.revoke(clientID: client.id)
        XCTAssertNil(pairing.authorize(token: token, now: now))
    }

    func testAnUnpairedTokenIsRefused() {
        var pairing = MCPPairing()
        XCTAssertNil(pairing.authorize(token: MCPPairing.freshToken(), now: now))
    }

    /// Two agents are two grants: revoking one must not shut out the other.
    func testAgentsAreLetInSeparately() throws {
        var pairing = MCPPairing()
        let first = pairing.start(clientName: "one", now: now, code: "111111")
        let (firstToken, firstClient) = try pairing.claim(requestID: first.id, code: "111111", now: now)
        let second = pairing.start(clientName: "two", now: now, code: "222222")
        let (secondToken, _) = try pairing.claim(requestID: second.id, code: "222222", now: now)

        pairing.revoke(clientID: firstClient.id)
        XCTAssertNil(pairing.authorize(token: firstToken, now: now))
        XCTAssertNotNil(pairing.authorize(token: secondToken, now: now))
    }

    func testUsingItRecordsWhenTheAgentLastCalled() throws {
        var pairing = MCPPairing()
        let request = pairing.start(clientName: "agent", now: now, code: "123456")
        let (token, _) = try pairing.claim(requestID: request.id, code: "123456", now: now)

        let later = now.addingTimeInterval(3_600)
        XCTAssertEqual(pairing.authorize(token: token, now: later)?.lastSeenAt, later)
    }
}
