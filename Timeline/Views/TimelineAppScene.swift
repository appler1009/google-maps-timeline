import SwiftUI

struct TimelineAppScene: View {
    @State private var store = TimelineStore()
    @State private var importerPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingCompactMap = false
    #endif

    var body: some View {
        layout
            .environment(store)
            .background(Palette.ink)
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
                        store.restoreLastOpenedFile()
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
                if horizontalSizeClass == .compact {
                    showingCompactMap = true
                }
            }
            .onChange(of: store.selectedDayID) { oldValue, newValue in
                if horizontalSizeClass == .compact, newValue != nil, newValue != oldValue {
                    showingCompactMap = true
                }
            }
            .onChange(of: store.selectedPlaceID) { oldValue, newValue in
                if horizontalSizeClass == .compact, newValue != nil, newValue != oldValue {
                    showingCompactMap = true
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
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        } detail: {
            MapCanvasView()
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .toolbar(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        #endif
    }

    #if os(iOS)
    private var compactStack: some View {
        Group {
            if showingCompactMap {
                MapCanvasView()
                    .overlay(alignment: .topLeading) {
                        Button {
                            showingCompactMap = false
                        } label: {
                            Label("Dates", systemImage: "chevron.backward")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Palette.parchment)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 16)
                        .padding(.top, 8)
                        .safeAreaPadding(.top)
                        .accessibilityLabel("Back to list")
                    }
            } else {
                SidebarView(importerPresented: $importerPresented)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unifiedCompact
        window.toolbar = nil
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.07, green: 0.11, blue: 0.16, alpha: 1)
        window.isOpaque = true
    }
}

private func bringWindowOnscreen() {
    DispatchQueue.main.async {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.appearance = NSAppearance(named: .darkAqua)
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
