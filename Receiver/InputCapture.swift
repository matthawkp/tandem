import AppKit
import ApplicationServices

/// Lends this Mac's keyboard and mouse to the Mac it's showing, like a virtual machine app does: click
/// the picture to start, press and let go of Control-Option to stop.
///
/// Events reach the app as usual, which covers almost everything. With Accessibility permission
/// an event tap also catches what macOS would otherwise keep, such as ⌘Tab and Spotlight.
final class InputCapture {
    /// Sends one event to the MacBook.
    var send: (InputEvent) -> Void = { _ in }
    /// Whether the MacBook will act on what's sent.
    var macState: Wire.InputState = .off {
        didSet { if macState != .ready { release(quietly: true) } }
    }
    /// There's a picture to control.
    var available = false {
        didSet {
            guard !available else { return }
            release(quietly: true)
            hold?.cancel()
        }
    }
    private(set) var engaged = false
    /// This Mac's own mouse moved, or came back, while not controlling the other Mac.
    var onLocalMouse: () -> Void = {}
    /// Control-Option held a moment, rather than pressed and let go: a peek.
    var onPeekHold: () -> Void = {}
    /// Offered each click on the picture first; true if it was taken (by an open bubble).
    var takesClick: (CGEvent) -> Bool = { _ in false }
    /// The Mac being controlled, for the messages.
    var peerKind = "Mac"

    private let window: NSWindow
    private let hud: InputHUD
    private var monitor: Any?
    /// While controlling the other Mac, catches what macOS would otherwise keep, such as ⌘Tab.
    private lazy var tap = EventTap { [unowned self] _, event in self.handle(event) ? nil : event }
    /// What controlling the other Mac adds while full screen, and only that: put back by taking
    /// these away again, never by restoring a copy, which could be out of date.
    private static let lockedDown: NSApplication.PresentationOptions = [.disableProcessSwitching, .disableHideApplication,
                                                                         .disableForceQuit, .disableSessionTermination]
    /// Control-Option is held with nothing else; letting go toggles.
    private var armed = false
    private var hold: DispatchWorkItem?
    /// The click that started control doesn't go to the MacBook, so neither does its release.
    private var holdsBackMouseUp = false

    init(window: NSWindow, hud: InputHUD) {
        self.window = window
        self.hud = hud
        let types: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel, .systemDefined,
                                            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                            .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            guard let self, let cgEvent = event.cgEvent else { return event }
            return self.handle(cgEvent) ? nil : event
        }
    }

    // MARK: Engaging

    private func engage(quietly: Bool = false) {
        guard available else { return }
        guard macState == .ready else {
            if macState == .needsPermission {
                hud.show("Your \(peerKind) needs to allow this first",
                         "On the \(peerKind), choose Allow Accessibility… in the Tandem menu.")
            } else {
                hud.show("Keyboard and mouse sharing is off",
                         "Turn on Use \(Machine.kind) Keyboard and Mouse in Tandem's menu on your \(peerKind).")
            }
            return
        }
        engaged = true
        armed = false
        log("keyboard and mouse: controlling the \(peerKind)")
        // The iMac's own pointer stays put, and its movements go to the MacBook's.
        CGAssociateMouseAndMouseCursorPosition(0)
        window.acceptsMouseMovedEvents = true
        CrashGuard.holding = .pointer
        if NSApp.presentationOptions.contains(.hideDock) {
            NSApp.presentationOptions.formUnion(Self.lockedDown)
            CrashGuard.holding = .everything
        }
        tap.watch([.keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel, EventTap.systemDefined]
                  + EventTap.buttons + EventTap.drags)
        if quietly { return }
        hud.show("This keyboard and mouse now control your \(peerKind)", "Press and release Control-Option ⌃⌥ to stop.")
    }

    /// Hands the keyboard and mouse back to the iMac.
    func release(quietly: Bool = false) {
        guard engaged else { return }
        engaged = false
        armed = false
        log("keyboard and mouse: back to this Mac")
        send(InputEvent(type: InputEvent.releaseAll))
        tap.stop()
        CGAssociateMouseAndMouseCursorPosition(1)
        NSApp.presentationOptions.subtract(Self.lockedDown)
        CrashGuard.holding = .nothing
        if !quietly {
            hud.show("Keyboard and mouse are back on this \(Machine.kind)", "Click to control your \(peerKind) again.")
            onLocalMouse()
        }
    }

    /// Lends this Mac's pointer to a peek: control stops for now. True if it was controlling the
    /// other Mac, so `takeBack` should carry on afterwards.
    func lend() -> Bool {
        guard engaged else { return false }
        release(quietly: true)
        return true
    }

    func takeBack() {
        engage(quietly: true)
    }

    // MARK: Events

    /// Every event comes through here, from the app or the tap. True if it was used up.
    private func handle(_ event: CGEvent) -> Bool {
        // Played here from the other Mac's keyboard and trackpad, not this Mac's own.
        if event.isFromOtherMac { return false }
        let type = event.type
        if type == .flagsChanged {
            let keys = event.modifierKeys
            if keys == .peekKeys {
                if !armed { waitForHold() }
                armed = true
            } else if keys.contains(.maskShift) || keys.contains(.maskCommand) {
                armed = false
                hold?.cancel()
            } else if keys.isEmpty && armed {
                armed = false
                hold?.cancel()
                if engaged { forward(event) }
                if engaged { release() } else { engage() }
                return true
            }
        } else if type != .mouseMoved && !EventTap.drags.contains(type) {
            // Part of a shortcut or a click, not a press of Control-Option on its own.
            armed = false
            hold?.cancel()
        }

        if EventTap.buttons.contains(type), takesClick(event) { return true }

        guard engaged else {
            if type == .mouseMoved && available { onLocalMouse() }
            if type == .leftMouseDown && available {
                engage()
                holdsBackMouseUp = engaged
                return engaged
            }
            return false
        }
        if type == .leftMouseUp && holdsBackMouseUp {
            // Not sent, but not dropped either: this Mac would think the button was still down.
            holdsBackMouseUp = false
            return false
        }
        return forward(event)
    }

    /// Held long enough, Control-Option is a peek, and letting go no longer toggles.
    private func waitForHold() {
        hold?.cancel()
        guard available else { return }
        let hold = DispatchWorkItem { [weak self] in
            // The keyboard itself: while controlling, the keys never reach this Mac's session.
            guard let self, self.armed, self.available,
                  CGEventSource.flagsState(.hidSystemState).intersection(.shortcutKeys) == .peekKeys else { return }
            self.armed = false
            self.onPeekHold()
        }
        self.hold = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + peekHoldDelay, execute: hold)
    }

    /// Sends the event to the MacBook. False for events that aren't sent, which carry on here.
    @discardableResult
    private func forward(_ event: CGEvent) -> Bool {
        guard let input = InputEvent(event) else { return false }
        send(input)
        return true
    }
}

/// A short message over the picture, like macOS's own overlays.
final class InputHUD: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        layer?.cornerRadius = 22
        alphaValue = 0
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        detail.font = .systemFont(ofSize: 16)
        detail.textColor = NSColor(white: 1, alpha: 0.65)
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 36, bottom: 22, right: 36)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks pass through to the picture underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ title: String, _ detail: String) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; self?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
