import SwiftUI

struct TimelineAppScene: View {
    @State private var store = TimelineLaunch.isUITesting ? TimelineStore.uiTesting() : TimelineStore()
    #if os(macOS)
    @State private var mcp = MCPController.shared
    #endif
    @State private var importerPresented = false
    @State private var luxSettingsPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #if os(macOS)
    @State private var cloudSettingsPresented = false
    #endif
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingCompactMap = false
    @State private var trackingSettingsPresented = false
    @State private var renamingPlaceID: String?
    #endif

    var body: some View {
        layout
            .environment(store)
            #if os(macOS)
            .background(WindowChrome())
            #endif
            .preferredColorScheme(.dark)
            .fileImporter(
                isPresented: $importerPresented,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { store.open(url: url) }
                case .failure(let error):
                    store.loadError = error.localizedDescription
                }
            }
            #if os(iOS)
            .sheet(isPresented: $trackingSettingsPresented) {
                TrackingSettingsView(store: store)
            }
            .placeRenameSheet(placeID: $renamingPlaceID, store: store)
            .onReceive(NotificationCenter.default.publisher(for: .timelineLibraryChanged)) { _ in
                store.refreshFromLibrary()
            }
            .onReceive(NotificationCenter.default.publisher(for: .visitNameChosen)) { _ in
                applyPendingVisitChoice()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !TimelineLaunch.isUITesting else { return }
                store.refreshIfStale()
                applyPendingVisitChoice()
                Task { await TimelineRecorder.shared.catchUp() }
                CloudSyncController.shared.fetchNow()
            }
            #endif
            #if os(macOS)
            .sheet(isPresented: $cloudSettingsPresented) {
                MacCloudSyncSettingsView()
                    .frame(width: 460, height: 520)
            }
            // An agent asking to be let in interrupts whatever is on screen,
            // because the code is only useful while it is being asked for.
            .sheet(isPresented: Binding(
                get: { mcp.pendingCode != nil },
                set: { if !$0 { mcp.dismissPairing() } }
            )) {
                if let code = mcp.pendingCode {
                    MCPPairingSheet(
                        clientName: mcp.pendingClientName ?? "An agent",
                        code: code
                    ) { mcp.dismissPairing() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .timelineLibraryChanged)) { _ in
                store.refreshFromLibrary()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncSettingsRequested)) { _ in
                cloudSettingsPresented = true
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !TimelineLaunch.isUITesting else { return }
                // Read the library again, not only when an open stay is stale:
                // stays from the phone can sit on disk while the sidebar still
                // ends on an older day.
                store.refreshFromLibrary()
                CloudSyncController.shared.fetchNow()
            }
            #endif
            // A stay still in progress is drawn up to the moment the library was
            // read. Nothing is written while you stay put, so nothing else would
            // redraw it: left open overnight, the Mac showed no today at all.
            // Coming back to the app redraws it, and this tick keeps it current
            // where that is cheap: a Mac on the wall, or the phone app on screen.
            // Nothing redraws at midnight by itself. "Coming back" means the app
            // becoming active: a Mac on battery with Timeline already in front
            // stays active overnight, and shows no today until you switch away
            // and back — clicking its window is not enough.
            .task {
                guard !TimelineLaunch.isUITesting else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    #if os(macOS)
                    // Plugged in, keep current by the clock. On battery, both
                    // wait for the app to become active again, and iCloud's own
                    // notice still fetches.
                    guard PowerSource.isOnWallPower else { continue }
                    CloudSyncController.shared.fetchIfOnWallPower(onWallPower: true)
                    #endif
                    #if os(iOS)
                    // Relaunched in the background for every visit; redrawing a
                    // screen nobody can see is battery spent on nothing.
                    guard UIApplication.shared.applicationState == .active else { continue }
                    #endif
                    store.refreshIfStale()
                }
            }
            .sheet(isPresented: $luxSettingsPresented) {
                LuxPhotosSettingsView()
                    #if os(macOS)
                    .frame(width: 480, height: 560)
                    #endif
            }
            .onAppear {
                TimelineLog.info("timeline scene appeared")
                #if os(macOS)
                NSApp.setActivationPolicy(.regular)
                bringWindowOnscreen()
                #endif
                if !TimelineLaunch.isUITesting {
                    LuxPhotoLink.shared.start()
                    CloudSyncController.shared.startIfEnabled()
                    #if os(macOS)
                    MCPController.shared.startIfEnabled()
                    #endif
                    #if os(iOS)
                    VisitNotifier.shared.start()
                    TimelineRecorder.shared.start()
                    applyPendingVisitChoice()
                    // Catching up is not only for coming back from the
                    // background. onChange(of:) does not fire at launch —
                    // the scene is already active by then — so a cold start,
                    // which is what every rebuild is, would skip it entirely.
                    Task { await TimelineRecorder.shared.catchUp() }
                    #endif
                }
                #if os(iOS)
                if TimelineLaunch.showsTrackingAtLaunch {
                    trackingSettingsPresented = true
                }
                #endif
                Task { @MainActor in
                    await Task.yield()
                    if store.parsed == nil {
                        if TimelineLaunch.shouldLoadFixture {
                            store.loadBundledFixture()
                        } else if !TimelineLaunch.isUITesting {
                            store.restoreLastOpenedFile()
                        } else {
                            // A UI test asking for an empty library: nothing will
                            // load, so say so rather than spin.
                            store.markLibraryChecked()
                        }
                    }
                }
            }
            .onChange(of: LuxPhotoLink.shared.browser.discovered.count) { _, count in
                TimelineLog.info("lux bonjour hosts", ["count": "\(count)"])
                guard !TimelineLaunch.isUITesting else { return }
                Task { await LuxPhotoLink.shared.reconnectIfPossible() }
            }
            .onChange(of: luxSettingsPresented) { _, presented in
                TimelineLog.info("lux settings presented changed", ["presented": "\(presented)"])
            }
            .onOpenURL { url in
                store.open(url: url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTimelineRequested)) { _ in
                importerPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .luxPhotosSettingsRequested)) { _ in
                TimelineLog.info("lux photos notification received")
                presentLuxPhotos(source: "notification")
            }
            #if os(iOS)
            .onChange(of: store.mapRevealGeneration) { _, _ in
                presentCompactMap()
            }
            .onChange(of: store.selectedDayID) { oldValue, newValue in
                if newValue != nil, newValue != oldValue {
                    presentCompactMap()
                }
            }
            .onChange(of: store.selectedPlaceID) { oldValue, newValue in
                if newValue != nil, newValue != oldValue {
                    presentCompactMap()
                }
            }
            #endif
    }

    #if os(iOS)
    /// A tap on a visit notification, applied once the scene exists — the tap may
    /// well be what launched the app.
    private func applyPendingVisitChoice() {
        guard let choice = VisitNotifier.shared.takePendingChoice() else { return }
        if let target = choice.mergeInto {
            store.mergePlace(from: choice.placeKey, into: target)
        } else if let name = choice.name {
            store.applyRecordedPlaceName(name, forPlaceKey: choice.placeKey)
        }
        if choice.opensRenameSheet {
            store.refreshFromLibrary()
            renamingPlaceID = choice.placeKey
        }
    }
    #endif

    private func presentLuxPhotos(source: String) {
        // NSLog so it shows in Console even when LogDock isn't configured yet.
        NSLog("[Timeline] presentLuxPhotos source=%@", source)
        TimelineLog.info("lux photos present requested", ["source": source])
        luxSettingsPresented = true
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            compactStack
        } else {
            splitView
        }
        #else
        splitView
        #endif
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(importerPresented: $importerPresented)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                .navigationTitle("Timeline")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } detail: {
            MapCanvasView()
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .timelineBackgroundExtension()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    cloudSettingsPresented = true
                } label: {
                    Label("iCloud Sync", systemImage: "icloud")
                }
                .help("Receive stays this Mac's companion iPhone recorded")
                .accessibilityLabel("iCloud Sync")
                .accessibilityIdentifier("cloud-sync-settings")
            }
            #endif
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    trackingSettingsPresented = true
                } label: {
                    Label("Tracking", systemImage: "location.circle")
                }
                .help("Record stays and movement on this iPhone")
                .accessibilityLabel("Tracking")
                .accessibilityIdentifier("tracking-settings")
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSLog("[Timeline] lux photos toolbar button tapped")
                    TimelineLog.info("lux photos toolbar tapped")
                    presentLuxPhotos(source: "toolbar")
                } label: {
                    Label("Lux Photos", systemImage: "photo.on.rectangle")
                }
                .help("Link Lux libraries and match photos to visits")
                .accessibilityLabel("Lux Photos")
                .accessibilityIdentifier("lux-photos")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    TimelineLog.info("open timeline toolbar tapped")
                    importerPresented = true
                } label: {
                    Label("Open Timeline", systemImage: "folder")
                }
                .help("Open a Google Maps Timeline JSON export")
                .accessibilityLabel("Open Timeline")
                .accessibilityIdentifier("open-timeline")
            }
        }
    }

    #if os(iOS)
    private var compactStack: some View {
        GeometryReader { geo in
            ZStack {
                NavigationStack {
                    SidebarView(importerPresented: $importerPresented)
                        .navigationTitle("Timeline")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(showingCompactMap ? .hidden : .automatic, for: .navigationBar)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    trackingSettingsPresented = true
                                } label: {
                                    Label("Tracking", systemImage: "location.circle")
                                }
                                .accessibilityLabel("Tracking")
                                .accessibilityIdentifier("tracking-settings")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    presentLuxPhotos(source: "compact-toolbar")
                                } label: {
                                    Label("Lux Photos", systemImage: "photo.on.rectangle")
                                }
                                .accessibilityLabel("Lux Photos")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    importerPresented = true
                                } label: {
                                    Label("Open Timeline", systemImage: "folder")
                                }
                                .accessibilityLabel("Open Timeline")
                                .accessibilityIdentifier("open-timeline")
                            }
                        }
                }
                .offset(x: showingCompactMap ? -geo.size.width * 0.22 : 0)
                .opacity(showingCompactMap ? 0 : 1)
                .allowsHitTesting(!showingCompactMap)
                .accessibilityHidden(showingCompactMap)
                // Keep the map at full size off-screen instead of using a trailing
                // move transition — that animates through 0-width and crashes MapKit
                // under Metal API validation (CAMetalLayer drawable 0×0).
                MapCanvasView()
                    .environment(\.compactMapDismiss, dismissCompactMap)
                    .offset(x: showingCompactMap ? 0 : geo.size.width)
                    .opacity(showingCompactMap ? 1 : 0)
                    .allowsHitTesting(showingCompactMap)
                    .accessibilityHidden(!showingCompactMap)
            }
        }
    }

    private func presentCompactMap() {
        guard horizontalSizeClass == .compact, !showingCompactMap else { return }
        withAnimation(.easeInOut(duration: 0.32)) {
            showingCompactMap = true
        }
    }

    private func dismissCompactMap() {
        withAnimation(.easeInOut(duration: 0.32)) {
            showingCompactMap = false
        }
    }
    #endif
}

#if os(macOS)
import AppKit

private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.apply()
    }
}

private final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        DispatchQueue.main.async { [weak self] in
            self?.apply()
        }
    }

    func apply() {
        guard let window else { return }
        window.title = "Timeline"
        window.subtitle = ""
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .automatic
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
    }
}

private func bringWindowOnscreen() {
    DispatchQueue.main.async {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .automatic
        window.styleMask.insert(.fullSizeContentView)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        let target = NSScreen.main?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1400, height: 900)
        if window.frame.width > target.width * 0.95 || !target.intersects(window.frame) {
            let width = min(1280, target.width - 40)
            let height = min(820, target.height - 40)
            let origin = NSPoint(
                x: target.midX - width / 2,
                y: target.midY - height / 2
            )
            window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
