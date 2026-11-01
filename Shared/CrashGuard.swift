import AppKit

/// If Tandem crashes, puts back what it may have changed for the whole Mac, rather than leave it
/// stuck: a pointer held still or hidden (for controlling the other Mac, or being controlled by
/// it), and modifier keys or a button the other Mac was holding down here. macOS itself takes
/// care of the rest when an app dies: hidden Dock and menu bar, event taps, windows, the virtual
/// display. The other Mac lets go of anything this one was holding when the link drops.
enum CrashGuard {
    static func install() {
        for crash in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(crash) { crash in
                CrashGuard.restore()
                // Then crash as usual, so there's still a crash report.
                signal(crash, SIG_DFL)
                raise(crash)
            }
        }
        NSSetUncaughtExceptionHandler { _ in CrashGuard.restore() }
    }

    /// Only what's safe-ish while crashing: plain calls to the window server, no locks of ours.
    private static func restore() {
        CGAssociateMouseAndMouseCursorPosition(1)
        for _ in 0..<4 { CGDisplayShowCursor(CGMainDisplayID()) }
        if let keys = CGEvent(keyboardEventSource: nil, virtualKey: 0x37, keyDown: false) {
            keys.type = .flagsChanged
            keys.flags = []
            keys.post(tap: .cghidEventTap)
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .left),
           let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }
}
