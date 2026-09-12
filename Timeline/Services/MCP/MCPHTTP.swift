import Foundation

/// Just enough HTTP to be talked to over the loopback interface.
///
/// Not a web server. It answers a handful of paths for one client at a time on
/// 127.0.0.1, so the whole surface is: read a request, answer it, close. Parsing
/// is kept separate from the socket so the awkward parts — a body split across
/// packets, a header line that never ends — can be tested without one.
enum MCPHTTP {
    /// Bigger than any tool call has cause to be, and small enough that a
    /// confused client cannot exhaust memory.
    static let maximumBodyBytes = 4 * 1024 * 1024
    static let maximumHeaderBytes = 64 * 1024

    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        /// Header lookup is case-insensitive; the wire is not consistent.
        func header(_ name: String) -> String? { headers[name.lowercased()] }

        var bearerToken: String? {
            guard let value = header("authorization") else { return nil }
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
            return String(parts[1])
        }
    }

    struct Response {
        var status: Int
        var body: Data
        var contentType = "application/json"

        static func json(_ object: Any, status: Int = 200) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(status: status, body: body)
        }

        static func error(_ status: Int, _ message: String) -> Response {
            json(["error": message], status: status)
        }

        var wireFormat: Data {
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
            // One request per connection: no keep-alive bookkeeping to get wrong.
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + body
        }

        private static func reason(_ status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 413: return "Payload Too Large"
            case 429: return "Too Many Requests"
            default: return "Internal Server Error"
            }
        }
    }

    enum ParseResult: Equatable {
        /// Nothing wrong, just not all here yet.
        case incomplete
        case complete(Request, consumed: Int)
        case failed(String)
    }

    /// Read one request out of whatever has arrived so far.
    static func parse(_ buffer: Data) -> ParseResult {
        guard let separator = range(of: Data("\r\n\r\n".utf8), in: buffer) else {
            if buffer.count > maximumHeaderBytes { return .failed("headers too long") }
            return .incomplete
        }
        let headSize = separator.lowerBound - buffer.startIndex
        guard headSize <= maximumHeaderBytes else { return .failed("headers too long") }
        guard let head = String(data: buffer.subdata(in: buffer.startIndex..<separator.lowerBound), encoding: .utf8) else {
            return .failed("headers are not text")
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .failed("no request line") }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .failed("malformed request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maximumBodyBytes else { return .failed("body too large") }
        let bodyStart = separator.upperBound
        let available = buffer.endIndex - bodyStart
        guard available >= length else { return .incomplete }

        return .complete(
            Request(
                method: String(requestLine[0]).uppercased(),
                path: String(requestLine[1]),
                headers: headers,
                body: buffer.subdata(in: bodyStart..<(bodyStart + length))
            ),
            consumed: (bodyStart - buffer.startIndex) + length
        )
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.endIndex - needle.count
        var index = haystack.startIndex
        while index <= last {
            if haystack[index..<(index + needle.count)] == needle {
                return index..<(index + needle.count)
            }
            index += 1
        }
        return nil
    }
}
