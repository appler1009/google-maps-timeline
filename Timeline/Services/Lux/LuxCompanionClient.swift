import Foundation
import LuxShared
import Network

struct LuxMacInfo: Codable, Sendable {
    let serverName: String
    let serverInstanceId: String
    let appVersion: String
    let protocolVersion: Int
    let companionEnabled: Bool
    let requiresPairing: Bool
}

struct LuxLibrariesPayload: Codable, Sendable {
    let libraries: [CompanionLibrary]
}

/// Timeline’s Lux Companion client — pair, list open libraries, geo+time query, thumbnails.
struct LuxCompanionClient: Sendable {
    var sessionToken: String?
    /// Keep-alive pool for authenticated traffic (nil during unpaired probing).
    private let pool: LuxCompanionHTTPPool?
    private let endpoint: NWEndpoint
    private let pinnedFingerprint: String?

    init(endpoint: NWEndpoint, sessionToken: String?, pinnedFingerprint: String?) {
        self.endpoint = endpoint
        self.sessionToken = sessionToken
        self.pinnedFingerprint = pinnedFingerprint
        if let pinnedFingerprint, !pinnedFingerprint.isEmpty {
            self.pool = LuxCompanionHTTPPool(
                endpoint: endpoint,
                pinnedFingerprint: pinnedFingerprint,
                size: 4
            )
        } else {
            self.pool = nil
        }
    }

    private var authHeaders: [String: String] {
        guard let sessionToken, !sessionToken.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(sessionToken)"]
    }

    func fetchInfo() async throws -> LuxMacInfo {
        let data = try await get("/v1/info")
        return try decoder().decode(APIResponse<LuxMacInfo>.self, from: data).luxRequireData()
    }

    func pairBegin(deviceId: UUID, deviceName: String) async throws -> PairInitResponse {
        let body = try encoder().encode(
            PairRequest(deviceId: deviceId, deviceName: deviceName, clientVersion: "Timeline", publicKey: nil)
        )
        let data = try await LuxCompanionHTTP.request(
            endpoint: endpoint,
            method: "POST",
            path: "/v1/pair",
            headers: ["Content-Type": "application/json"],
            body: body,
            pinnedFingerprint: nil
        )
        return try decoder().decode(APIResponse<PairInitResponse>.self, from: data).luxRequireData()
    }

    func pairConfirm(
        pairingId: String,
        code: String,
        observedFingerprint: LuxCompanionTLS.FingerprintBox
    ) async throws -> PairSession {
        let body = try encoder().encode(
            PairConfirmRequest(pairingId: pairingId, confirmationCode: code, libraryId: "")
        )
        let data = try await LuxCompanionHTTP.request(
            endpoint: endpoint,
            method: "POST",
            path: "/v1/pair/confirm",
            headers: ["Content-Type": "application/json"],
            body: body,
            pinnedFingerprint: nil,
            captureFingerprint: observedFingerprint
        )
        return try decoder().decode(APIResponse<PairSession>.self, from: data).luxRequireData()
    }

    func fetchLibraries() async throws -> [CompanionLibrary] {
        let data = try await get("/v1/libraries")
        return try decoder().decode(APIResponse<LuxLibrariesPayload>.self, from: data).luxRequireData().libraries
    }

    func queryItems(libraryId: String, request: MediaQueryRequest) async throws -> MediaQueryResponse {
        var headers = authHeaders
        headers["X-Library-Id"] = libraryId
        headers["Content-Type"] = "application/json"
        let body = try encoder().encode(request)
        let data = try await send(
            method: "POST",
            path: "/v1/items/query",
            headers: headers,
            body: body
        )
        return try decoder().decode(APIResponse<MediaQueryResponse>.self, from: data).luxRequireData()
    }

    /// Raw JPEG, or `nil` when Lux has no thumbnail yet (404 envelope).
    func fetchThumbnail(itemId: String, libraryId: String) async throws -> Data? {
        try await fetchRawMedia(
            path: "/v1/items/\(itemId.luxPathEncoded)/thumbnail",
            libraryId: libraryId
        )
    }

    /// Full original bytes (may be slow if Lux must pull from cloud).
    func fetchOriginal(itemId: String, libraryId: String) async throws -> Data? {
        try await fetchRawMedia(
            path: "/v1/items/\(itemId.luxPathEncoded)/original",
            libraryId: libraryId
        )
    }

    private func fetchRawMedia(path: String, libraryId: String) async throws -> Data? {
        var headers = authHeaders
        headers["X-Library-Id"] = libraryId
        let data = try await send(method: "GET", path: path, headers: headers, body: Data())
        if let decoded = try? decoder().decode(APIResponse<String>.self, from: data), !decoded.ok {
            return nil
        }
        return data
    }

    private func get(_ path: String) async throws -> Data {
        try await send(method: "GET", path: path, headers: authHeaders, body: Data())
    }

    private func send(
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        if let pool {
            return try await pool.request(method: method, path: path, headers: headers, body: body)
        }
        return try await LuxCompanionHTTP.request(
            endpoint: endpoint,
            method: method,
            path: path,
            headers: headers,
            body: body,
            pinnedFingerprint: pinnedFingerprint
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
