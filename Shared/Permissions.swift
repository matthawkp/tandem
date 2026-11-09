import AppKit
import AVFoundation
import SwiftUI

/// The permissions Tandem asks for, what each is for, and whether it's been given. Asked for
/// together when Tandem is set up, again when a feature that needs one is turned on, and at the
/// moment of use if it's since been taken away.
enum Permission: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case camera
    /// Asking the Finder to place files brought across, and the Desktop and Downloads folders
    /// they're saved to.
    case files

    var id: String { rawValue }

    /// What each role uses, most important first.
    static func needed(by role: Role) -> [Permission] {
        switch role {
        case .extend: return [.screenRecording, .accessibility, .camera, .files]
        case .display: return [.accessibility] + (AVCaptureDevice.default(for: .video) != nil ? [.camera] : [])
        }
    }

    func title(for role: Role) -> String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .camera: return "Camera"
        case .files: return "Bringing Files Across"
        }
    }

    func detail(for role: Role) -> String {
        switch (self, role) {
        case (.screenRecording, _):
            return "Needed: Tandem copies the other Mac's part of your desktop across the cable. Nothing leaves your two Macs."
        case (.accessibility, .extend):
            return "For the other Mac's keyboard and mouse, brightness keys on the screen with the pointer, and peeking from this keyboard."
        case (.accessibility, .display):
            return "For peeking: clicking through the bubble, and using this Mac from the other Mac's keyboard. Also sends ⌘Tab and Spotlight across."
        case (.camera, .extend):
            return "For Tandem Camera, which switches to whichever camera you're facing."
        case (.camera, .display):
            return "Lets the other Mac use this Mac's camera."
        case (.files, _):
            return "Files pulled through the bubble go where you let go of them: the Finder places them, in your Desktop, Downloads or another folder."
        }
    }

    /// Nil while it's still being found out.
    var isGranted: Bool? {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .files: return Permission.finderStatus
        }
    }

    /// Asks, if macOS still can; otherwise opens the right part of System Settings.
    func request() {
        switch self {
        case .screenRecording:
            // Adds Tandem to the list (and asks, the first time), then opens the right pane.
            CGRequestScreenCaptureAccess()
            openSettings("Privacy_ScreenCapture")
        case .accessibility:
            Accessibility.prompt()
            openSettings("Privacy_Accessibility")
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { granted in log("permissions: camera \(granted ? "allowed" : "refused")") }
            } else {
                openSettings("Privacy_Camera")
            }
        case .files:
            DispatchQueue.global(qos: .userInitiated).async {
                let finder = Permission.askFinder(ifNeeded: true)
                // Reading each folder is what makes macOS ask for it.
                for folder in [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory] {
                    if let url = FileManager.default.urls(for: folder, in: .userDomainMask).first {
                        _ = try? FileManager.default.contentsOfDirectory(atPath: url.path)
                    }
                }
                if finder == false { DispatchQueue.main.async { openSettings("Privacy_Automation") } }
            }
        }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: The Finder

    private static let finderLock = NSLock()
    private static var finderCache: Bool?

    /// The last known answer; finding out can block, so it's refreshed in the background.
    private static var finderStatus: Bool? {
        finderLock.lock()
        defer { finderLock.unlock() }
        return finderCache
    }

    static func refreshFinderStatus() {
        DispatchQueue.global(qos: .utility).async { _ = askFinder(ifNeeded: false) }
    }

    /// Whether Tandem may send the Finder Apple events, asking first if `ifNeeded`. Blocks.
    @discardableResult
    private static func askFinder(ifNeeded ask: Bool) -> Bool? {
        var target = AEAddressDesc()
        let bundle = "com.apple.finder"
        let made = bundle.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &target) }
        guard made == noErr else { return nil }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        // Not asked yet counts as not given; the Finder not running means it can't be known.
        let granted: Bool? = status == noErr ? true : status == OSStatus(procNotFound) ? nil : false
        finderLock.lock()
        finderCache = granted
        finderLock.unlock()
        return granted
    }
}

/// A window listing the permissions a role uses, each with a tick or an Allow button, kept up to
/// date while System Settings is open.
final class PermissionsWindow: NSObject, NSWindowDelegate {
    final class Model: ObservableObject {
        let role: Role
        let permissions: [Permission]
        @Published var granted: [Permission: Bool] = [:]

        init(role: Role) {
            self.role = role
            permissions = Permission.needed(by: role)
            refresh()
        }

        func refresh() {
            Permission.refreshFinderStatus()
            var granted: [Permission: Bool] = [:]
            for permission in permissions { granted[permission] = permission.isGranted ?? false }
            if granted != self.granted { self.granted = granted }
        }
    }

    private let window: NSPanel
    private let model: Model
    private var timer: Timer?
    /// Before System Settings opens: a full-screen Tandem gets out of its way.
    var beforeOpeningSettings: () -> Void = {}

    init(role: Role) {
        model = Model(role: role)
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Tandem Permissions"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.delegate = self
        let view = VStack(alignment: .leading, spacing: 18) {
            Text("Tandem Permissions").font(.system(size: 20, weight: .bold))
            Text("Allow these now so everything works when you need it. You can change them later in System Settings.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PermissionsList(model: model) { [weak self] permission in
                self?.beforeOpeningSettings()
                permission.request()
            }
        }
        .padding(28)
        .frame(width: 500)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
    }

    func show(on screen: NSScreen? = nil) {
        if let frame = (screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        model.refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

/// Each permission with what it's for, and a tick or an Allow button.
struct PermissionsList: View {
    @ObservedObject var model: PermissionsWindow.Model
    let allow: (Permission) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(model.permissions) { permission in
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSImage(named: model.granted[permission] == true ? NSImage.statusAvailableName : NSImage.statusNoneName)!)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(permission.title(for: model.role)).font(.headline)
                        Text(permission.detail(for: model.role))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if model.granted[permission] == true {
                        Text("Allowed").foregroundColor(.secondary)
                    } else {
                        Button("Allow…") { allow(permission) }
                    }
                }
            }
        }
    }
}
