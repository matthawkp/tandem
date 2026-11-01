import AppKit

/// Peeking: a bubble through the other Mac's picture to this Mac's own desktop, opened by holding
/// Control-Option on either Mac's keyboard, and stepping through it to use this Mac. One object
/// owns all of it, so the window, the pointer, the click tap and the other Mac are always set up
/// and put back together, however it ends.
///
/// With Accessibility, clicks go through the open bubble: the window lets the mouse through and
/// this Mac's own pointer sits in the bubble, moved by its own mouse or by the other Mac's
/// trackpad. Without it, the bubble is only for looking, and follows whichever pointer is in use.
final class PeekSession {
    enum Origin: Equatable {
        /// Held on this Mac's keyboard. `resumes`: it was controlling the other Mac, which carries
        /// on when the bubble closes.
        case here(resumes: Bool)
        /// Asked for by the other Mac. `drives`: its trackpad works this Mac's pointer.
        case mac(drives: Bool)
    }

    private enum Phase: Equatable {
        case closed
        /// `through`: clicks go through to this Mac's desktop.
        case open(Origin, through: Bool)
        /// Spreading to fill the screen, on the way to `away`. However it was opened, once through,
        /// both Macs' keyboards work this Mac: its own directly, and the other Mac's (`macDrives`)
        /// played here, given Accessibility.
        /// `resumes`: this Mac was controlling the other Mac before, and does again on coming back.
        case spreading(macDrives: Bool, resumes: Bool)
        /// Stepped through: this Mac's desktop, with the picture hidden.
        case away(macDrives: Bool, resumes: Bool)

        /// The other Mac's keyboard and trackpad work this Mac.
        var macDrives: Bool {
            switch self {
            case .open(.mac(true), _), .spreading(true, _), .away(true, _): return true
            default: return false
            }
        }
    }

    // MARK: Set up by the app

    /// Sends a peek message to the other Mac.
    var send: (Data) -> Void = { _ in }
    var isStreaming: () -> Bool = { false }
    var setCursorHidden: (Bool) -> Void = { _ in }
    /// Full screen again after this Mac's desktop.
    var restoreFullScreen: () -> Void = {}
    /// Whether the other Mac's pointer moved more recently than this Mac's own, so a peek from
    /// this keyboard opens around the pointer in use.
    var macPointerMovedLast = false

    private let window: NSWindow
    private let picture: NSView
    private let portal: Portal
    private let overlay: CursorOverlay
    private let input: InputCapture
    private let player = InputPlayer()
    private let playerQueue: DispatchQueue

    private var phase = Phase.closed {
        didSet { if phase.macDrives != oldValue.macDrives { setMacDrives(phase.macDrives) } }
    }
    /// Something was dragged out of the bubble: it stays where it is, rather than chasing the
    /// pointer back, until the pointer goes back into it for something else.
    private var parked = false
    /// Control-Option was let go mid-drag: the bubble closes once the button is up, so the drag
    /// can finish first.
    private var closesWhenButtonUp = false
    private var timer: Timer?
    /// While clicks go through: takes Control and Option off them (they'd be right-clicks), and
    /// spots double-clicks.
    private lazy var clickTap = EventTap { [unowned self] _, event in
        event.flags.remove(.peekKeys)
        if event.isDoubleClick { DispatchQueue.main.async { self.doubleClicked() } }
        return event
    }
    private var comeBackMonitor: Any?
    private var comeBackHold: DispatchWorkItem?

    init(window: NSWindow, picture: NSView, overlay: CursorOverlay, input: InputCapture, playerQueue: DispatchQueue) {
        self.window = window
        self.picture = picture
        self.overlay = overlay
        self.input = input
        self.playerQueue = playerQueue
        portal = Portal(window: window, picture: picture.layer!, host: overlay.layer!)
    }

    var isAway: Bool {
        if case .away = phase { return true }
        return false
    }

    // MARK: Ways in

    /// Control-Option held on this Mac's keyboard.
    func heldHere() {
        guard phase == .closed else { return }
        // This Mac's pointer goes into the bubble, lent back from the other Mac until it closes.
        let resumes = input.lend()
        if !open(.here(resumes: resumes)), resumes { input.takeBack() }
    }

