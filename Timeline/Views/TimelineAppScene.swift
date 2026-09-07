import SwiftUI
import AppKit

enum Palette {
    static let ink = Color(red: 0.07, green: 0.11, blue: 0.16)
    static let inkLift = Color(red: 0.11, green: 0.16, blue: 0.22)
    static let rule = Color(red: 0.22, green: 0.30, blue: 0.36)
    static let parchment = Color(red: 0.93, green: 0.89, blue: 0.82)
    static let muted = Color(red: 0.62, green: 0.66, blue: 0.68)
    static let copper = Color(red: 0.72, green: 0.42, blue: 0.22)
    static let water = Color(red: 0.16, green: 0.45, blue: 0.42)
    static let path = Color(red: 0.78, green: 0.36, blue: 0.22)

    static func distance(meters: Double) -> Color {
        let km = max(0, meters / 1000)
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0.22, 0.48, 0.46)),
            (15, (0.32, 0.52, 0.40)),
            (35, (0.58, 0.50, 0.28)),
            (60, (0.72, 0.42, 0.22)),
            (90, (0.80, 0.32, 0.18)),
            (160, (0.86, 0.22, 0.16)),
        ]
        if km <= stops[0].0 {
            let c = stops[0].1
            return Color(red: c.0, green: c.1, blue: c.2)
        }
        for index in 1..<stops.count {
            let (hi, hc) = stops[index]
            let (lo, lc) = stops[index - 1]
            if km <= hi {
                let u = (km - lo) / (hi - lo)
                return Color(
                    red: lc.0 + (hc.0 - lc.0) * u,
                    green: lc.1 + (hc.1 - lc.1) * u,
                    blue: lc.2 + (hc.2 - lc.2) * u
                )
            }
        }
        let c = stops[stops.count - 1].1
        return Color(red: c.0, green: c.1, blue: c.2)
    }
}

struct TimelineAppScene: View {
    @State private var store = TimelineStore()
    @State private var importerPresented = false

    var body: some View {
        HSplitView {
            SidebarView(importerPresented: $importerPresented)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            MapCanvasView()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        .environment(store)
        .background(Palette.ink)
        .background(WindowChrome())
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
            NSApp.setActivationPolicy(.regular)
            bringWindowOnscreen()
            Task { @MainActor in
                await Task.yield()
                if store.parsed == nil {
                    store.restoreLastOpenedFile()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTimelineRequested)) { _ in
            importerPresented = true
        }
    }
}

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
