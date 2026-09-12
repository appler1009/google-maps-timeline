import Foundation

/// Remembers which agents were let in, across launches.
///
/// Beside the library rather than in it: this is about who may look, which is
/// not part of the timeline and has no business syncing to the phone.
struct MCPClientStore: Sendable {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func standard() -> MCPClientStore {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Timeline", isDirectory: true)
        return MCPClientStore(fileURL: folder.appendingPathComponent("mcp-clients.json"))
    }

    func load() -> [MCPPairing.Client] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([MCPPairing.Client].self, from: data)) ?? []
    }

    func save(_ clients: [MCPPairing.Client]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(clients) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Readable only by this user. The container is already protected, but a
        // file about access should not be the loosest thing in it.
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
