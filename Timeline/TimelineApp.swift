import SwiftUI

@main
struct TimelineApp: App {
    var body: some Scene {
        WindowGroup {
            TimelineAppScene()
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)
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
        }
    }
}

extension Notification.Name {
    static let openTimelineRequested = Notification.Name("openTimelineRequested")
}
