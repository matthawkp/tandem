import AppKit
import ApplicationServices

/// A session event tap on the main run loop: it sees this Mac's keyboard and mouse events before
/// any app, and can change or drop them. Needs Accessibility.
///
/// macOS turns a tap off if it's ever slow to answer; this one turns straight back on. Changing
/// what it watches from inside its own handler waits until the handler has returned, as a tap
/// mustn't be torn down mid-callback.
final class EventTap {
    /// Returns the event to let it carry on (changed or not), or nil to drop it.
    typealias Handler = (CGEventType, CGEvent) -> CGEvent?

    static let systemDefined = CGEventType(rawValue: 14)! // media keys, among others
    static let buttons: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
    static let drags: [CGEventType] = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mask: CGEventMask = 0
    private var handling = false
    /// What to watch, applied as soon as it's safe: always the latest asked for.
    private var wanted: [CGEventType] = []
    private var applyPending = false

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Watches these kinds of event, or nothing if there are none or there's no Accessibility.
    func watch(_ types: [CGEventType]) {
        self.wanted = types
        guard handling else { return apply() }
        guard !applyPending else { return }
        applyPending = true
        DispatchQueue.main.async {
            self.applyPending = false
            self.apply()
        }
    }

    private func apply() {
        let wanted = AXIsProcessTrusted() ? self.wanted.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue } : 0
        guard wanted != mask else { return }
        remove()
        mask = wanted
        guard wanted != 0,
              let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: wanted, callback: eventTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        watch([])
    }

    deinit {
        remove()
    }

    private func remove() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    fileprivate func tapped(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        handling = true
        defer { handling = false }
        return handler(type, event).map { Unmanaged.passUnretained($0) }
    }
}

private func eventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(info).takeUnretainedValue().tapped(type, event)
}

extension CGEvent {
    /// Played by Tandem from the other Mac's keyboard and mouse, rather than this Mac's own.
    var isFromOtherMac: Bool { getIntegerValueField(.eventSourceUserData) == InputPlayer.marker }

    /// Control, Option, Shift and Command, the keys Tandem's shortcuts use.
    var modifierKeys: CGEventFlags { flags.intersection(.shortcutKeys) }

    var isDoubleClick: Bool { type == .leftMouseDown && getIntegerValueField(.mouseEventClickState) == 2 }
}

extension CGEventFlags {
    static let shortcutKeys: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    /// Held to peek; a quick press and release toggles keyboard and mouse sharing.
    static let peekKeys: CGEventFlags = [.maskControl, .maskAlternate]
    /// Held while peeking, to step through.
    static let stepThroughKeys: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
}

/// How long Control-Option must be held to peek, rather than pressed to toggle sharing.
let peekHoldDelay = 0.3