    /// A peek message from the other Mac.
    func macAsked(_ command: Wire.Peek) {
        switch command {
        case .open:
            let drives = AXIsProcessTrusted()
            guard open(.mac(drives: drives)) else { return send(Data([Wire.Peek.closed.rawValue])) }
            send(Data([Wire.Peek.opened.rawValue, drives ? 1 : 0]))
        case .close:
            if case .open(.mac, _) = phase { close(tellingMac: false) }
        case .stepThrough:
            if case .open(.mac, _) = phase { stepThrough() }
        case .comeBack:
            comeBack()
        case .steppedOut, .back, .opened, .at, .closed:
            break
        }
    }

    /// Something the other Mac's keyboard or trackpad did, on the network queue: played here while
    /// it works this Mac.
    func play(_ input: InputEvent) {
        drivesLock.lock()
        let drives = macDrives
        drivesLock.unlock()
        if drives { player.play(input) }
    }

    /// A click on the picture, which the window gets when clicks don't go through the bubble.
    /// True if the bubble took it.
    func takesClick(_ event: CGEvent) -> Bool {
        guard case .open(let origin, let through) = phase else { return false }
        // Only looking: a double-click steps through. Otherwise this is a click beside a parked
        // bubble, which shouldn't start controlling the other Mac.
        if !through, case .here = origin, event.isDoubleClick { stepThrough() }
        return true
    }

    // MARK: Opening and closing

    private func open(_ origin: Origin) -> Bool {
        guard phase == .closed, isStreaming(), let start = startPoint(for: origin) else { return false }
        let through = AXIsProcessTrusted() && origin != .mac(drives: false)
        phase = .open(origin, through: through)
        parked = false
        closesWhenButtonUp = false
        log("peek: open from \(origin)\(through ? ", clicks go through" : "")")
        // This Mac's pointer is the one in the bubble unless only following the other Mac's.
        let ownPointer = through || origin != .mac(drives: false)
        if ownPointer {
            warpPointer(to: start)
            setCursorHidden(false)
            // The picture's invisible pointer would otherwise linger until the pointer moves on.
            NSCursor.arrow.set()
        }
        if through {
            overlay.hidesPointer = true
            // Above any window a click brings forward, and out of the way of the clicks. Stationary,
            // or a click on the wallpaper would slide it away to reveal the desktop.
            window.level = .floating
            window.collectionBehavior.insert(.stationary)
            window.ignoresMouseEvents = true
            clickTap.watch(EventTap.buttons + EventTap.drags)
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        portal.open(at: start)
        return true
    }

    /// `resumes`: control lent from the other Mac carries on, unless the picture has stopped.
    private func close(tellingMac: Bool, animated: Bool = true, resumes: Bool = true) {
        guard case .open(let origin, let through) = phase else { return }
        log("peek: closed")
        stopFollowing()
        restoreWindow(through: through)
        animated ? portal.close() : portal.reset()
        phase = .closed
        switch origin {
        case .here(let lent):
            if lent && resumes {
                input.takeBack()
                sendPointerPosition()
            }
        case .mac(let drives):
            if drives { sendPointerPosition() }
            if tellingMac { send(Data([Wire.Peek.closed.rawValue])) }
        }
        if through {
            // A click through the bubble may have made another app active.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(picture)
        }
        setCursorHidden(isStreaming())
    }

    /// The picture has stopped, or the other Mac has gone: nothing can be peeked at, and its
    /// keyboard and trackpad can't be heard any more.
    func pictureStopped() {
        switch phase {
        case .closed:
            break
        case .open:
            close(tellingMac: true, animated: false, resumes: false)
        case .spreading:
            phase = .spreading(macDrives: false, resumes: false)
        case .away:
            phase = .away(macDrives: false, resumes: false)
        }
    }

    // MARK: Following

    private func tick() {
        guard case .open(let origin, let through) = phase else { return }
        if case .here = origin {
            watchKeys(through: through)
            guard case .open = phase else { return }
        }
        // Played buttons as well as this Mac's own, so the other Mac's trackpad can drag too.
        let buttonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        if through {
            let pointer = localPointer
            let inside = portal.contains(pointer)
            if buttonDown {
                // Holding something: the bubble stays put, so it can be dragged out onto the
                // picture, which then takes the drop.
                window.ignoresMouseEvents = inside
                if !inside { parked = true }
            } else if parked && !inside {
                window.ignoresMouseEvents = false
            } else {
                parked = false
                window.ignoresMouseEvents = true
                portal.move(to: pointer)
            }
        } else if case .mac = origin {
            // Only following the other Mac's pointer, which has left this screen.
            guard let hotspot = overlay.hotspot else { return close(tellingMac: true) }
            portal.move(to: hotspot)
        } else {
            portal.move(to: localPointer)
        }
    }

    /// The keys held on this Mac's keyboard, while peeking from it. Read from the keyboard itself:
    /// a click through the bubble can make another app active, which then hears the keys instead,
    /// and while controlling the other Mac they never reach this Mac's session at all.
    private func watchKeys(through: Bool) {
        let keys = CGEventSource.flagsState(.hidSystemState).intersection(.shortcutKeys)
        let buttonDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        if closesWhenButtonUp {
            if !buttonDown { close(tellingMac: false) }
        } else if keys == .stepThroughKeys && !buttonDown {
            stepThrough()
        } else if keys != .peekKeys {
            if through && buttonDown {
                closesWhenButtonUp = true
            } else {
                close(tellingMac: false)
            }
        }
    }

    private func stopFollowing() {
        timer?.invalidate()
        timer = nil
        clickTap.stop()
        parked = false
        closesWhenButtonUp = false
    }

    private func restoreWindow(through: Bool) {
        guard through else { return }
        window.ignoresMouseEvents = false
        window.level = .normal
        window.collectionBehavior.remove(.stationary)
        overlay.hidesPointer = false
    }

    // MARK: Double-clicks in the bubble

    /// On bare wallpaper a double-click steps through. On anything else it went through as usual,
    /// and a window it opens is brought under the bubble to be seen.
    private func doubleClicked() {
        guard case .open(_, true) = phase, let point = CGEvent(source: nil)?.location else { return }
        let before = Set(ScreenProbe.windows().map(\.id))
        // Asking the Finder what's there can be slow; not on the main thread, where taps run.
        DispatchQueue.global(qos: .userInitiated).async {
            let wallpaper = ScreenProbe.window(at: point).map { $0.isDesktop && ScreenProbe.finderItem(at: point, in: $0) == nil } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, case .open(_, true) = self.phase else { return }
                if wallpaper {
                    log("peek: double-click on the wallpaper")
                    self.stepThrough()
                } else {
                    self.bringOpenedWindowUnderBubble(notIn: before, tries: 8)
                }
            }
        }
    }

