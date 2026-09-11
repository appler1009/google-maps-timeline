#if os(iOS)
import SwiftUI
import CoreLocation
import CoreMotion

/// The one screen that decides how much battery the recorder is allowed to spend,
/// and the only place the permission escalation is explained.
struct TrackingSettingsView: View {
    /// Handed in rather than read from the environment: this view is presented in
    /// a sheet, and a sheet gets its own environment on iOS.
    let store: TimelineStore

    @Bindable private var settings = TrackingSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var locationStatus = CLLocationManager().authorizationStatus
    @State private var notificationsAllowed = false
    @State private var motionAllowed = CMMotionActivityManager.authorizationStatus() == .authorized
    @State private var diagnostics = TimelineRecorder.Diagnostics()
    private let modelUnavailableReason = PlaceChooserFactory.unavailableReason()

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

                    Section {
                        Toggle("Smarter place guesses", isOn: $settings.usesOnDeviceModel)
                            .accessibilityIdentifier("tracking-model-toggle")
                        if let reason = modelUnavailableReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                    } header: {
                        Text("On-device intelligence")
                    } footer: {
                        Text("When the nearest places are equally likely, Apple Intelligence picks the one that fits the time of day and how long you stayed. It runs on this iPhone — where you have been never leaves the device.")
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

                    Section {
                        LabeledContent("Recording") {
                            Text(recorder.isRunning ? "On" : "Off")
                                .foregroundStyle(Palette.muted)
                        }
                        LabeledContent("Right now") {
                            Text(openStayLabel)
                                .foregroundStyle(Palette.muted)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Stays recorded today") {
                            Text("\(diagnostics.staysToday)")
                                .foregroundStyle(Palette.muted)
                                .monospacedDigit()
                        }
                    } header: {
                        Text("Status")
                    } footer: {
                        Text("A stay is only written once you leave, so this stays at zero while you are still somewhere.")
                    }

                    Section {
                        counter("Stays, all time", diagnostics.staysTotal)
                        counter("Location fixes today", diagnostics.fixesToday)
                        counter("Location fixes stored", diagnostics.fixesTotal)
                        LabeledContent("Movement read through") {
                            Text(stamp(diagnostics.motionMark))
                                .foregroundStyle(Palette.muted)
                        }
                        LabeledContent("Last fix stored") {
                            Text(stamp(diagnostics.fixMark))
                                .foregroundStyle(Palette.muted)
                        }
                        counter("Rows waiting to sync", diagnostics.pendingSync)
                        Button("Refresh") {
                            Task { diagnostics = await recorder.diagnostics() }
                        }
                    } header: {
                        Text("Raw counts")
                    } footer: {
                        Text("What the recorder has actually collected. If these are all zero while recording is on, nothing is reaching the app.")
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
            .task {
                await refreshPermissions()
                diagnostics = await recorder.diagnostics()
            }
        }
    }

    /// "Somewhere since 09:12" is the answer to "why is today still zero".
    private var openStayLabel: String {
        guard let start = diagnostics.openStayStart else { return "Not at a place yet" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Somewhere since \(formatter.string(from: start))"
    }

    private func counter(_ title: String, _ value: Int) -> some View {
        LabeledContent(title) {
            Text("\(value)")
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
        }
    }

    private func stamp(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
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
