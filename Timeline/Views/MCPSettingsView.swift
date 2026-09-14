import SwiftUI

/// The code an agent has to repeat back before it is let in.
///
/// Large, plain, and the only place the code appears — an agent that can read
/// this is a person at the machine, which is the whole point.
struct MCPPairingSheet: View {
    let clientName: String
    let code: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Let \(clientName) in?")
                .font(.system(size: 17, weight: .semibold, design: .serif))
            Text("Read this code back to it. It expires in two minutes.")
                .font(.callout)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)

            Text(spaced)
                .font(.system(size: 40, weight: .medium, design: .monospaced))
                .tracking(4)
                .textSelection(.enabled)
                .accessibilityIdentifier("mcp-pairing-code")

            Text("Until then it can see nothing. Close this and it stays shut out.")
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)

            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 380)
        .dismissesOnEscape(onDismiss)
    }

    /// Grouped in threes, which is how anybody reads six digits aloud.
    private var spaced: String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }
}

/// Turning the server on, and seeing who has been let in.
struct MCPSettingsView: View {
    @State private var controller = MCPController.shared

    var body: some View {
        Section {
            Toggle("Let agents browse and repair this library", isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.isEnabled = $0 }
            ))
            .accessibilityIdentifier("mcp-enabled-toggle")

            if controller.isEnabled {
                LabeledContent("Address") {
                    Text(controller.isRunning ? "127.0.0.1:\(controller.port ?? MCPServer.defaultPort)" : "starting…")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("""
            Reachable only from this Mac. An agent asks to connect, this app shows a \
            six-digit code, and it gets in only if it can repeat the code back.
            """)
            .font(.caption)
            .foregroundStyle(Palette.muted)
        }

        if !controller.clients.isEmpty {
            Section("Paired") {
                ForEach(controller.clients, id: \.id) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.name)
                            Text(lastSeen(client))
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button("Revoke") { controller.revoke(client) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func lastSeen(_ client: MCPPairing.Client) -> String {
        guard let seen = client.lastSeenAt else { return "never used" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "last used \(formatter.localizedString(for: seen, relativeTo: Date()))"
    }
}
