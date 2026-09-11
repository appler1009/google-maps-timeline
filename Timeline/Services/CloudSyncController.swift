import Foundation
import SwiftUI
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Owns the sync actor and keeps it fed.
///
/// Lives on both platforms: the phone records and sends, the Mac only receives,
/// but the wiring is identical either way.
@MainActor
@Observable
final class CloudSyncController {
    static let shared = CloudSyncController()

    enum Status: Equatable {
        case off
        case starting
        case on
        case failed(String)

        var label: String {
            switch self {
            case .off: return "Off"
            case .starting: return "Starting…"
            case .on: return "On"
            case .failed(let message): return message
            }
        }
    }

    private(set) var status: Status = .off
    private(set) var pendingCount = 0

    private let database: TimelineDatabase
    private let sync: TimelineCloudSync
    private let settings: TrackingSettings
    private var observer: NSObjectProtocol?

    init(
        database: TimelineDatabase = TimelineDatabase(),
        settings: TrackingSettings? = nil
    ) {
        self.database = database
        self.settings = settings ?? TrackingSettings.shared
        self.sync = TimelineCloudSync(database: database)
    }

    /// Called at launch; does nothing unless the user asked for sync.
    func startIfEnabled() {
        guard settings.syncsWithCloud, !TimelineLaunch.isUITesting else { return }
        enable()
    }

    func enable() {
        settings.syncsWithCloud = true
        status = .starting
        observeLibraryChanges()
        Task {
            do {
                try await sync.start()
                status = .on
                await refreshPendingCount()
                // CKSyncEngine keeps its own subscription, but the app still has
                // to be registered before those pushes can arrive. Without this
                // the Mac only learned about changes when it was relaunched.
                #if os(iOS)
                UIApplication.shared.registerForRemoteNotifications()
                #elseif os(macOS)
                NSApplication.shared.registerForRemoteNotifications()
                #endif
            } catch {
                status = .failed(error.localizedDescription)
                TimelineLog.error("cloud sync start failed", ["error": error.localizedDescription])
            }
        }
    }

    func disable() {
        settings.syncsWithCloud = false
        status = .off
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        Task { await sync.stop() }
    }

    /// Push the whole library up. Offered in settings because it is the repair for
    /// anything that ever looks missing on the other device.
    func resyncEverything() {
        Task {
            do {
                try await sync.resyncEverything()
                await refreshPendingCount()
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func fetchNow() {
        Task { try? await sync.fetchNow() }
    }

    private func observeLibraryChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .timelineLibraryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.enqueue()
            }
        }
    }

    private func enqueue() async {
        await sync.enqueuePendingChanges()
        await refreshPendingCount()
    }

    private func refreshPendingCount() async {
        pendingCount = (try? await database.pendingChangeCount()) ?? 0
    }
}

/// Turning sync on, and the two escape hatches for when it looks wrong.
struct CloudSyncSettingsView: View {
    @Bindable private var settings = TrackingSettings.shared
    private let controller = CloudSyncController.shared

    var body: some View {
        Section {
            Toggle("Sync with iCloud", isOn: syncBinding)
                .accessibilityIdentifier("cloud-sync-toggle")
            if settings.syncsWithCloud {
                LabeledContent("Status") {
                    Text(controller.status.label)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Waiting to send") {
                    Text("\(controller.pendingCount)")
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                }
                Button("Fetch now") { controller.fetchNow() }
                Button("Upload everything again") { controller.resyncEverything() }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Stays and trips this iPhone records appear on your other devices. Your timeline stays in your own private iCloud database.")
        }
    }

    private var syncBinding: Binding<Bool> {
        Binding(
            get: { settings.syncsWithCloud },
            set: { $0 ? controller.enable() : controller.disable() }
        )
    }
}

#if os(macOS)
/// The Mac has no tracking screen — it cannot record — so sync gets its own small
/// window, reachable from the toolbar and the File menu.
struct MacCloudSyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                CloudSyncSettingsView()
            }
            .formStyle(.grouped)
            .navigationTitle("iCloud Sync")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
