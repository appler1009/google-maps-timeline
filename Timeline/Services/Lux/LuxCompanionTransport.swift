import CryptoKit
import Foundation
import LuxShared
import Network
import Security

extension String {
    /// Percent-encode a single path component (item ids may be raw filenames).
    var luxPathEncoded: String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return addingPercentEncoding(withAllowedCharacters: unreserved) ?? self
    }
}

enum LuxCompanionError: LocalizedError {
    case serverError(code: String, message: String)
    case emptyResponse
    case timeout(seconds: UInt64, phase: String)
    case certificateMismatch
    case notConnected

    var errorDescription: String? {
        switch self {
        case .serverError(_, let message): return message
        case .emptyResponse: return "Lux returned no data"
        case .timeout(let seconds, let phase): return "Timed out while \(phase) (\(seconds)s)"
        case .certificateMismatch: return "Lux’s security identity changed — pair again."
        case .notConnected: return "Lux is not connected"
        }
    }
}

extension APIResponse {
    func luxRequireData() throws -> T {
        guard ok, let data else {
            throw LuxCompanionError.serverError(
                code: error?.code ?? "unknown",
                message: error?.message ?? "Unknown error"
            )
        }
        return data
    }
}

enum LuxCompanionTLS {
    final class FingerprintBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        var fingerprint: String? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    static func parameters(pinnedFingerprint: String?, capture: FingerprintBox? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let opts = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(opts, .TLSv12)
        sec_protocol_options_set_verify_block(
            opts,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                guard let fingerprint = leafFingerprint(of: trust) else {
                    complete(false)
                    return
                }
                capture?.fingerprint = fingerprint
                if let pin = pinnedFingerprint {
                    complete(fingerprint == pin)
                } else {
                    complete(true)
                }
            },
            DispatchQueue.global(qos: .userInitiated)
        )
        return NWParameters(tls: tls)
    }

    static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keep-alive HTTP/1.1 pool — reuses TLS connections across queries and thumbnails.
actor LuxCompanionHTTPPool {
    private let channels: [Channel]
    private var next = 0

    init(endpoint: NWEndpoint, pinnedFingerprint: String?, size: Int = 4) {
        channels = (0..<max(1, size)).map { _ in
            Channel(endpoint: endpoint, pinnedFingerprint: pinnedFingerprint)
        }
    }

    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data = Data()
    ) async throws -> Data {
        let index = next % channels.count
        next += 1
        return try await channels[index].request(
            method: method,
            path: path,
            headers: headers,
            body: body
        )
    }

    func invalidate() {
        for channel in channels {
            Task { await channel.invalidate() }
        }
    }
}

/// One serial keep-alive channel (actor = one in-flight request).
private actor Channel {
    private let endpoint: NWEndpoint
    private let pinnedFingerprint: String?
    private var connection: NWConnection?

    init(endpoint: NWEndpoint, pinnedFingerprint: String?) {
        self.endpoint = endpoint
        self.pinnedFingerprint = pinnedFingerprint
    }

    func invalidate() {
        connection?.cancel()
        connection = nil
    }

    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        do {
            return try await send(method: method, path: path, headers: headers, body: body)
        } catch {
            invalidate()
            return try await send(method: method, path: path, headers: headers, body: body)
        }
    }

    private func send(
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        let connection = try await ensureConnection()
        let (response, keepAlive) = try await LuxCompanionHTTP.exchange(
            on: connection,
            method: method,
            path: path,
            headers: headers,
            body: body,
            keepAlive: true
        )
        if !keepAlive {
            invalidate()
        }
        return response
    }

    private func ensureConnection() async throws -> NWConnection {
        if let connection {
            return connection
        }
        let opened = try await LuxCompanionHTTP.open(
            endpoint: endpoint,
            pinnedFingerprint: pinnedFingerprint,
            captureFingerprint: nil
        )
        connection = opened
        return opened
    }
}

/// Minimal HTTP/1.1 over Network.framework for Lux Companion.
enum LuxCompanionHTTP {
    fileprivate static let connectSeconds: UInt64 = 15
    fileprivate static let requestSeconds: UInt64 = 30
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// One-shot request (pairing / fingerprint capture). Closes the connection afterward.
    static func request(
        endpoint: NWEndpoint,
        method: String,
        path: String,
        headers: [String: String],
        body: Data = Data(),
        pinnedFingerprint: String?,
        captureFingerprint: LuxCompanionTLS.FingerprintBox? = nil
    ) async throws -> Data {
        let connection = try await open(
            endpoint: endpoint,
            pinnedFingerprint: pinnedFingerprint,
            captureFingerprint: captureFingerprint
        )
        defer { connection.cancel() }
        let (data, _) = try await exchange(
            on: connection,
            method: method,
            path: path,
            headers: headers,
            body: body,
            keepAlive: false
        )
        return data
    }

