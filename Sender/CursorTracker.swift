import AppKit

/// Follows this Mac's pointer for a receiver that draws it itself: where it is on the virtual
/// display, whether it shows, and its image whenever that changes. The picture is then captured
/// without the pointer, so moving it costs no frames and it moves as soon as the message lands,
/// not with the next captured, encoded and decoded frame.
///
/// Polled at 120 Hz on the main queue (NSCursor wants it); a poll is a few microseconds, and only
/// changes are sent.
@available(macOS 14, *)
final class CursorTracker {
    var onPosition: (CursorPosition) -> Void = { _ in }
    var onShape: (CursorShape) -> Void = { _ in }

    private let displayID: CGDirectDisplayID
    private let pixelWidth: Int
    private var timer: DispatchSourceTimer?
    private var lastPosition: CursorPosition?
    private var lastSeed: Int32?
    private var lastScale: CGFloat = 0
    private var sizeScale: CGFloat = 1
    private var ticks = 0
    /// Where the pointer was when an app hid it. macOS hides it while you type, until the mouse
    /// moves; but movements played from the other Mac's mouse don't count, so an app like Chrome
    /// can leave it hidden for good. Here, once it moves from where it was hidden, it shows.
    private var hiddenAt: CGPoint?
    private var shownByMoving = false

    init(displayID: CGDirectDisplayID, pixelWidth: Int) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// A key was typed from the other Mac: an app may hide the pointer again, until it moves.
    func keyTyped() {
        hiddenAt = nil
        shownByMoving = false
    }

    /// Sends the image and position again, e.g. after the display's resolution changed.
    func resend() {
        lastSeed = nil
        lastPosition = nil
    }

    private func tick() {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, let location = CGEvent(source: nil)?.location else { return }
        // Receiver pixels per point: 2 at the default "looks like" size, less in scaled modes.
        let pixelsPerPoint = CGFloat(pixelWidth) / bounds.width
        var shows = CursorTracker.isVisible()
        if shows {
            hiddenAt = nil
            shownByMoving = false
        } else {
            // Not when an app has the pointer held still, as games do: it doesn't move then.
            if hiddenAt == nil { hiddenAt = location }
            if let at = hiddenAt, hypot(location.x - at.x, location.y - at.y) > 2 { shownByMoving = true }
            shows = shownByMoving
        }
        let visible = bounds.contains(location) && shows

        // The pointer size setting in Accessibility, which also grows when you shake to find it.
        if ticks % 30 == 0 { sizeScale = CursorTracker.sizeScale() }
        ticks &+= 1
        if visible {
            let scale = pixelsPerPoint * sizeScale
            let seed = CursorTracker.seed()
            if seed != lastSeed || seed == nil || scale != lastScale, let shape = CursorTracker.shape(scale: scale) {
                lastSeed = seed
                lastScale = scale
                onShape(shape)
            }
        }

        let position = CursorPosition(x: Int32(((location.x - bounds.minX) * pixelsPerPoint).rounded()),
                                      y: Int32(((location.y - bounds.minY) * pixelsPerPoint).rounded()),
                                      visible: visible)
        // While hidden, where it is doesn't matter.
        guard position != lastPosition, visible || lastPosition?.visible != false else { return }
        lastPosition = position
        onPosition(position)
    }

    /// The current pointer image, drawn at `scale` pixels per point.
    private static func shape(scale: CGFloat) -> CursorShape? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let size = cursor.image.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, width <= 1024, height <= 1024,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        cursor.image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        // The hotspot is measured from the image's top-left corner, like the receiver's pixels.
        return CursorShape(width: width, height: height,
                           hotX: min(width - 1, Int((cursor.hotSpot.x * scale).rounded())),
                           hotY: min(height - 1, Int((cursor.hotSpot.y * scale).rounded())),
                           pixels: Data(bytes: data, count: width * height * 4))
    }

    // Private CoreGraphics calls, looked up at run time so a missing one only loses that detail.
    private typealias SeedFunction = @convention(c) () -> Int32
    private typealias VisibleFunction = @convention(c) () -> UInt32
    private typealias ScaleFunction = @convention(c) (CGSConnectionID, UnsafeMutablePointer<Float>) -> CGError
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    private static let seedFunction = dlsym(defaultHandle, "CGSCurrentCursorSeed").map { unsafeBitCast($0, to: SeedFunction.self) }
    private static let visibleFunction = dlsym(defaultHandle, "CGCursorIsVisible").map { unsafeBitCast($0, to: VisibleFunction.self) }
    private static let scaleFunction = dlsym(defaultHandle, "CGSGetCursorScale").map { unsafeBitCast($0, to: ScaleFunction.self) }

    /// Changes whenever the pointer's image does. Nil if unknown: the image is then read each time.
    private static func seed() -> Int32? { seedFunction?() }

    /// False while an app has hidden the pointer, e.g. while typing or playing a video.
    private static func isVisible() -> Bool { visibleFunction.map { $0() != 0 } ?? true }

    private static func sizeScale() -> CGFloat {
        var scale: Float = 1
        guard let scaleFunction, scaleFunction(_CGSDefaultConnection(), &scale) == .success, scale >= 1, scale <= 8 else { return 1 }
        return CGFloat(scale)
    }
}
