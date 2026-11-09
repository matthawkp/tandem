import AppKit
import ApplicationServices

/// Peeking from this Mac's own keyboard and trackpad, as the other Mac's keyboard and mouse can:
/// hold Control-Option with the pointer on the other Mac's screen and a bubble opens there, around
/// the pointer, through to that Mac's own desktop, and this Mac's trackpad works that Mac's own
/// pointer inside it. Add Command to step through; this Mac's keyboard and trackpad then work the
/// other Mac until a quick Control-Option press comes back.
///
/// Watching the keys and taking over the trackpad use an event tap, so this needs Accessibility,
/// like the rest of keyboard and mouse sharing.
@available(macOS 14, *)
final class RemotePeek {
    /// Sends a peek command to the other Mac.
    var send: (Wire.Peek) -> Void = { _ in }
    /// Sends one of this Mac's events to the other Mac, in the bubble or stepped through.
    var sendInput: (InputEvent) -> Void = { _ in }
    /// The virtual display shown on the other Mac.
    var displayID: () -> CGDirectDisplayID? = { nil }
    /// Connected to a Mac that can peek.
    var available = false {
        didSet {
            if !available { stop() }
            update()
        }
    }

    private enum Mode: Equatable {
        case idle
        /// Control-Option held on the other Mac's screen, waiting to see if it's a hold.
        case holding
        /// `drives`: this Mac's trackpad works the other Mac's pointer in the bubble. Without
        /// Accessibility there, the bubble only follows this Mac's pointer, for looking.
        case peeking(drives: Bool)
        /// Waiting for the other Mac to finish spreading the bubble.
        case steppingThrough(drives: Bool)
        /// On the other Mac's desktop. `drives`: this Mac's keyboard and trackpad go there.
        case away(drives: Bool)
    }
    private var mode = Mode.idle {
        // Not straight away: this is often set from inside the tap's own callback.
        didSet { if mode != oldValue { DispatchQueue.main.async { self.update() } } }
    }
    private var hold: DispatchWorkItem?
    /// In case the other Mac never answers a step through.
    private var stepThroughTimeout: DispatchWorkItem?
    /// Buttons held down on the other Mac, from this Mac's trackpad, in the bubble.
    private var buttonsDown = 0
    /// Control-Option was let go mid-drag: the bubble closes once the button is up, so the drag
    /// can finish over there.
    private var closesWhenButtonsUp = false
    /// While away: Control-Option pressed with nothing else; letting go comes back.
    private var armed = false
    /// While away: every key has been let go since stepping through, so the keys held to step
    /// through don't count as a press.
    private var keysLetGo = false
    private lazy var tap = EventTap { [unowned self] type, event in self.handle(type, event) ? nil : event }

    /// The other Mac has opened the bubble.
    func opened(drives: Bool) {
        guard mode == .peeking(drives: false), drives else { return }
        mode = .peeking(drives: true)
    }

    /// Where the other Mac's pointer finished, as fractions of its screen: this Mac's carries on
    /// from the same place on the picture.
    func pointer(at x: Float, _ y: Float) {
        guard x.isFinite, y.isFinite, let id = displayID() else { return }
        let bounds = CGDisplayBounds(id)
        CGWarpMouseCursorPosition(CGPoint(x: bounds.minX + CGFloat(min(max(x, 0), 0.999)) * bounds.width,
                                          y: bounds.minY + CGFloat(min(max(y, 0), 0.999)) * bounds.height))
        CGAssociateMouseAndMouseCursorPosition(drivesNow ? 0 : 1)
    }

    /// The other Mac has spread the bubble and shows its desktop.
    func steppedOut(drives: Bool) {
        // Asked for, or a double-click on the wallpaper in the bubble, perhaps after the keys
        // were let go here while it spread. The other Mac has stepped out either way.
        if case .away = mode { return }
        stepThroughTimeout?.cancel()
        log("peek: on the other Mac's desktop\(drives ? "" : ", but it can't play this Mac's keyboard and trackpad without Accessibility")")
        armed = false
        keysLetGo = false
        mode = .away(drives: drives)
    }

    /// The other Mac closed the bubble by itself, or couldn't open it.
    func otherMacClosed() {
        switch mode {
        case .holding, .peeking: mode = .idle
        default: break
        }
    }

    /// The other Mac came back to the picture by itself (its Dock icon, say).
    func otherMacCameBack() {
        guard case .away = mode else { return }
        log("peek: back from the other Mac")
        mode = .idle
    }

    private func comeBack() {
        log("peek: coming back from the other Mac")
        send(.comeBack)
        mode = .idle
    }

    private func stop() {
        hold?.cancel()
        stepThroughTimeout?.cancel()
        mode = .idle
    }

    private func cancelHold() {
        if mode == .holding { mode = .idle }
    }

    private func askToStepThrough(drives: Bool) {
        log("peek: stepping through")
        send(.stepThrough)
        mode = .steppingThrough(drives: drives)
        stepThroughTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            if case .steppingThrough = self?.mode { self?.mode = .idle }
        }
        stepThroughTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    // MARK: Events

    private static let held = CGEventFlags.peekKeys
    private static let buttons = EventTap.buttons

