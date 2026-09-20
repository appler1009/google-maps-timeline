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
        // Always ask the sidebar to rebuild after a fetch, even when CloudKit
        // reports nothing new. apply() already posts when rows arrive, but a
        // redraw that misses that notification — or a read that raced the
        // write — used to leave the Mac showing yesterday until it was
        // relaunched, while the library on disk already had today.
        //
        // Also push anything still sitting in the local change log. A hand-added
        // stay used to write the log and refresh the phone UI without ever
        // telling the sync engine, so it never left the device.
        Task {
            await sync.enqueuePendingChanges()
            try? await sync.fetchNow()
            await MainActor.run {
                NotificationCenter.default.post(name: .timelineLibraryChanged, object: nil)
            }
        }
    }

    #if os(macOS)
    /// How often a plugged-in Mac asks iCloud for changes on its own, and how
    /// often it rereads the library from disk even when CloudKit is quiet.
    static let wallPowerFetchInterval: TimeInterval = 5 * 60
    private var lastScheduledFetch: Date?

    /// Ask iCloud for changes if the Mac is plugged in and it has been a while.
    ///
    /// iCloud is meant to announce changes, and on the Mac it does so only
    /// sometimes: the phone's evening came through on its own at one point
    /// and sat unfetched for minutes at another, until the window was
    /// clicked. Plugged in, a regular look costs nothing that matters. On
    /// battery the Mac keeps waiting to be told.
    ///
    /// Returns whether this call started a poll interval, so the UI can reread
    /// the library from disk on the same cadence — notifications alone have
    /// left the sidebar on yesterday after today was already written.
    @discardableResult
    func fetchIfOnWallPower(now: Date = Date(), onWallPower: Bool = PowerSource.isOnWallPower) -> Bool {
        guard onWallPower else { return false }
        if let lastScheduledFetch, now.timeIntervalSince(lastScheduledFetch) < Self.wallPowerFetchInterval {
            return false
        }
        lastScheduledFetch = now
        if status == .on {
            fetchNow()
        }
        return true
    }
    #endif

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
                MCPSettingsView()
            }
            .formStyle(.grouped)
            .navigationTitle("Sync & Agents")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .dismissesOnEscape { dismiss() }
    }
}
#endif
