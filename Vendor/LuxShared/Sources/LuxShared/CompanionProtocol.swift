import Foundation

public let CompanionProtocolVersion = 1

// MARK: - Library

public struct CompanionLibrary: Codable, Sendable, Identifiable {
  public let id: String
  public let displayName: String
  public let hasCloudStorage: Bool
  public let isOpen: Bool
  public let itemCount: Int?
  /// Whether this library has password protection enabled at all — `isUnlocked` is only
  /// meaningful when this is true. `false` for a library with no protection.
  public let isProtected: Bool
  /// Current lock state for a protected library. Always `true` for an unprotected library (no
  /// lock to speak of). An upload still succeeds while locked, but lands unencrypted until the
  /// library is next unlocked — the client shows a warning for exactly that combination.
  public let isUnlocked: Bool
  /// Most recent display date among this library's items, if any — auxiliary/informational only
  /// (shown when `recentHashes` finds no match at all), since exact content matching via
  /// `recentHashes` is what actually drives the "uploaded through here" marker now.
  public let latestMediaDate: Date?
  /// Content fingerprints (same `(fileSize, contentHash)` pair the real duplicate check uses) of
  /// this library's most recently added items, newest first, capped at a small count. A client with
  /// local access to the same files can hash its own recent items and match exactly — no timestamp
  /// comparison, so no exposure to EXIF/timezone extraction quirks on either side.
  public let recentHashes: [RecentMediaHash]

  public init(
    id: String, displayName: String, hasCloudStorage: Bool, isOpen: Bool, itemCount: Int?,
    isProtected: Bool = false, isUnlocked: Bool = true, latestMediaDate: Date? = nil,
    recentHashes: [RecentMediaHash] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.hasCloudStorage = hasCloudStorage
    self.isOpen = isOpen
    self.itemCount = itemCount
    self.isProtected = isProtected
    self.isUnlocked = isUnlocked
    self.latestMediaDate = latestMediaDate
    self.recentHashes = recentHashes
  }
}

/// One item's content fingerprint, as reported by `/v1/libraries` — mirrors exactly what
/// `PartialContentHash` computes client-side, so `PartialContentHash.fingerprint(byteLength:
/// contentHash:)` can compare them directly with no format translation.
public struct RecentMediaHash: Codable, Sendable {
  public let contentHash: String
  public let fileSize: Int

  public init(contentHash: String, fileSize: Int) {
    self.contentHash = contentHash
    self.fileSize = fileSize
  }
}

// MARK: - Full-library hash sync

/// `POST /v1/libraries/hashes` request — pages through *every* item's content fingerprint for one
/// library (unlike `CompanionLibrary.recentHashes`, capped at the newest 100), so a client can build
/// a complete on-device index instead of only ever seeing a recent window.
public struct LibraryHashPageRequest: Codable, Sendable {
  public let libraryId: String
  /// Items with a display date after this are returned; `nil` starts a sync from scratch. The
  /// client should pass the max `addedAt` it has already stored for this library.
  public let since: Date?
  public let limit: Int

  public init(libraryId: String, since: Date?, limit: Int) {
    self.libraryId = libraryId
    self.since = since
    self.limit = limit
  }
}

public struct LibraryHashPage: Codable, Sendable {
  public let items: [DatedMediaHash]
  /// True if there are more items after this page — the client should request again with `since`
  /// set to the last item's `addedAt`.
  public let hasMore: Bool

  public init(items: [DatedMediaHash], hasMore: Bool) {
    self.items = items
    self.hasMore = hasMore
  }
}

/// One item's content fingerprint plus the date it's ordered/paged by.
public struct DatedMediaHash: Codable, Sendable {
  public let contentHash: String
  public let fileSize: Int
  public let addedAt: Date

  public init(contentHash: String, fileSize: Int, addedAt: Date) {
    self.contentHash = contentHash
    self.fileSize = fileSize
    self.addedAt = addedAt
  }
}

// MARK: - Favorites

/// `GET /v1/favorites` item — mirrors `LocalMediaItem`'s favorite-relevant fields, not the whole
/// item, since this is a read-only summary for lightweight clients (e.g. a widget's sync pass).
public struct FavoriteItem: Codable, Sendable, Identifiable {
  public let id: String
  public let filename: String
  public let capturedAt: Date?
  /// One of "photo", "livePhoto", "rawPhoto", "video", "dashcam" — see
  /// `CompanionServer.mediaTypeString`.
  public let mediaType: String
  /// Whether `GET /v1/favorites/{id}/thumbnail` can currently serve bytes for this item. A newly
  /// favorited item may not have one yet — a background service generates thumbnails
  /// asynchronously — so a client should tolerate a 404 there and retry later rather than treating
  /// it as a permanent condition.
  public let hasThumbnail: Bool
  /// Reverse-geocoded location (e.g. "Kelowna, Canada"), if the Mac has one for this item. Nil for
  /// items with no GPS data, or that haven't been geocoded yet.
  public let location: String?
  /// Detected face(s) bounding box, computed Mac-side (see `FaceDetectionIndexer`) rather than
  /// on-device — a real photo was confirmed to reliably detect on macOS but not when the exact same
  /// image bytes ran through Vision inside the iOS widget extension. Nil if no face was found, or
  /// detection hasn't run for this item yet.
  public let faceBoundingBox: NormalizedFaceBox?

