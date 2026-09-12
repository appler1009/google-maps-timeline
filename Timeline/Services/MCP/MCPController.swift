import Foundation
import SwiftUI

/// Owns the agent-facing server and the state the UI shows about it.
@MainActor
@Observable
final class MCPController {
    static let shared = MCPController()

    /// The code currently on screen, if an agent is waiting to be let in.
    private(set) var pendingCode: String?
    private(set) var pendingClientName: String?
    private(set) var clients: [MCPPairing.Client] = []
    private(set) var port: UInt16?
    private(set) var isRunning = false

    /// Whether an agent may talk to this Mac at all. Off until asked for: a
    /// server nobody is using should not be listening.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private static let enabledKey = "mcpServerEnabled"
    /// Development only: puts the pairing code in the log, so an agent working
    /// without anyone at the machine can still pair. It defeats the point of
    /// showing a code on screen, so it is off unless deliberately switched on:
    ///
    ///     defaults write com.appler.Timeline mcpLogsPairingCode -bool YES
    private static let logsCodeKey = "mcpLogsPairingCode"

    private let store: MCPClientStore
    private var service: MCPService?
    private var server: MCPServer?

    private init(store: MCPClientStore = .standard()) {
        self.store = store
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.clients = store.load()
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func start() {
        guard server == nil else { return }
        let store = store
        let tools = MCPTimelineTools(database: TimelineDatabase()) {
            // A repair changes rows the cloud has already acknowledged, so the
            // library has to be told to look again or it goes nowhere.
            Task { @MainActor in
                NotificationCenter.default.post(name: .timelineLibraryChanged, object: nil)
            }
        }
        let service = MCPService(
            pairing: MCPPairing(clients: clients),
            tools: tools,
            onPairingStarted: { [weak self] request in
                Task { @MainActor in self?.show(request) }
            },
            onClientsChanged: { updated in
                store.save(updated)
                Task { @MainActor in MCPController.shared.clients = updated }
            }
        )
        let server = MCPServer(service: service)
        self.service = service
        self.server = server
        Task {
            do {
                try await server.start()
                let port = await server.port
                await MainActor.run {
                    self.port = port
                    self.isRunning = true
                }
            } catch {
                TimelineLog.error("mcp server could not start", ["error": error.localizedDescription])
                await MainActor.run { self.isRunning = false }
            }
        }
    }

    func stop() {
        let server = server
        self.server = nil
        self.service = nil
        isRunning = false
        port = nil
        pendingCode = nil
        Task { await server?.stop() }
    }

    func revoke(_ client: MCPPairing.Client) {
        guard let service else {
            clients.removeAll { $0.id == client.id }
            store.save(clients)
            return
        }
        Task {
            await service.revoke(clientID: client.id)
            let remaining = await service.pairedClients
            await MainActor.run { self.clients = remaining }
            store.save(remaining)
        }
    }

    func dismissPairing() {
        pendingCode = nil
        pendingClientName = nil
    }

    private func show(_ request: MCPPairing.Request) {
        pendingCode = request.code
        pendingClientName = request.clientName
        if UserDefaults.standard.bool(forKey: Self.logsCodeKey) {
            TimelineLog.info(
                "mcp pairing code",
                ["code": request.code, "client": request.clientName, "developmentOnly": "true"]
            )
        }
        // A code nobody reads should not sit on screen once it has expired.
        let code = request.code
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MCPPairing.codeLifetime * 1_000_000_000))
            if self.pendingCode == code { self.dismissPairing() }
        }
    }
}
