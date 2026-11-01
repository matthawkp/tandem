import AppKit

/// Draws the other Mac's pointer over the picture, from cursor and cursorShape messages. A layer
/// of its own, moved as soon as a position arrives, so the pointer doesn't wait for frames.
final class CursorOverlay: NSView {
    /// Only shown while there's a picture.
    var isActive = false {
        didSet { update() }
    }

    /// The pointer's hotspot in this view's coordinates, while it shows.
    private(set) var hotspot: CGPoint?
    /// The pointer moved, or appeared or went.
    var onMove: () -> Void = {}
    /// Hides the drawn pointer while this Mac's own is the one in use, during a peek.
    var hidesPointer = false {
        didSet { update() }
    }

    private let pointer = CALayer()
    private let streamSize: CGSize
    private var shape: CursorShape?
    private var position: CursorPosition?

    init(frame: NSRect, streamSize: CGSize) {
        self.streamSize = streamSize
        super.init(frame: frame)
        wantsLayer = true
        pointer.isHidden = true
        pointer.contentsGravity = .resize
        // Jump straight to each position; no implicit animation.
        pointer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(pointer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go to the picture underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        update()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pointer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func setShape(_ shape: CursorShape) {
        guard let provider = CGDataProvider(data: shape.pixels as CFData),
              let image = CGImage(width: shape.width, height: shape.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: shape.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        self.shape = shape
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.contents = image
        CATransaction.commit()
        update()
    }

    func setPosition(_ position: CursorPosition) {
        self.position = position
        update()
    }

    /// Forget the pointer, e.g. for a new connection.
    func reset() {
        shape = nil
        position = nil
        update()
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard isActive, let shape, let position, position.visible, streamSize.width > 0, streamSize.height > 0 else {
            pointer.isHidden = true
            hotspot = nil
            onMove()
            return
        }
        // The picture is fitted to the view (contentsGravity .resizeAspect), centred.
        let scale = min(bounds.width / streamSize.width, bounds.height / streamSize.height)
        let left = (bounds.width - streamSize.width * scale) / 2
        let top = (bounds.height - streamSize.height * scale) / 2
        let width = CGFloat(shape.width) * scale, height = CGFloat(shape.height) * scale
        let x = left + CGFloat(Int(position.x) - shape.hotX) * scale
        let yFromTop = top + CGFloat(Int(position.y) - shape.hotY) * scale
        // Layer coordinates start at the bottom.
        pointer.frame = CGRect(x: x, y: bounds.height - yFromTop - height, width: width, height: height)
        pointer.isHidden = hidesPointer
        hotspot = CGPoint(x: left + CGFloat(position.x) * scale, y: bounds.height - top - CGFloat(position.y) * scale)
        onMove()
    }
}
