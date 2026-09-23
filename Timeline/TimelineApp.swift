import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct TimelineApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(TimelineAppDelegate.self) private var appDelegate
    #endif

    init() {
        TimelineLog.start()
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            TimelineAppScene()
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Timeline…") {
                    NotificationCenter.default.post(name: .openTimelineRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("iCloud Sync…") {
                    NotificationCenter.default.post(name: .cloudSyncSettingsRequested, object: nil)
                }
                Button("Lux Photos…") {
                    NSLog("[Timeline] lux photos menu command")
                    TimelineLog.info("lux photos menu tapped")
                    NotificationCenter.default.post(name: .luxPhotosSettingsRequested, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        #else
        WindowGroup {
            TimelineAppScene()
        }
        #endif
    }
}

#if os(macOS)
/// XCTest launches on recent macOS can leave SwiftUI's WindowGroup with a menu
/// bar and zero NSWindows — every accessibility query then fails. If the scene
/// has not materialized after a short beat, host the root view ourselves.
final class TimelineAppDelegate: NSObject, NSApplicationDelegate {
    private var fallbackWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.ensureWindow(allowFallback: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.ensureWindow(allowFallback: true)
        }
    }

    private func ensureWindow(allowFallback: Bool) {
        if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            present(window)
            return
        }
        guard allowFallback, TimelineLaunch.isUITesting, fallbackWindow == nil else { return }

        let host = NSHostingController(
            rootView: TimelineAppScene()
                .frame(minWidth: 980, minHeight: 640)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Timeline"
        window.contentViewController = host
        window.isOpaque = true
        window.backgroundColor = .black
        window.setFrameAutosaveName("TimelineUITestFallback")
        window.center()
        fallbackWindow = window
        present(window)
    }

    /// WindowGroup can still wake up after the fallback is showing. Two
    /// windows put every element in the tree twice, and the test may already
    /// be driving the first — so the late one goes. Checked on every pass of
    /// the event loop, since a window opened behind the key one never becomes
    /// key itself; nothing is done until a fallback exists.
    func applicationDidUpdate(_ notification: Notification) {
        guard let fallback = fallbackWindow else { return }
        for window in NSApp.windows where window !== fallback && window.isVisible {
            // A sheet, panel, child, menu, tooltip or popover belongs to the
            // fallback; only a second titled top-level window is WindowGroup
            // arriving late.
            guard window.styleMask.contains(.titled), window.level == .normal,
                  window.sheetParent == nil, window.parent == nil, !(window is NSPanel),
                  window.contentView != nil else { continue }
            window.close()
        }
    }

    private func present(_ window: NSWindow) {
        if TimelineLaunch.isUITesting {
            // Clear + non-opaque windows drop out of the accessibility tree
            // under XCTest — the app shows as Disabled with only a menu bar.
            window.isOpaque = true
            window.backgroundColor = .black
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif

extension Notification.Name {
    static let openTimelineRequested = Notification.Name("openTimelineRequested")
    static let luxPhotosSettingsRequested = Notification.Name("luxPhotosSettingsRequested")
    static let cloudSyncSettingsRequested = Notification.Name("cloudSyncSettingsRequested")
}
