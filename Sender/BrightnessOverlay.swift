import AppKit

/// The brightness level, shown briefly on the other Mac's screen when the brightness keys change
/// it. macOS shows its own only for displays whose brightness it controls. Like macOS's, the level
/// can be dragged, and it stays up while the pointer is over it.
@available(macOS 14, *)
final class BrightnessOverlay {
    static let shared = BrightnessOverlay()

    /// A new level, dragged by the user.
    var onChange: (Float) -> Void = { _ in }

    private let panel: NSPanel
    private let icon = NSImageView()
    private let level = LevelBar()
    private var hide: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 52),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let content = NSView()
        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        icon.contentTintColor = .labelColor
        for view in [icon, level] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            level.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            level.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            level.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            level.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Glass on macOS 26, like the system's own controls; the HUD material before that.
        let background: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 26
            glass.contentView = content
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.masksToBounds = true
            content.frame = effect.bounds
            content.autoresizingMask = [.width, .height]
            effect.addSubview(content)
            background = effect
        }
        panel.contentView = background
        level.onChange = { [weak self] value in
            guard let self else { return }
            self.setIcon(value)
            self.onChange(Float(value))
        }
    }

    private func setIcon(_ value: CGFloat) {
        icon.image = NSImage(systemSymbolName: value < 0.5 ? "sun.min.fill" : "sun.max.fill", accessibilityDescription: "Brightness")
    }

    func show(_ value: Float, on display: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display
        }) else { return }
        setIcon(CGFloat(value))
        level.value = CGFloat(value)

        // Top right, under the menu bar, where macOS shows its own.
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 12, y: area.maxY - size.height - 12))
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        scheduleHide()
    }

    /// Fades out after a moment, unless the pointer is over the panel or dragging the level.
    private func scheduleHide() {
        hide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.level.isDragging || self.panel.frame.contains(NSEvent.mouseLocation) {
                self.scheduleHide()
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
            })
        }
        self.hide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hide)
    }
}

/// A rounded track, filled to `value`, which can be clicked or dragged.
private final class LevelBar: NSView {
    var value: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var onChange: (CGFloat) -> Void = { _ in }
    private(set) var isDragging = false

    /// The drawn track; the view is taller so it's easy to grab.
    private var track: NSRect {
        NSRect(x: bounds.minX, y: bounds.midY - 3, width: bounds.width, height: 6)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        set(event)
    }

    override func mouseDragged(with event: NSEvent) {
        set(event)
    }

    override func mouseUp(with event: NSEvent) {
        set(event)
        isDragging = false
    }

    private func set(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let new = min(max((x - bounds.minX) / bounds.width, 0), 1)
        guard new != value else { return }
        value = new
        onChange(new)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = track
        let radius = track.height / 2
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard value > 0 else { return }
        var fill = track
        fill.size.width = max(track.height, track.width * min(max(value, 0), 1))
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