    private var pointerIsOnOtherMac: Bool {
        guard let id = displayID(), let location = CGEvent(source: nil)?.location else { return false }
        return CGDisplayBounds(id).contains(location)
    }

    /// True if the event was used up.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // Played here from the other Mac's keyboard and mouse: that Mac peeks by itself.
        if event.isFromOtherMac { return false }
        let keys = event.modifierKeys
        switch mode {
        case .idle:
            if type == .flagsChanged, keys == Self.held, pointerIsOnOtherMac {
                mode = .holding
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.mode == .holding,
                          CGEventSource.flagsState(.hidSystemState).intersection(.shortcutKeys) == Self.held,
                          !CGEventSource.buttonState(.hidSystemState, button: .left)
                    else { return self?.cancelHold() ?? () }
                    log("peek: open")
                    self.send(.open)
                    self.buttonsDown = 0
                    self.closesWhenButtonsUp = false
                    self.mode = .peeking(drives: false)
                }
                hold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + peekHoldDelay, execute: work)
            }
            return false

        case .holding:
            // A key or a click makes it part of a shortcut, such as ⌃⌥→, not a peek.
            if type != .flagsChanged || keys != Self.held {
                hold?.cancel()
                mode = .idle
            }
            return false

        case .peeking(let drives):
            if type == .flagsChanged {
                if closesWhenButtonsUp { return false }
                if keys == .stepThroughKeys && buttonsDown == 0 {
                    askToStepThrough(drives: drives)
                } else if keys != Self.held {
                    if drives && buttonsDown > 0 {
                        closesWhenButtonsUp = true
                    } else {
                        send(.close)
                        mode = .idle
                    }
                }
                return false
            }
            if drives {
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { buttonsDown += 1 }
                if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) { buttonsDown = max(0, buttonsDown - 1) }
                let used = forward(event)
                if closesWhenButtonsUp && buttonsDown == 0 {
                    closesWhenButtonsUp = false
                    send(.close)
                    mode = .idle
                }
                return used
            }
            // Only looking: clicks belong to the bubble, as with Control held they'd be right-clicks
            // here. A double-click steps through.
            guard Self.buttons.contains(type) else { return false }
            if event.isDoubleClick { askToStepThrough(drives: false) }
            return true

        case .steppingThrough(let drives):
            if type == .flagsChanged { return false }
            return drives ? forward(event) : Self.buttons.contains(type)

        case .away(let drives):
            if type == .flagsChanged {
                if keys.isEmpty { keysLetGo = true }
                if keys == Self.held && keysLetGo {
                    armed = true
                } else if keys.isEmpty && armed {
                    armed = false
                    if drives, let input = InputEvent(event) { sendInput(input) }
                    comeBack()
                    return drives
                } else if !keys.isEmpty && !Self.held.contains(keys) {
                    armed = false
                }
            } else if type != .mouseMoved && !EventTap.drags.contains(type) {
                armed = false
            }
            guard drives, let input = InputEvent(event) else { return false }
            sendInput(input)
            return true
        }
    }

    /// Sends a pointer event to the other Mac, without Control and Option: those are held to
    /// keep the bubble open, and would make clicks right-clicks.
    private func forward(_ event: CGEvent) -> Bool {
        guard event.type != .keyDown, event.type != .keyUp, var input = InputEvent(event) else { return false }
        input.flags &= ~(CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
        sendInput(input)
        return true
    }

    private var drivesNow: Bool {
        switch mode {
        case .peeking(true), .steppingThrough(true), .away(true): return true
        default: return false
        }
    }

    // MARK: Event tap

    /// Watches only the modifier keys until there's more to do, so the tap costs next to nothing
    /// the rest of the time.
    private func update() {
        var types: [CGEventType] = [.flagsChanged]
        switch mode {
        case .idle:
            break
        case .holding:
            // To tell a hold from a shortcut or a click.
            types += [.keyDown] + Self.buttons
        case .peeking(let drives), .steppingThrough(let drives):
            types += Self.buttons
            if drives { types += [.mouseMoved, .scrollWheel] + EventTap.drags }
        case .away(let drives):
            if drives { types += Self.buttons + EventTap.drags + [.keyDown, .keyUp, .mouseMoved, .scrollWheel, EventTap.systemDefined] }
        }
        tap.watch(available ? types : [])
        // Allowed later in System Settings: look again in a while.
        if available && !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.update() }
        }

        // This Mac's pointer stays put, out of sight, while its trackpad moves the other Mac's.
        let drives = drivesNow
        CGAssociateMouseAndMouseCursorPosition(drives ? 0 : 1)
        setPointerHidden(drives)
        CrashGuard.holding = drives ? .pointer : .nothing
        if !drives, wasDriving { sendInput(InputEvent(type: InputEvent.releaseAll)) }
        wasDriving = drives
    }
    private var wasDriving = false

    private var pointerHidden = false

    private func setPointerHidden(_ hidden: Bool) {
        guard hidden != pointerHidden else { return }
        pointerHidden = hidden
        // A menu bar app is always in the background, where it may only hide the pointer once
        // it's told the window server it means to.
        CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if hidden { CGDisplayHideCursor(CGMainDisplayID()) } else { CGDisplayShowCursor(CGMainDisplayID()) }
    }
}
