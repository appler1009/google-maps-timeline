import SwiftUI
import LuxShared

struct LuxPhotosSettingsView: View {
    @Bindable private var link = LuxPhotoLink.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status") {
                        Text(link.statusMessage)
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.trailing)
                    }
                    if link.isPaired {
                        Button("Refresh connection", action: refresh)
                        Button("Unpair Lux", role: .destructive) {
                            link.unpair()
                        }
                    }
                } header: {
                    Text("Lux")
                } footer: {
                    Text("Keep Lux open with the libraries you want Timeline to search. Companion must be enabled in Lux Settings.")
                }

                if !link.isPaired || link.pendingPairingId != nil {
                    pairingSection
                }

                if link.isPaired {
                    librariesSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Lux Photos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                NSLog("[Timeline] LuxPhotosSettingsView appeared")
                TimelineLog.info("lux settings view appeared", [
                    "paired": "\(link.isPaired)",
                    "hosts": "\(link.browser.discovered.count)",
                    "status": link.statusMessage,
                ])
                link.start()
                Task { await link.reconnectIfPossible() }
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 460, idealHeight: 560)
    }

    @ViewBuilder
    private var pairingSection: some View {
        Section("Pair") {
            if link.pendingPairingId != nil {
                Text("Enter the 6-digit code shown in Lux")
                    .foregroundStyle(Palette.muted)
                TextField("Code", text: $link.confirmationCode)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                Button("Confirm") {
                    Task { await link.confirmPairing() }
                }
                .disabled(link.confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 6 || link.isBusy)
            } else if link.browser.discovered.isEmpty {
                Text(link.browser.isSearching ? "Searching for Lux on the local network…" : "No Lux instances found.")
                    .foregroundStyle(Palette.muted)
                Button("Search again") { link.browser.start() }
            } else {
                ForEach(link.browser.discovered) { host in
                    Button {
                        Task { await link.beginPairing(with: host) }
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                            Text(host.name)
                            Spacer()
                            Text("Pair")
                                .foregroundStyle(Palette.water)
                        }
                    }
                    .disabled(link.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var librariesSection: some View {
        Section {
            if link.libraries.isEmpty {
                Text("No open libraries. Open a .lux library window in Lux.")
                    .foregroundStyle(Palette.muted)
            } else {
                ForEach(link.libraries) { library in
                    Toggle(isOn: Binding(
                        get: { link.paired?.linkedLibraryIds.contains(library.id) == true },
                        set: { link.setLibraryLinked(library.id, linked: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(library.displayName)
                            Text(Self.lockCaption(for: library))
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
        } header: {
            Text("Libraries")
        } footer: {
            Text("Timeline queries linked libraries for photos near each visit’s time and location.")
        }
    }

    private func refresh() {
        Task { await link.reconnectIfPossible() }
    }

    /// Lux leaves `isUnlocked == false` for unprotected libraries (no DEK to load). Only
    /// password-protected libraries use Locked/Unlocked; plain libraries are just Open.
    private static func lockCaption(for library: CompanionLibrary) -> String {
        if library.isProtected {
            return library.isUnlocked ? "Unlocked" : "Locked"
        }
        return "Open"
    }
}
