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
}

struct TimelineAppScene: View {
    @StateObject private var store = TimelineStore()
    @State private var importerPresented = false

    var body: some View {
        NavigationSplitView {
            SidebarView(importerPresented: $importerPresented)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            MapCanvasView()
        }
        .environmentObject(store)
        .background(Palette.ink)
        .navigationTitle("Timeline")
        .navigationSubtitle(store.windowSubtitle)
        .background(WindowTitleSync(subtitle: store.windowSubtitle))
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    importerPresented = true
                } label: {
                    Label("Open Timeline", systemImage: "folder")
                }
                .help("Open a Google Maps Timeline JSON export")
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            bringWindowOnscreen()
            if store.parsed == nil {
                store.tryOpenDownloadsExample()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTimelineRequested)) { _ in
            importerPresented = true
        }
    }
}

private struct WindowTitleSync: NSViewRepresentable {
    let subtitle: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.title = "Timeline"
            window.subtitle = subtitle
        }
    }
}

private func bringWindowOnscreen() {
    DispatchQueue.main.async {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
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
