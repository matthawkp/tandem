import AppKit

/// Shows what Tandem Camera is sending, and how directly each camera sees you, so the switching
/// can be tried out (and works before the camera extension is installed).
@available(macOS 14, *)
final class CameraPreview: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let picture = NSView()
    private let status = NSTextField(labelWithString: "Starting the cameras…")
    private let switcher: CameraSwitcher
    /// The frames on screen, kept so their buffers aren't reused while showing.
    private var shown: [CVPixelBuffer] = []

    init(switcher: CameraSwitcher) {
        self.switcher = switcher
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Tandem Camera"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentAspectRatio = NSSize(width: 16, height: 10)
        window.contentMinSize = NSSize(width: 400, height: 250)

        picture.wantsLayer = true
        picture.layer?.backgroundColor = NSColor.black.cgColor
        picture.layer?.contentsGravity = .resizeAspect
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        let content = NSView()
        for view in [picture, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: content.topAnchor),
            picture.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
    }

    func show() {
        switcher.onFrame = { [weak self] buffer in
            guard let self else { return }
            // Hold on to the last few frames: the layer only keeps the IOSurface, so a released
            // buffer would go back to its pool and be refilled (sometimes with the other camera's
            // picture) while it's still on screen, flashing for a frame.
            self.shown.append(buffer)
            if self.shown.count > 3 { self.shown.removeFirst() }
            self.picture.layer?.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        }
        switcher.onStatus = { [weak self] status in self?.show(status) }
        switcher.setPreviewing(true)
        if !window.isVisible {
            // On this Mac's own screen, where its camera is.
            let screen = NSScreen.screens.first { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return id.map { CGDisplayIsBuiltin($0) != 0 } ?? false
            } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func show(_ status: CameraSwitcher.Status) {
        if status.waiting {
            self.status.stringValue = "Starting the cameras…"
            return
        }
        let facing = CameraSwitcher.Source.allCases.map { source -> String in
            guard let value = status.facing[source] ?? nil else { return "\(source.name): no face" }
            return "\(source.name) \(Int((value * 100).rounded()))%"
        }
        self.status.stringValue = "Showing the \(status.showing.name) camera  ·  Facing: " + facing.joined(separator: ", ")
    }

    func windowWillClose(_ notification: Notification) {
        switcher.setPreviewing(false)
        switcher.onFrame = { _ in }
        switcher.onStatus = { _ in }
        picture.layer?.contents = nil
        shown = []
    }
}