  public init(
    id: String, filename: String, capturedAt: Date?, mediaType: String, hasThumbnail: Bool,
    location: String? = nil, faceBoundingBox: NormalizedFaceBox? = nil
  ) {
    self.id = id
    self.filename = filename
    self.capturedAt = capturedAt
    self.mediaType = mediaType
    self.hasThumbnail = hasThumbnail
    self.location = location
    self.faceBoundingBox = faceBoundingBox
  }
}

/// Normalized (0...1), top-left-origin bounding box — used for `FavoriteItem.faceBoundingBox`, and
/// as the JSON shape the Mac stores per favorited item (see `FaceDetectionIndexer`). A plain small
/// struct rather than `CGRect` so it round-trips through JSON identically on both the Mac
/// (CoreGraphics `CGRect.union`-derived) and iOS (widget crop math) sides with no platform-specific
/// Codable assumptions.
public struct NormalizedFaceBox: Codable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct FavoritesResponse: Codable, Sendable {
  public let items: [FavoriteItem]

  public init(items: [FavoriteItem]) {
    self.items = items
  }
}

// MARK: - Item query

/// `POST /v1/items/query` request — the geo + time lookup a map/timeline client needs: "what did
/// this library capture near here, then?". Unlike `/v1/favorites` this sees every non-deleted item,
/// so it's gated on the same `read` scope but returns far more; the server caps `limit` and the
/// radius regardless of what's asked for.
public struct MediaQueryRequest: Codable, Sendable {
  /// Inclusive lower bound on the item's display date (the same UTC-normalized date the grid sorts
  /// by — user-edited date, else EXIF, else file creation).
  public let start: Date
  /// Exclusive upper bound on the display date.
  public let end: Date
  public let latitude: Double
  public let longitude: Double
  /// Great-circle distance from (`latitude`, `longitude`) an item's GPS fix must be within.
  /// Items with no GPS never match. Server-capped (see `CompanionServer.maxQueryRadiusMeters`).
  public let radiusMeters: Double
  /// Page size. Server-clamped; omit to take the server default.
  public let limit: Int?
  /// Opaque `nextCursor` from the previous page. Only meaningful with the identical filter values —
  /// it encodes a position in this query's ordering, not a snapshot of the library.
  public let cursor: String?
  /// Restrict to these `QueriedMediaItem.mediaType` values; nil or empty means every type.
  public let mediaTypes: [String]?

  public init(
    start: Date, end: Date, latitude: Double, longitude: Double, radiusMeters: Double,
    limit: Int? = nil, cursor: String? = nil, mediaTypes: [String]? = nil
  ) {
    self.start = start
    self.end = end
    self.latitude = latitude
    self.longitude = longitude
    self.radiusMeters = radiusMeters
    self.limit = limit
    self.cursor = cursor
    self.mediaTypes = mediaTypes
  }
}

/// One `/v1/items/query` result. Deliberately the same shape of summary as `FavoriteItem` (id,
/// filename, date, type, thumbnail availability) plus the coordinates that made it match, so a
/// client can place it on a map without a second round trip per item.
public struct QueriedMediaItem: Codable, Sendable, Identifiable {
  public let id: String
  public let filename: String
  /// Display date — the value `start`/`end` filtered on. Never nil in practice for a queried item
  /// (it's what ordering is built from), but optional to mirror `FavoriteItem.capturedAt`.
  public let capturedAt: Date?
  /// One of "photo", "livePhoto", "rawPhoto", "video", "dashcam".
  public let mediaType: String
  public let latitude: Double?
  public let longitude: Double?
  /// Metres from the query centre — lets a client rank or tighten the radius client-side.
  public let distanceMeters: Double?
  /// Full reverse-geocoded string if the Mac has one (not the shortened form `FavoriteItem`
  /// carries), or nil if the item hasn't been geocoded.
  public let geocode: String?
  /// Whether `GET /v1/items/{id}/thumbnail` can serve bytes right now — thumbnails are generated
  /// in the background, so `false` is a "retry later", not a permanent state.
  public let hasThumbnail: Bool

  public init(
    id: String, filename: String, capturedAt: Date?, mediaType: String,
    latitude: Double?, longitude: Double?, distanceMeters: Double?, geocode: String?,
    hasThumbnail: Bool
  ) {
    self.id = id
    self.filename = filename
    self.capturedAt = capturedAt
    self.mediaType = mediaType
    self.latitude = latitude
    self.longitude = longitude
    self.distanceMeters = distanceMeters
    self.geocode = geocode
    self.hasThumbnail = hasThumbnail
  }
}

public struct MediaQueryResponse: Codable, Sendable {
  /// Oldest first, tie-broken by id — the order a visit reads in.
  public let items: [QueriedMediaItem]
  /// Pass back as `MediaQueryRequest.cursor` for the next page; nil when this page is the last.
  public let nextCursor: String?

