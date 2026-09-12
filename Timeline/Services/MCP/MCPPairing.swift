import Foundation
import CryptoKit

/// Deciding whether an agent is allowed to read and rewrite the library.
///
/// The library is years of precise location history, and the tools that clean it
/// up can also ruin it. Binding to the loopback interface is not protection:
/// anything running as the user can reach a local port. So an agent has to be
/// let in by the person sitting at the machine — it asks, the app shows a code
/// on screen, and the agent only gets a token if it can repeat the code back.
///
/// The token that comes out is stored as a hash. A file holding usable tokens
/// would be worth stealing; a file holding hashes is worth nothing on its own.
struct MCPPairing: Sendable {
    /// Long enough to walk to the machine and read it, short enough that a code
    /// left on screen is not a standing invitation.
    static let codeLifetime: TimeInterval = 2 * 60
    /// Six digits is a million guesses, but a patient attacker only needs to be
    /// lucky once, so the attempt itself is the thing worth limiting.
    static let maximumAttempts = 5

    /// A request in progress: the app is showing `code`, and whoever asked is
    /// holding `id` and waiting to be told what it says.
    struct Request: Equatable, Sendable {
        var id: String
        var clientName: String
        var code: String
        var startedAt: Date
        var attempts: Int = 0

        func isLive(at now: Date) -> Bool {
            attempts < MCPPairing.maximumAttempts
                && now.timeIntervalSince(startedAt) < MCPPairing.codeLifetime
        }
    }

    /// An agent that was let in, kept so it can be seen and revoked.
    struct Client: Codable, Equatable, Sendable {
        var id: String
        var name: String
        /// SHA-256 of the token, never the token.
        var tokenHash: String
        var pairedAt: Date
        var lastSeenAt: Date?
    }

    enum Failure: Error, Equatable {
        case unknownRequest
        case expired
        case tooManyAttempts
        case wrongCode(attemptsLeft: Int)
    }

    private(set) var requests: [String: Request] = [:]
    private(set) var clients: [Client] = []

    init(clients: [Client] = []) {
        self.clients = clients
    }

    // MARK: - Pairing

    /// Begin. The caller shows `code` to the person at the machine.
    mutating func start(
        clientName: String,
        now: Date = Date(),
        id: String = UUID().uuidString,
        code: String = Self.freshCode()
    ) -> Request {
        // Anything that timed out while nobody was looking is not worth keeping.
        requests = requests.filter { $0.value.isLive(at: now) }
        let request = Request(
            id: id,
            clientName: Self.tidy(clientName),
            code: code,
            startedAt: now
        )
        requests[request.id] = request
        return request
    }

    /// Finish, if the code is right. Returns the token, which is shown once and
    /// never stored in a form that could be handed out again.
    mutating func claim(
        requestID: String,
        code: String,
        now: Date = Date(),
        token: String = Self.freshToken()
    ) throws -> (token: String, client: Client) {
        guard var request = requests[requestID] else { throw Failure.unknownRequest }
        guard request.attempts < Self.maximumAttempts else {
            requests[requestID] = nil
            throw Failure.tooManyAttempts
        }
        guard now.timeIntervalSince(request.startedAt) < Self.codeLifetime else {
            requests[requestID] = nil
            throw Failure.expired
        }
        // Compared in constant time: a comparison that gives up at the first
        // wrong digit tells you how many digits were right.
        guard Self.matches(request.code, code) else {
            request.attempts += 1
            let left = Self.maximumAttempts - request.attempts
            if left <= 0 {
                requests[requestID] = nil
                throw Failure.tooManyAttempts
            }
            requests[requestID] = request
            throw Failure.wrongCode(attemptsLeft: left)
        }
        requests[requestID] = nil
        let client = Client(
            id: request.id,
            name: request.clientName,
            tokenHash: Self.hash(token),
            pairedAt: now,
            lastSeenAt: now
        )
        clients.append(client)
        return (token, client)
    }

    // MARK: - Using it

    /// The client this token belongs to, or nil. Also records that it was seen,
    /// so the settings list can say when each agent last called.
    mutating func authorize(token: String, now: Date = Date()) -> Client? {
        let hash = Self.hash(token)
        guard let index = clients.firstIndex(where: { Self.matches($0.tokenHash, hash) }) else {
            return nil
        }
        clients[index].lastSeenAt = now
        return clients[index]
    }

    mutating func revoke(clientID: String) {
        clients.removeAll { $0.id == clientID }
    }

    // MARK: - Pieces

    static func freshCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    static func freshToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant time for equal-length inputs, which is the case that matters.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) { difference |= a ^ b }
        return difference == 0
    }

    private static func tidy(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "An agent" }
        return String(trimmed.prefix(60))
    }
}
