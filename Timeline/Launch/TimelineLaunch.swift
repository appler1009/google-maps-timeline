import Foundation

enum TimelineLaunch {
    static var isUITesting: Bool {
        env("TIMELINE_UI_TESTING") || flag("-UITesting") || flag("UITesting")
    }

    static var shouldLoadFixture: Bool {
        if env("TIMELINE_EMPTY_LIBRARY") || flag("emptyLibrary") { return false }
        return env("TIMELINE_LOAD_FIXTURE") || flag("loadFixture") || isUITesting
    }

    private static func env(_ key: String) -> Bool {
        let value = ProcessInfo.processInfo.environment[key]
        return value == "1" || value == "true" || value == "YES"
    }

    private static func flag(_ name: String) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        let key = name.hasPrefix("-") ? String(name.dropFirst()) : name
        if args.contains(key) || args.contains("-\(key)") { return true }
        if let string = UserDefaults.standard.string(forKey: key) {
            return string == "true" || string == "1" || string == "YES"
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}
