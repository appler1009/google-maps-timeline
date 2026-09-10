import SwiftUI

struct TimelineAppScene: View {
    @State private var store = TimelineLaunch.isUITesting ? TimelineStore.uiTesting() : TimelineStore()
    @State private var importerPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingCompactMap = false
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
            .onAppear {
                #if os(macOS)
                NSApp.setActivationPolicy(.regular)
                bringWindowOnscreen()
                #endif
                Task { @MainActor in
                    await Task.yield()
                    if store.parsed == nil {
                        if TimelineLaunch.shouldLoadFixture {
                            store.loadBundledFixture()
                        } else if !TimelineLaunch.isUITesting {
                            store.restoreLastOpenedFile()
                        }
                    }
                }
            }
            .onOpenURL { url in
                store.open(url: url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTimelineRequested)) { _ in
                importerPresented = true
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
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            importerPresented = true
                        } label: {
                            Label("Open Timeline", systemImage: "folder")
                        }
                        .help("Open a Google Maps Timeline JSON export")
                        .accessibilityLabel("Open Timeline")
                        .accessibilityIdentifier("open-timeline")
                    }
                }
        } detail: {
            MapCanvasView()
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .timelineBackgroundExtension()
        }
        .navigationSplitViewStyle(.balanced)
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
                if showingCompactMap {
                    MapCanvasView()
                        .environment(\.compactMapDismiss, dismissCompactMap)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
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
