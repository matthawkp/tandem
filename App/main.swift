import AppKit

// One app for both Macs. Which half runs depends on the role chosen on first launch.
CrashGuard.install()
let app = NSApplication.shared
let role = Role.fromArguments(CommandLine.arguments) ?? Role.saved ?? Role.migrated
LoginItem.followMove()
let delegate: NSApplicationDelegate
switch role {
case .extend:
    if #available(macOS 14, *) {
        delegate = SenderApp()
        app.setActivationPolicy(.accessory)
    } else {
        // Saved on a newer macOS, or chosen by a test switch: this Mac can only be a display.
        delegate = RoleChooser()
        app.setActivationPolicy(.regular)
    }
case .display:
    delegate = ReceiverApp()
    app.setActivationPolicy(.regular)
case nil:
    delegate = RoleChooser()
    app.setActivationPolicy(.regular)
}
app.delegate = delegate
app.run()