  public init(items: [QueriedMediaItem], nextCursor: String?) {
    self.items = items
    self.nextCursor = nextCursor
  }
}

// MARK: - Pairing

public struct PairRequest: Codable, Sendable {
  public let deviceId: UUID
  public let deviceName: String
  public let clientVersion: String
  public let publicKey: String?

  public init(deviceId: UUID, deviceName: String, clientVersion: String, publicKey: String?) {
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.clientVersion = clientVersion
    self.publicKey = publicKey
  }
}

public struct PairInitResponse: Codable, Sendable {
  public let pairingId: String
  public let expiresInSeconds: Int

  public init(pairingId: String, expiresInSeconds: Int) {
    self.pairingId = pairingId
    self.expiresInSeconds = expiresInSeconds
  }
}

public struct PairConfirmRequest: Codable, Sendable {
  public let pairingId: String
  public let confirmationCode: String
  public let libraryId: String

  public init(pairingId: String, confirmationCode: String, libraryId: String) {
    self.pairingId = pairingId
    self.confirmationCode = confirmationCode
    self.libraryId = libraryId
  }
}

public struct PairSession: Codable, Sendable {
  public let sessionToken: String
  public let expiresAt: Date
  public let refreshExpiresAt: Date
  public let grantedScopes: [String]
  public let library: CompanionLibrary
  public let tlsFingerprint: String

  public init(
    sessionToken: String, expiresAt: Date, refreshExpiresAt: Date,
    grantedScopes: [String], library: CompanionLibrary, tlsFingerprint: String
  ) {
    self.sessionToken = sessionToken
    self.expiresAt = expiresAt
    self.refreshExpiresAt = refreshExpiresAt
    self.grantedScopes = grantedScopes
    self.library = library
    self.tlsFingerprint = tlsFingerprint
  }
}

// MARK: - Upload

public enum UploadFileRole: String, Codable, Sendable {
  case original
  case edited
  case liveCompanion
}

public struct UploadManifestFile: Codable, Sendable {
  public let partName: String
  public let filename: String
  public let role: UploadFileRole
  public let capturedAt: Date?
  public let byteLength: Int64
  public let contentHash: String?
  public let contentType: String?

  public init(
    partName: String, filename: String, role: UploadFileRole,
    capturedAt: Date?, byteLength: Int64, contentHash: String?, contentType: String?
  ) {
    self.partName = partName
    self.filename = filename
    self.role = role
    self.capturedAt = capturedAt
    self.byteLength = byteLength
    self.contentHash = contentHash
    self.contentType = contentType
  }
}

public struct UploadManifestItem: Codable, Sendable {
  public let clientItemId: String
  public let groupId: String
  public let files: [UploadManifestFile]

  public init(clientItemId: String, groupId: String, files: [UploadManifestFile]) {
    self.clientItemId = clientItemId
    self.groupId = groupId
    self.files = files
  }
}

public struct UploadManifest: Codable, Sendable {
  public let uploadId: UUID
  public let items: [UploadManifestItem]

  public init(uploadId: UUID, items: [UploadManifestItem]) {
    self.uploadId = uploadId
    self.items = items
  }
}

public struct UploadCheckRequest: Codable, Sendable {
  public let libraryId: String
  public let byteLength: Int
  public let contentHash: String

  public init(libraryId: String, byteLength: Int, contentHash: String) {
    self.libraryId = libraryId
    self.byteLength = byteLength
    self.contentHash = contentHash
  }
}

public struct UploadCheckResult: Codable, Sendable {
  public let duplicate: Bool

  public init(duplicate: Bool) {
    self.duplicate = duplicate
  }
}

// MARK: - Error codes

/// Stable `APIError.code` values the client branches on. Strings (not an enum) so an older client
/// tolerates codes it doesn't know.
public enum CompanionErrorCode {
  /// Missing or invalid bearer token on a protected endpoint.
  public static let unauthorized = "unauthorized"
  /// The pairing id is unknown or its short-lived window elapsed.
  public static let pairingExpired = "pairing_expired"
  /// The confirmation code did not match the pending pairing.
  public static let badCode = "bad_code"
  /// The bearer token is valid but its device wasn't granted the scope the route requires.
  public static let insufficientScope = "insufficient_scope"
  /// Too many wrong confirmation-code attempts; the pairing was dropped before its TTL.
  public static let tooManyAttempts = "too_many_attempts"
  /// The request decoded but its values don't describe a usable query (empty/backwards time window,
  /// out-of-range coordinates, non-positive radius, unusable cursor).
  public static let invalidQuery = "invalid_query"
}

// MARK: - API envelope

public struct APIError: Codable, Sendable {
  public let code: String
  public let message: String
  public let details: [String: String]?

  public init(code: String, message: String, details: [String: String]? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }
}

public struct APIResponse<T: Codable & Sendable>: Codable, Sendable {
  public let ok: Bool
  public let protocolVersion: Int
  public let data: T?
  public let error: APIError?

  public init(ok: Bool, protocolVersion: Int, data: T?, error: APIError?) {
    self.ok = ok
    self.protocolVersion = protocolVersion
    self.data = data
    self.error = error
  }
}
