#if os(iOS)
import SwiftUI
import CoreLocation
import CoreMotion

/// The one screen that decides how much battery the recorder is allowed to spend,
/// and the only place the permission escalation is explained.
struct TrackingSettingsView: View {
    @Bindable private var settings = TrackingSettings.shared
    @Environment(TimelineStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var locationStatus = CLLocationManager().authorizationStatus
    @State private var notificationsAllowed = false
    @State private var motionAllowed = CMMotionActivityManager.authorizationStatus() == .authorized

    private let recorder = TimelineRecorder.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(TrackingMode.allCases) { mode in
                        Button {
                            choose(mode)
                        } label: {
                            modeRow(mode)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tracking-mode-\(mode.rawValue)")
                    }
                } header: {
                    Text("Record on this iPhone")
                } footer: {
                    Text("Timeline writes what it records into the same library your Google Takeout exports go into. Opening an export still works either way.")
                }

                if settings.mode.isRecording {
                    Section {
                        Toggle("Ask me to name new places", isOn: $settings.notifiesVisits)
                            .accessibilityIdentifier("tracking-notify-toggle")
                    } footer: {
                        Text("After a stay of ten minutes or more at a place with no name, Timeline sends one notification with its best guesses. Places you have already named stay quiet, and there are never more than three a day.")
                    }

                    Section("Permissions") {
                        permissionRow(
                            title: "Location",
                            detail: locationDetail,
                            isGranted: locationStatus == .authorizedAlways,
                            action: requestLocation
                        )
                        permissionRow(
                            title: "Motion & Fitness",
                            detail: motionAllowed ? "Trips are typed as walking, cycling or driving." : "Needed to tell walking from driving.",
                            isGranted: motionAllowed,
                            action: requestMotion
                        )
                        permissionRow(
                            title: "Notifications",
                            detail: notificationsAllowed ? "Timeline can ask about new places." : "Needed for the place-name prompt.",
                            isGranted: notificationsAllowed,
                            action: requestNotifications
                        )
                    }

                    Section {
                        Toggle("Use Apple Watch workouts", isOn: healthBinding)
                            .accessibilityIdentifier("tracking-health-toggle")
                    } header: {
                        Text("Apple Watch")
                    } footer: {
                        Text("Walks, runs and rides the Watch recorded come in with their exact route, and the cycling distance it logs corrects trips Core Motion read as driving. Timeline only reads this data.")
                    }

                    CloudSyncSettingsView()

                    Section {
                        Toggle("Show imported copies of recorded days", isOn: shadowBinding)
                            .accessibilityIdentifier("tracking-shadow-toggle")
                        Button("Merge exports with recordings now") {
                            store.reconcileLibrary()
                        }
                    } header: {
                        Text("Google Takeout")
                    } footer: {
                        Text("On a day this iPhone recorded, the export's version of the same stays is hidden rather than deleted. Turn this on to see both.")
                    }

                    Section("Status") {
                        LabeledContent("Recording") {
                            Text(recorder.isRunning ? "On" : "Off")
                                .foregroundStyle(Palette.muted)
                        }
                        LabeledContent("Stays this session") {
                            Text("\(recorder.recordedVisitCount)")
                                .foregroundStyle(Palette.muted)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refreshPermissions() }
        }
    }

    private var healthBinding: Binding<Bool> {
        Binding(
            get: { settings.usesHealth },
            set: { wanted in
                guard wanted else {
                    settings.usesHealth = false
                    return
                }
                Task { await recorder.enableHealth() }
            }
        )
    }

    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { store.showsShadowedImports },
            set: { store.showsShadowedImports = $0 }
        )
    }

    private func modeRow(_ mode: TrackingMode) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: settings.mode == mode ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(settings.mode == mode ? Palette.water : Palette.muted)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(mode.title)
                        .foregroundStyle(Palette.parchment)
                    Spacer()
                    Text(mode.batteryLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                }
                Text(mode.detail)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(settings.mode == mode ? [.isButton, .isSelected] : .isButton)
    }

    private func permissionRow(
        title: String,
        detail: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.walk)
                    .accessibilityLabel("Granted")
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var locationDetail: String {
        switch locationStatus {
        case .authorizedAlways: return "Stays are recorded even when Timeline is closed."
        case .authorizedWhenInUse: return "Only while Timeline is open. Allow Always to record stays."
        case .denied, .restricted: return "Turn Location on for Timeline in Settings."
        default: return "Needed to notice where you stop."
        }
    }

    private func choose(_ mode: TrackingMode) {
        settings.mode = mode
        if mode.isRecording {
            requestLocation()
            if !notificationsAllowed, settings.notifiesVisits { requestNotifications() }
            requestMotion()
            recorder.restart()
        } else {
            recorder.stop()
        }
    }

    /// Two steps, never a cold Always prompt: ask for When In Use here, and let
    /// the recorder escalate once the first stay is on screen.
    private func requestLocation() {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            openSettings()
        }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            locationStatus = CLLocationManager().authorizationStatus
        }
    }

    private func requestMotion() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        // The only way to raise the Motion prompt is to ask for data.
        let manager = CMMotionActivityManager()
        manager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, _ in
            motionAllowed = CMMotionActivityManager.authorizationStatus() == .authorized
        }
    }

    private func requestNotifications() {
        Task {
            notificationsAllowed = await VisitNotifier.shared.requestAuthorization()
        }
    }

    private func refreshPermissions() async {
        locationStatus = CLLocationManager().authorizationStatus
        motionAllowed = CMMotionActivityManager.authorizationStatus() == .authorized
        notificationsAllowed = await VisitNotifier.shared.isAuthorized
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
#endif
