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
    private var colorMatrix = DisplayState.identity

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
        guard updateImage(for: shape) else { return }
        self.shape = shape
        update()
    }

    /// The other Mac's True Tone / Night Shift adaptation, so the pointer matches the picture.
    func setColorMatrix(_ matrix: [Float]) {
        guard matrix.count == 9, matrix.allSatisfy(\.isFinite), matrix != colorMatrix else { return }
        colorMatrix = matrix
        if let shape { _ = updateImage(for: shape) }
    }

    @discardableResult
    private func updateImage(for shape: CursorShape) -> Bool {
        let pixels = Self.applyColorMatrix(colorMatrix, to: shape.pixels)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: shape.width, height: shape.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: shape.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.contents = image
        CATransaction.commit()
        return true
    }

    /// Applies the renderer's linear-light colour matrix to premultiplied BGRA sRGB pixels.
    static func applyColorMatrix(_ m: [Float], to pixels: Data) -> Data {
        guard m.count == 9, m != DisplayState.identity else { return pixels }
        var out = pixels
        out.withUnsafeMutableBytes { raw in
            guard let buf = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in stride(from: 0, to: raw.count & ~3, by: 4) {
                let aByte = buf[i + 3]
                guard aByte != 0 else { continue }
                let a = Float(aByte)
                let b = toLinear(Float(buf[i]) / a)
                let g = toLinear(Float(buf[i + 1]) / a)
                let r = toLinear(Float(buf[i + 2]) / a)
                let rOut = min(max(m[0] * r + m[1] * g + m[2] * b, 0), 1)
                let gOut = min(max(m[3] * r + m[4] * g + m[5] * b, 0), 1)
                let bOut = min(max(m[6] * r + m[7] * g + m[8] * b, 0), 1)
                buf[i] = UInt8(clamping: Int((toGamma(bOut) * a).rounded()))
                buf[i + 1] = UInt8(clamping: Int((toGamma(gOut) * a).rounded()))
                buf[i + 2] = UInt8(clamping: Int((toGamma(rOut) * a).rounded()))
            }
        }
        return out
    }

    private static func toLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private static func toGamma(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1.0 / 2.4) - 0.055
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
