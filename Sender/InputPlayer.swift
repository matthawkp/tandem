import AppKit
import ApplicationServices
import IOKit.pwr_mgt

/// Replays the iMac's keyboard and mouse on this Mac. Posting events needs Accessibility
/// permission, the same one the brightness keys use.
///
/// Thread-safe in the sense that it's only used from the network queue. The display Mac uses it
/// too, to play the extending Mac's keyboard and trackpad after stepping through to its desktop.
final class InputPlayer {
    /// Adjustments from the menu, on top of the iMac's own mouse settings.
    struct Tuning {
        var pointerSpeed = 1.0
        var scrollSpeed = 1.0
        var reversesScrolling = false
    }
    var tuning = Tuning()
    /// A brightness key from the iMac's keyboard: +1 or -1, and whether Option-Shift asked for a
    /// finer step. Returns whether it was handled; if not, the key is played here as usual.
    /// Called on the main queue.
    var onBrightnessKey: (_ direction: Float, _ fine: Bool) -> Bool = { _, _ in false }
    /// A key was typed, which may hide the pointer until it moves. Called on the main queue.
    var onKeyTyped: () -> Void = {}
    /// The last brightness step taken, to count one press once (main queue).
    private var lastBrightnessStep: (direction: Float, time: UInt64)?
    private var brightnessKeyHandled = false

