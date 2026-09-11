import SwiftUI

@main
struct TimelineApp: App {
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

extension Notification.Name {
    static let openTimelineRequested = Notification.Name("openTimelineRequested")
    static let luxPhotosSettingsRequested = Notification.Name("luxPhotosSettingsRequested")
    static let cloudSyncSettingsRequested = Notification.Name("cloudSyncSettingsRequested")
}
