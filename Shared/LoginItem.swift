import Foundation
import ServiceManagement

/// Opening the app at login, through the same mechanism as System Settings → Login Items. Before
/// macOS 13 there's no API for that without a helper app, so a launch agent opens it instead.
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: LaunchAgent.url.path)
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if #available(macOS 13, *) {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } else {
                if enabled { try LaunchAgent.write() } else { try LaunchAgent.remove() }
            }
        } catch {
            log("login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    /// Login items remember where the app was; after it moves or is renamed (FiveK.app became
    /// Tandem.app), register again so login opens this copy.
    static func followMove() {
        let key = "loginItemPath", path = Bundle.main.bundlePath
        guard UserDefaults.standard.string(forKey: key) != path else { return }
        UserDefaults.standard.set(path, forKey: key)
        guard isEnabled else { return }
        if #available(macOS 13, *) { try? SMAppService.mainApp.unregister() }
        setEnabled(true)
    }

    /// Turns it on the first time the app runs; after that it's the user's choice.
    static func enableOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }

    /// ~/Library/LaunchAgents/<bundle identifier>.plist, which opens this copy of the app at login.
    private enum LaunchAgent {
        static var url: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(Bundle.main.bundleIdentifier ?? "Tandem").plist")
        }

        static func write() throws {
            let plist: [String: Any] = [
                "Label": Bundle.main.bundleIdentifier ?? "Tandem",
                "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        }

        static func remove() throws {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }
}