    /// Looks for a couple of seconds for a window that the app now in front opened.
    private func bringOpenedWindowUnderBubble(notIn before: Set<CGWindowID>, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, case .open(_, true) = self.phase, tries > 0 else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let opened = ScreenProbe.windows().first(where: { $0.layer == 0 && $0.pid == front && !before.contains($0.id) }),
                  let point = CGEvent(source: nil)?.location
            else { return self.bringOpenedWindowUnderBubble(notIn: before, tries: tries - 1) }
            log("peek: bringing the window it opened under the bubble")
            let area = ScreenProbe.usableArea()
            DispatchQueue.global(qos: .userInitiated).async { ScreenProbe.move(opened, centredOn: point, within: area) }
        }
    }

    // MARK: Stepping through and back

    /// The bubble spreads to fill the screen and Tandem hides: this Mac is yours again, with its
    /// pointer where the bubble was. The other Mac keeps its display meanwhile.
    func stepThrough() {
        guard case .open(let origin, let through) = phase else { return }
        log("peek: stepping through to this \(Machine.kind)")
        let point = through || origin != .mac(drives: false) ? localPointer : (overlay.hotspot ?? localPointer)
        stopFollowing()
        restoreWindow(through: through)
        warpPointer(to: point)
        setCursorHidden(false)
        // This Mac's own keyboard and mouse are its own again, whoever opened the bubble, until
        // coming back: control of the other Mac, if it had it, carries on then.
        let resumes = origin == .here(resumes: true) || input.lend()
        let drives = AXIsProcessTrusted()
        if !drives {
            log("peek: the other Mac's keyboard and trackpad need Accessibility here")
            InputCapture.requestAccessibility()
        }
        phase = .spreading(macDrives: drives, resumes: resumes)
        portal.spread { [weak self] in
            guard let self, case .spreading(let drives, let resumes) = self.phase else { return }
            NSApp.presentationOptions = []
            // Hidden still cut wide open, so coming back starts from the desktop, not a flash of picture.
            NSApp.hide(nil)
            self.phase = .away(macDrives: drives, resumes: resumes)
            self.watchForComeBack()
            // The other Mac's keyboard and trackpad come over too, until either Mac comes back.
            self.send(Data([Wire.Peek.steppedOut.rawValue, drives ? 1 : 0]))
        }
    }

    /// Back from this Mac's desktop, by the Dock icon, holding Control-Option, or the other Mac's
    /// quick Control-Option press: the picture closes in around the pointer.
    func comeBack() {
        guard case .away(let drives, let resumes) = phase else { return }
        stopWatchingForComeBack()
        // The other Mac's pointer carries on from here, under this Mac's mouse again if it was.
        if drives || resumes { sendPointerPosition() }
        phase = .closed
        send(Data([Wire.Peek.back.rawValue]))
        log("peek: back to the picture")
        restoreFullScreen()
        if resumes { input.takeBack() }
        if isStreaming() {
            portal.closeIn(at: localPointer)
        } else {
            portal.reset()
        }
        setCursorHidden(isStreaming())
        // Not left to the app becoming active, which macOS may refuse to an app in the background.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(picture)
    }

    /// Holding Control-Option on this Mac's desktop brings the picture back: a fresh press, not
    /// the keys still held from stepping through, and not part of a shortcut. Seeing keys in other
    /// apps needs Accessibility; without it, the Dock icon still works.
    private func watchForComeBack() {
        stopWatchingForComeBack()
        var keysLetGo = false
        let types: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        comeBackMonitor = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] event in
            guard let self else { return }
            self.comeBackHold?.cancel()
            // The other Mac's own keys come back with its own quick press.
            guard event.type == .flagsChanged, event.cgEvent?.isFromOtherMac != true else { return }
            let keys = event.cgEvent?.modifierKeys ?? []
            if keys.isEmpty { keysLetGo = true }
            guard keys == .peekKeys, keysLetGo else { return }
            let hold = DispatchWorkItem { [weak self] in self?.comeBack() }
            self.comeBackHold = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + peekHoldDelay, execute: hold)
        }
    }

    private func stopWatchingForComeBack() {
        comeBackHold?.cancel()
        if let comeBackMonitor { NSEvent.removeMonitor(comeBackMonitor) }
        comeBackMonitor = nil
    }

    // MARK: Pointers

    private func startPoint(for origin: Origin) -> CGPoint? {
        switch origin {
        case .mac:
            return overlay.hotspot
        case .here(let resumes):
            if let hotspot = overlay.hotspot, resumes || macPointerMovedLast { return hotspot }
            return localPointer
        }
    }

    /// This Mac's own pointer, in the picture's coordinates.
    private var localPointer: CGPoint {
        overlay.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// Puts this Mac's pointer at a point in the picture.
    private func warpPointer(to point: CGPoint) {
        let onScreen = window.convertPoint(toScreen: overlay.convert(point, to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? window.frame.maxY
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: top - onScreen.y))
        // A warp otherwise holds the pointer still for a moment. Nothing here is controlling the
        // other Mac, which is what dissociating is for.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Tells the other Mac where this Mac's pointer is, so its own carries on from there.
    private func sendPointerPosition() {
        let p = NSEvent.mouseLocation, f = window.frame
        var d = Data([Wire.Peek.at.rawValue])
        d.appendLE(Float((p.x - f.minX) / f.width).bitPattern)
        d.appendLE(Float((f.maxY - p.y) / f.height).bitPattern)
        send(d)
    }

    // MARK: The other Mac's input

    private let drivesLock = NSLock()
    private var macDrives = false

    /// Gates `play`, which runs on the network queue; letting go of anything the other Mac's
    /// keyboard and trackpad still held happens in order there too.
    private func setMacDrives(_ drives: Bool) {
        drivesLock.lock()
        macDrives = drives
        drivesLock.unlock()
        if !drives { playerQueue.async { self.player.releaseAll() } }
    }
}