    /// Marks the events played here, so Tandem's own taps can tell them from this Mac's real
    /// keyboard and mouse: otherwise Control-Option from the other Mac would also peek from this one.
    static let marker: Int64 = 0x5461_6E64

    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = InputPlayer.marker
        // By default, posting an event mutes this Mac's own keyboard and trackpad for a
        // quarter of a second. Both should work side by side.
        source?.localEventsSuppressionInterval = 0
        return source
    }()
    private var keysDown = Set<UInt16>()
    private var buttonsDown = Set<Int64>()
    /// Something has been played since the last release.
    private var active = false
    /// The pointer may be hidden: macOS hides it while you type, until the mouse moves, and only
    /// counts real mice. Set when input starts and after typing.
    private var pointerMayBeHidden = true
    private var activityAssertion: IOPMAssertionID = 0
    private var lastActivity = DispatchTime(uptimeNanoseconds: 0)

    @available(macOS 14, *)
    static var state: Wire.InputState {
        guard Preferences.shared.usesReceiverInput else { return .off }
        return AXIsProcessTrusted() ? .ready : .needsPermission
    }

    func play(_ input: InputEvent) {
        if input.type == InputEvent.releaseAll { return releaseAll() }
        guard let type = CGEventType(rawValue: input.type) else { return }
        active = true
        declareActivity()
        let flags = CGEventFlags(rawValue: input.flags)
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            let code = UInt16(input[CGEventField.keyboardEventKeycode.rawValue])
            // Apple keyboards' brightness keys arrive as key codes as well as media keys.
            if code == 144 || code == 145, type != .flagsChanged {
                let direction: Float = code == 144 ? 1 : -1
                DispatchQueue.main.async {
                    guard !self.brightnessKey(direction, isDown: type == .keyDown, flags: flags) else { return }
                    let event = CGEvent(keyboardEventSource: self.source, virtualKey: code, keyDown: type == .keyDown)
                    event?.flags = flags
                    event?.post(tap: .cghidEventTap)
                }
                return
            }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: type != .keyUp) else { return }
            event.type = type
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: Int64(input[CGEventField.keyboardEventAutorepeat.rawValue]))
            if type == .keyDown {
                keysDown.insert(code)
                pointerMayBeHidden = true
                DispatchQueue.main.async { self.onKeyTyped() }
            } else if type == .keyUp {
                keysDown.remove(code)
            }
            event.post(tap: .cghidEventTap)

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            revealPointerIfNeeded()
            let dx = input[CGEventField.mouseEventDeltaX.rawValue] * tuning.pointerSpeed
            let dy = input[CGEventField.mouseEventDeltaY.rawValue] * tuning.pointerSpeed
            let to = movedPointer(by: dx, dy)
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to,
                                      mouseButton: CGMouseButton(rawValue: UInt32(input[CGEventField.mouseEventButtonNumber.rawValue])) ?? .left)
            else { return }
            event.flags = flags
            event.setDoubleValueField(.mouseEventDeltaX, value: dx)
            event.setDoubleValueField(.mouseEventDeltaY, value: dy)
            event.post(tap: .cghidEventTap)

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            revealPointerIfNeeded()
            let button = Int64(input[CGEventField.mouseEventButtonNumber.rawValue])
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pointer,
                                      mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left)
            else { return }
            event.flags = flags
            event.setIntegerValueField(.mouseEventClickState, value: Int64(input[CGEventField.mouseEventClickState.rawValue]))
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
                buttonsDown.insert(button)
            } else {
                buttonsDown.remove(button)
            }
            event.post(tap: .cghidEventTap)

        case .scrollWheel:
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)
            else { return }
            event.flags = flags
            event.location = pointer
            for field in InputEvent.scrollFields {
                guard var value = input.fields[field.rawValue] else { continue }
                if InputEvent.scrollDeltaFields.contains(field) {
                    value *= tuning.scrollSpeed * (tuning.reversesScrolling ? -1 : 1)
                    // Whole-line steps from a mouse wheel shouldn't round away to nothing.
                    if !InputEvent.doubleFields.contains(field) && value != 0 {
                        value = value < 0 ? min(value.rounded(), -1) : max(value.rounded(), 1)
                    }
                }
                if InputEvent.doubleFields.contains(field) {
                    event.setDoubleValueField(field, value: value)
                } else {
                    event.setIntegerValueField(field, value: Int64(value))
                }
            }
            event.post(tap: .cghidEventTap)

        default:
            // Media keys: volume, play/pause, brightness (which Tandem's own brightness keys then
            // send to whichever screen the pointer is on).
            guard input.type == 14 else { return } // NX_SYSDEFINED
            let data1 = Int(input[InputEvent.data1Field]), data2 = Int(input[InputEvent.data2Field])
            let subtype = Int16(input[InputEvent.subtypeField])
            DispatchQueue.main.async {
                let key = (data1 & 0xFFFF_0000) >> 16
                let brightnessUp = 2, brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
                if subtype == 8, key == brightnessUp || key == brightnessDown,
                   self.brightnessKey(key == brightnessUp ? 1 : -1, isDown: (data1 & 0xFF00) >> 8 == 0x0A, flags: flags) {
                    return
                }
                NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                   modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(input.flags)),
                                   timestamp: 0, windowNumber: 0, context: nil,
                                   subtype: subtype, data1: data1, data2: data2)?
                    .cgEvent.map { event in
                        event.setIntegerValueField(.eventSourceUserData, value: InputPlayer.marker)
                        event.post(tap: .cghidEventTap)
                    }
            }
        }
    }

    /// Offers a brightness key to `onBrightnessKey`; true if handled, so it isn't played. One press
    /// arrives twice, as a key code and as a media key, but steps once, and its release goes where
    /// the press went.
    private func brightnessKey(_ direction: Float, isDown: Bool, flags: CGEventFlags) -> Bool {
        guard isDown else { return brightnessKeyHandled }
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastBrightnessStep, last.direction == direction, now - last.time < 40_000_000 {
            return brightnessKeyHandled
        }
        lastBrightnessStep = (direction, now)
        brightnessKeyHandled = onBrightnessKey(direction, flags.contains([.maskAlternate, .maskShift]))
        return brightnessKeyHandled
    }

    /// Posted events don't count as someone using this Mac, so without this its screens would dim
    /// and sleep while you work from the iMac, and stay dark when you come back to it.
    private func declareActivity() {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastActivity.uptimeNanoseconds > 1_000_000_000 else { return }
        lastActivity = now
        IOPMAssertionDeclareUserActivity("Tandem: the other Mac's keyboard and mouse" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }

    /// Brings the pointer back if typing hid it, as moving a real mouse would. A background app
    /// may show the pointer once it tells the window server it means to.
    ///
    /// Not just once after a key: an app may hide the pointer a moment after the key that made it
    /// (Google Sheets does, pasting), so it's shown on each movement, at most a few times a
    /// second, until it really is visible.
    private func revealPointerIfNeeded() {
        guard pointerMayBeHidden else { return }
        if InputPlayer.pointerIsVisible() {
            pointerMayBeHidden = false
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastReveal > 150_000_000 else { return }
        lastReveal = now
        // Without a way to tell, once is all there is: after each key, as before.
        if InputPlayer.visibleFunction == nil { pointerMayBeHidden = false }
        DispatchQueue.main.async {
            CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
            CGDisplayHideCursor(CGMainDisplayID())
            CGDisplayShowCursor(CGMainDisplayID())
            // And any "hidden until the mouse moves", which only a real mouse would clear.
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }
    private var lastReveal: UInt64 = 0

    private typealias VisibleFunction = @convention(c) () -> UInt32
    /// CGCursorIsVisible: private, looked up at run time; if it's missing, the pointer is shown
    /// after every key, as before.
    private static let visibleFunction = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible")
        .map { unsafeBitCast($0, to: VisibleFunction.self) }
    private static func pointerIsVisible() -> Bool { visibleFunction.map { $0() != 0 } ?? false }

    /// Lets go of anything still held, so nothing sticks when the iMac lets go or disconnects.
    func releaseAll() {
        guard active else { return }
        active = false
        pointerMayBeHidden = true
        for code in keysDown {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        }
        keysDown.removeAll()
        let ups: [Int64: CGEventType] = [0: .leftMouseUp, 1: .rightMouseUp]
        for button in buttonsDown {
            CGEvent(mouseEventSource: source, mouseType: ups[button] ?? .otherMouseUp, mouseCursorPosition: pointer,
                    mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll()
        if let modifiers = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) {
            modifiers.type = .flagsChanged
            modifiers.flags = []
            modifiers.post(tap: .cghidEventTap)
        }
    }

    private var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Moves the pointer like a mouse would: across any screen, stopping at the outer edges.
    private func movedPointer(by dx: Double, _ dy: Double) -> CGPoint {
        let from = pointer
        let to = CGPoint(x: from.x + dx, y: from.y + dy)
        if display(at: to) != nil { return to }
        // Off every screen: slide along the edge of the one it's on.
        guard let id = display(at: from) else { return from }
        let bounds = CGDisplayBounds(id)
        return CGPoint(x: min(max(to.x, bounds.minX), bounds.maxX - 1), y: min(max(to.y, bounds.minY), bounds.maxY - 1))
    }

    private func display(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        return count > 0 ? id : nil
    }
}