    fileprivate static func open(
        endpoint: NWEndpoint,
        pinnedFingerprint: String?,
        captureFingerprint: LuxCompanionTLS.FingerprintBox?
    ) async throws -> NWConnection {
        let params = LuxCompanionTLS.parameters(
            pinnedFingerprint: pinnedFingerprint,
            capture: captureFingerprint
        )
        let isPinned = pinnedFingerprint != nil
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "timeline.lux.http")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = OnceFlag()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if once.fire() { continuation.resume() }
                        case .failed(let error):
                            if once.fire() {
                                if isPinned, case .tls = error {
                                    continuation.resume(throwing: LuxCompanionError.certificateMismatch)
                                } else {
                                    continuation.resume(throwing: error)
                                }
                            }
                        case .cancelled:
                            if once.fire() {
                                continuation.resume(throwing: LuxCompanionError.timeout(seconds: connectSeconds, phase: "connecting"))
                            }
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: connectSeconds * 1_000_000_000)
                throw LuxCompanionError.timeout(seconds: connectSeconds, phase: "connecting")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                connection.cancel()
                group.cancelAll()
                throw error
            }
        }
        return connection
    }

    /// Returns response body and whether the connection may be reused.
    fileprivate static func exchange(
        on connection: NWConnection,
        method: String,
        path: String,
        headers: [String: String],
        body: Data,
        keepAlive: Bool
    ) async throws -> (Data, Bool) {
        var lines = [
            "\(method) \(path) HTTP/1.1",
            "Host: lux",
            keepAlive ? "Connection: keep-alive" : "Connection: close",
            "X-Lux-Protocol-Version: 1",
        ]
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        lines.append("Content-Length: \(body.count)")
        guard var payload = (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8) else {
            throw LuxCompanionError.emptyResponse
        }
        payload.append(body)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // isComplete must stay false for keep-alive TCP — true sends FIN.
            connection.send(
                content: payload,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }

        return try await withThrowingTaskGroup(of: (Data, Bool).self) { group in
            group.addTask {
                try await readResponse(from: connection)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: requestSeconds * 1_000_000_000)
                connection.cancel()
                throw LuxCompanionError.timeout(seconds: requestSeconds, phase: "waiting for Lux")
            }
            guard let result = try await group.next() else { throw LuxCompanionError.emptyResponse }
            group.cancelAll()
            return result
        }
    }

    private static func readResponse(from connection: NWConnection) async throws -> (Data, Bool) {
        var buffer = Data()
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(returning: Data())
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            if chunk.isEmpty {
                throw LuxCompanionError.emptyResponse
            }
            buffer.append(chunk)
            if let parsed = parseResponse(buffer) {
                guard (200...299).contains(parsed.status) else {
                    if let apiError = decodeAPIError(parsed.body) {
                        throw LuxCompanionError.serverError(code: apiError.code, message: apiError.message)
                    }
                    throw LuxCompanionError.serverError(code: "http_\(parsed.status)", message: "HTTP \(parsed.status)")
                }
                let connectionHeader = parsed.headers["connection"]?.lowercased() ?? ""
                let keepAlive = !connectionHeader.contains("close")
                return (parsed.body, keepAlive)
            }
        }
    }

    private static func parseResponse(_ buffer: Data) -> (status: Int, headers: [String: String], body: Data)? {
        guard let headerEnd = buffer.range(of: headerTerminator) else { return nil }
        guard let statusLine = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8)?
            .components(separatedBy: "\r\n").first
        else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        if let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) {
            for line in headerText.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let total = headerEnd.upperBound + length
        guard buffer.count >= total else { return nil }
        return (status, headers, Data(buffer[headerEnd.upperBound..<total]))
    }

    private static func decodeAPIError(_ body: Data) -> APIError? {
        struct Envelope: Decodable { let error: APIError? }
        guard !body.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Envelope.self, from: body))?.error
    }
}

private final class OnceFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
    }
}
