import AppKit
import IOKit.pwr_mgt

/// Settings that make this Mac behave like a monitor: on at power-up, straight into Tandem.
enum MonitorMode {
    /// Whether this Mac starts by itself when power returns after a cut.
    static var restartsAfterPowerFailure: Bool {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["-g"]
        let pipe = Pipe()
        pmset.standardOutput = pipe
        guard (try? pmset.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pmset.waitUntilExit()
        return output.split(separator: "\n").contains {
            let parts = $0.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count >= 2 && parts[0] == "autorestart" && parts[1] == "1"
        }
    }

    /// Needs an administrator, so macOS asks for a password.
    static func setRestartsAfterPowerFailure(_ on: Bool) {
        let source = "do shell script \"/usr/bin/pmset -a autorestart \(on ? 1 : 0)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log("couldn't change autorestart: \(error)") }
    }

    /// Automatic login is set in Users & Groups, and needs FileVault off.
    static func openAutomaticLoginSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")!)
    }
}

/// While no Mac is connected, keeps this one awake so one can connect (a sleeping Mac can't
/// be reached over Thunderbolt), then puts it to sleep after the chosen number of minutes.
/// Time spent using this Mac itself doesn't count.
final class DisconnectedSleep {
    /// Minutes; 0 is never.
    static let choices = [1, 5, 15, 30, 60, 0]

    var minutes: Int {
        get { UserDefaults.standard.object(forKey: "sleepAfterDisconnectMinutes") as? Int ?? 15 }
        set { UserDefaults.standard.set(newValue, forKey: "sleepAfterDisconnectMinutes") }
    }

    /// A Mac is connected, or it's asleep and will wake this one with it.
    var paused = false {
        didSet { if oldValue && !paused { since = Date() } }
    }

    private var since = Date()
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    init() {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Tandem is ready for the other Mac" as CFString, &assertion)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.since = Date()
        }
    }

    private func check() {
        guard !paused, minutes > 0 else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let untouched = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard min(Date().timeIntervalSince(since), untouched) >= Double(minutes * 60) else { return }
        log("no Mac connected for \(minutes) min, sleeping")
        since = Date()
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["sleepnow"]
        try? pmset.run()
    }
}
