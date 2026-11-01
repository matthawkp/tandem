import AppKit
import Network

/// Each Mac runs Tandem in one of two roles, chosen on first launch.
enum Role: String {
    /// This Mac's desktop extends onto the other Mac's screen (the menu bar app).
    case extend
    /// This Mac's screen shows the other Mac's display (full screen).
    case display

    static var saved: Role? {
        get { UserDefaults.standard.string(forKey: "role").flatMap(Role.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "role") }
    }

    /// Test switches choose the role without changing the saved one.
    static func fromArguments(_ arguments: [String]) -> Role? {
        if arguments.contains(where: { ["--display", "--windowed"].contains($0) }) { return .display }
        if arguments.contains(where: { ["--extend", "--synthetic", "--host"].contains($0) }) { return .extend }
        return nil
    }

    /// FiveK, before it became Tandem, was always the extending side on the MacBook.
    static var migrated: Role? {
        guard UserDefaults.standard.object(forKey: "hasLaunchedBefore") != nil else { return nil }
        saved = .extend
        return .extend
    }

    /// Extending needs macOS 14 (screen capture and virtual displays); a display only needs 11.
    static var canExtend: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    /// Saves the new role and starts again in it.
    static func switchTo(_ role: Role) {
        saved = role
        relaunch()
    }
}

/// Quits and opens again, e.g. so a newly granted permission applies.
func relaunch() {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    try? shell.run()
    NSApp.terminate(nil)
}

/// Suggests a role for this Mac: whatever complements a Tandem already on the cable, or else
/// what suits the hardware.
final class RoleDetector {
    struct Suggestion: Equatable {
        var role: Role
        var reason: String
    }

    var onChange: (Suggestion) -> Void = { _ in }
    private(set) var suggestion: Suggestion
    private var browsers: [NWBrowser] = []

    init() {
        if !Role.canExtend {
            suggestion = Suggestion(role: .display, reason: "Extending needs macOS Sonoma or later; this \(Machine.kind) can be a display.")
        } else if Machine.isLaptop {
            suggestion = Suggestion(role: .extend, reason: "Laptops usually extend onto a bigger screen.")
        } else if Machine.hasBuiltInDisplay {
            suggestion = Suggestion(role: .display, reason: "This \(Machine.kind)'s screen can be a display for another Mac.")
        } else {
            suggestion = Suggestion(role: .extend, reason: "This \(Machine.kind) can use another Mac's screen as its display.")
        }
    }

    func start() {
        watch(Wire.serviceType) { name in
            Suggestion(role: .extend, reason: "\(name) is already set up as a display.")
        }
        watch(Wire.extenderServiceType) { name in
            Suggestion(role: .display, reason: "\(name) is ready to extend onto this Mac.")
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
    }

    /// Only Macs across the Thunderbolt cable, not anyone on a network.
    private func watch(_ type: String, suggest: @escaping (String) -> Suggestion) {
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let wired = results.first { $0.interfaces.contains(where: Wire.isThunderbolt) }
            guard let self, let wired, case .service(let name, _, _, _) = wired.endpoint else { return }
            let suggestion = suggest(name)
            guard suggestion.role == .display || Role.canExtend, suggestion != self.suggestion else { return }
            self.suggestion = suggestion
            self.onChange(suggestion)
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }
}
