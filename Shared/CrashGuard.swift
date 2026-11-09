import AppKit

/// If Tandem crashes, puts back what it may have changed for the whole Mac, rather than leave it
/// stuck: a pointer held still or hidden (for controlling the other Mac, or being controlled by
/// it), and modifier keys or a button the other Mac was holding down here. macOS itself takes
/// care of the rest when an app dies: hidden Dock and menu bar, event taps, windows, the virtual
/// display. The other Mac lets go of anything this one was holding when the link drops.
///
/// And if it hangs instead, while it has the pointer held still: a watchdog off the main thread
/// gives the pointer back, and, where Force Quit has been turned off too (a display Mac whose
/// keyboard and mouse are controlling the other Mac), ends the app, as nothing else could.
enum CrashGuard {
    static func install() {
        for crash in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(crash) { crash in
                // Putting things back isn't strictly safe from here (it may wait for a lock the
                // crash was holding), so not for long: after this, macOS ends the app regardless.
                signal(SIGALRM, SIG_DFL)
                alarm(2)
                CrashGuard.restore()
                // Then crash as usual, so there's still a crash report.
                signal(crash, SIG_DFL)
                raise(crash)
            }
        }
        NSSetUncaughtExceptionHandler { _ in CrashGuard.restore() }
        startWatchdog()
    }

    // MARK: Hangs

    /// What Tandem is holding, which someone would be stuck without if it stopped responding.
    enum Hold {
        case nothing
        /// The pointer is held still or hidden, its movements going to the other Mac.
        case pointer
        /// And Force Quit, switching apps and logging out are turned off.
        case everything
    }

    /// Set on the main thread whenever it changes.
    static var holding: Hold {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    private static let lock = NSLock()
    private static var held = Hold.nothing
    private static var lastBeat = DispatchTime.now()
    private static var rescued = false
    private static var beat: Timer?
    private static var watchdog: DispatchSourceTimer?
    /// Seconds without the main thread before the pointer is given back, and before giving up.
    private static let rescueAfter = 5.0, quitAfter = 15.0

    private static func startWatchdog() {
        // The main thread says it's alive, in every run loop mode (menus and alerts included).
        let beat = Timer(timeInterval: 1, repeats: true) { _ in
            lock.withLock {
                lastBeat = .now()
                rescued = false
            }
        }
        RunLoop.main.add(beat, forMode: .common)
        self.beat = beat

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "watchdog", qos: .userInitiated))
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler {
            // Uptime, which stands still while the Mac sleeps: that isn't a hang.
            let (holding, silent, alreadyRescued) = lock.withLock {
                (held, Double(DispatchTime.now().uptimeNanoseconds - lastBeat.uptimeNanoseconds) / 1e9, rescued)
            }
            guard holding != .nothing, silent > rescueAfter else { return }
            if !alreadyRescued {
                lock.withLock { rescued = true }
                log("not responding for \(Int(silent)) s while holding the pointer: giving it back")
                restore()
            }
            if holding == .everything, silent > quitAfter {
                log("still not responding after \(Int(silent)) s, with Force Quit turned off: stopping")
                // As a crash, so there's a report showing where it was stuck. A moment for the log.
                Thread.sleep(forTimeInterval: 0.2)
                abort()
            }
        }
        watchdog.resume()
        self.watchdog = watchdog
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
