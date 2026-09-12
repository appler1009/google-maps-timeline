import Foundation

/// A JSON value that can cross between the socket and an actor.
///
/// Tool arguments arrive as arbitrary JSON and answers go back as arbitrary
/// JSON, but `[String: Any]` cannot be handed to an actor. This is the same
/// shape with the types written down.
enum MCPValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPValue])
    case object([String: MCPValue])

    // MARK: - Reading

    var stringValue: String? { if case let .string(value) = self { return value }; return nil }
    var doubleValue: Double? {
        switch self {
        case let .number(value): return value
        case let .string(value): return Double(value)
        default: return nil
        }
    }
    var intValue: Int? { doubleValue.map(Int.init) }
    var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .number(value): return value != 0
        default: return nil
        }
    }
    var arrayValue: [MCPValue]? { if case let .array(value) = self { return value }; return nil }
    var objectValue: [String: MCPValue]? { if case let .object(value) = self { return value }; return nil }

    subscript(key: String) -> MCPValue? { objectValue?[key] }

    /// A date given either as seconds since 1970 or as an ISO-8601 string, since
    /// an agent will reasonably reach for either.
    var dateValue: Date? {
        if let seconds = doubleValue { return Date(timeIntervalSince1970: seconds) }
        guard let text = stringValue else { return nil }
        return MCPValue.isoFormatter.date(from: text) ?? MCPValue.dayFormatter.date(from: text)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Crossing the wire

    init(json: Any) {
        switch json {
        case is NSNull: self = .null
        case let value as Bool where CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID():
            self = .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(MCPValue.init(json:)))
        case let value as [String: Any]: self = .object(value.mapValues(MCPValue.init(json:)))
        default: self = .null
        }
    }

    var json: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value == value.rounded() && abs(value) < 1e15 ? Int(value) : value
        case let .string(value): return value
        case let .array(value): return value.map(\.json)
        case let .object(value): return value.mapValues(\.json)
        }
    }

    static func parse(_ data: Data) -> MCPValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return MCPValue(json: object)
    }

    // MARK: - Building

    static func of(_ pairs: [String: MCPValue?]) -> MCPValue {
        .object(pairs.compactMapValues { $0 })
    }
}

extension MCPValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}
