import AppKit

/// A bubble through the other Mac's picture to this Mac's own desktop: hold Control-Option to
/// peek. It pops open, trails the pointer on a spring, stretches as it moves, and shimmers like a
/// soap film.
final class Portal {
    private let window: NSWindow
    /// The picture, which the hole is cut from.
    private let picture: CALayer
    private let hole = CAShapeLayer()
    /// Everything drawn around the hole, built once at full size and then moved, turned and scaled.
    private let bubble = CALayer()
    private let film = CAGradientLayer()
    private let highlight = CAShapeLayer()

    private(set) var isOpen = false
    private var target = CGPoint.zero
    private var center = CGPoint.zero
    private var velocity = CGVector.zero
    private var radius: CGFloat = 0
    private var radiusVelocity: CGFloat = 0
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    /// Spreading to fill the screen, then calling this.
    private var spreadDone: (() -> Void)?
    /// Closing in from the whole screen, more slowly, like an iris.
    private var closingIn = false

    /// Big enough to uncover the whole picture from anywhere on it.
    private var fullRadius: CGFloat { hypot(picture.bounds.width, picture.bounds.height) * 1.05 }

    static let size: CGFloat = 220

    /// The bubble is drawn in `host`, which should sit over the picture with the same bounds.
    init(window: NSWindow, picture: CALayer, host: CALayer) {
        self.window = window
        self.picture = picture
        hole.fillRule = .evenOdd
        hole.fillColor = NSColor.black.cgColor
        buildBubble()
        bubble.isHidden = true
        host.insertSublayer(bubble, at: 0)
    }

    private func buildBubble() {
        let r = Portal.size
        let box = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        bubble.bounds = box
        let circle = CGPath(ellipseIn: box, transform: nil)

        // A soft shadow just outside, as if the picture were a sheet lifted off the desktop.
        let shadow = CAShapeLayer()
        shadow.frame = box
        shadow.path = circle
        shadow.fillColor = nil
        shadow.strokeColor = NSColor(white: 0, alpha: 0.5).cgColor
        shadow.lineWidth = 1
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.7
        shadow.shadowRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        bubble.addSublayer(shadow)

        // Shading inside the edge, so the desktop looks like it's beneath the picture.
        let depth = CAGradientLayer()
        depth.type = .radial
        depth.frame = box
        depth.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor(white: 0, alpha: 0.18).cgColor,
                        NSColor(white: 0, alpha: 0.55).cgColor]
        depth.locations = [0, 0.72, 0.9, 1]
        depth.startPoint = CGPoint(x: 0.5, y: 0.5)
        depth.endPoint = CGPoint(x: 1, y: 1)
        let depthMask = CAShapeLayer()
        depthMask.path = circle
        depth.mask = depthMask
        bubble.addSublayer(depth)

        // The rim: a thin film of shifting colour, like a soap bubble.
        film.type = .conic
        film.frame = box
        film.startPoint = CGPoint(x: 0.5, y: 0.5)
        film.endPoint = CGPoint(x: 1, y: 0.5)
        let hues: [(CGFloat, CGFloat, CGFloat)] = [(0.35, 0.95, 1), (0.45, 0.55, 1), (0.95, 0.45, 1), (1, 0.7, 0.4),
                                                   (0.95, 1, 0.55), (0.35, 0.95, 1)]
        film.colors = hues.map { NSColor(calibratedRed: $0.0, green: $0.1, blue: $0.2, alpha: 0.9).cgColor }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: box.insetBy(dx: 2, dy: 2), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.black.cgColor
        ring.lineWidth = 5
        film.mask = ring
        film.shadowColor = NSColor(calibratedRed: 0.6, green: 0.8, blue: 1, alpha: 1).cgColor
        film.shadowOpacity = 0.8
        film.shadowRadius = 10
        film.shadowOffset = .zero
        bubble.addSublayer(film)

        // A glint on the glass, top left, which stays put as the bubble turns.
        highlight.frame = box
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: r, y: r), radius: r - 16, startAngle: .pi * 0.58, endAngle: .pi * 0.86, clockwise: false)
        highlight.path = arc
        highlight.fillColor = nil
        highlight.strokeColor = NSColor(white: 1, alpha: 0.75).cgColor
        highlight.lineWidth = 5
        highlight.lineCap = .round
        highlight.shadowColor = NSColor.white.cgColor
        highlight.shadowOpacity = 0.9
        highlight.shadowRadius = 6
        highlight.shadowOffset = .zero
        // And a fainter one opposite, light caught on the far side of the glass.
        let reflection = CAShapeLayer()
        reflection.frame = box
        let far = CGMutablePath()
        far.addArc(center: CGPoint(x: r, y: r), radius: r - 12, startAngle: .pi * 1.62, endAngle: .pi * 1.78, clockwise: false)
        reflection.path = far
        reflection.fillColor = nil
        reflection.strokeColor = NSColor(white: 1, alpha: 0.35).cgColor
        reflection.lineWidth = 3
        reflection.lineCap = .round
        highlight.addSublayer(reflection)
        bubble.addSublayer(highlight)
    }

    func open(at point: CGPoint) {
        target = point
        guard !isOpen else { return }
        isOpen = true
        if radius < 1 {
            center = point
            velocity = .zero
            radiusVelocity = 0
            started = CACurrentMediaTime()
        }
        // The window has to let the desktop show through while the hole is there.
        window.isOpaque = false
        window.backgroundColor = .clear
        picture.mask = hole
        bubble.isHidden = false
        run()
    }

    /// Whether a point is inside the bubble as it's drawn now.
    func contains(_ point: CGPoint) -> Bool {
        isOpen && hypot(point.x - center.x, point.y - center.y) < radius
    }

    func move(to point: CGPoint) {
        guard spreadDone == nil else { return }
        target = point
    }

    /// Spreads out to uncover the whole screen, then calls `done`.
    func spread(_ done: @escaping () -> Void) {
        guard isOpen else { return done() }
        target = center
        velocity = .zero
        spreadDone = done
        run()
    }

    /// The picture closes back in over the desktop, around `point`.
    func closeIn(at point: CGPoint) {
        center = point
        target = point
        velocity = .zero
        radius = fullRadius
        radiusVelocity = 0
        isOpen = false
        closingIn = true
        started = CACurrentMediaTime()
        window.isOpaque = false
        window.backgroundColor = .clear
        picture.mask = hole
        bubble.isHidden = false
        draw(time: 0)
        run()
    }

    /// Back to a plain picture straight away.
    func reset() {
        isOpen = false
        spreadDone = nil
        finishClosing()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        run()
    }

    private func run() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1.0 / 30))
        lastTick = now

        // The centre trails the pointer on a slightly bouncy spring.
        let stiffness: CGFloat = 170, damping = 2 * sqrt(stiffness) * 0.62
        velocity.dx += (stiffness * (target.x - center.x) - damping * velocity.dx) * dt
        velocity.dy += (stiffness * (target.y - center.y) - damping * velocity.dy) * dt
        center.x += velocity.dx * dt
        center.y += velocity.dy * dt

        // The size pops open with a wobble, and closes briskly; spreading and closing in are smooth.
        let spreading = spreadDone != nil
        let goal: CGFloat = spreading ? fullRadius : isOpen ? Portal.size : 0
        let k: CGFloat = spreading ? 90 : closingIn ? 110 : isOpen ? 260 : 420
        let ratio: CGFloat = spreading || closingIn ? 1 : isOpen ? 0.42 : 1
        radiusVelocity += (k * (goal - radius) - 2 * sqrt(k) * ratio * radiusVelocity) * dt
        radius = max(0, radius + radiusVelocity * dt)

        if !isOpen && radius < 1 {
            finishClosing()
            return
        }
        if spreading && radius >= fullRadius * 0.97, let done = spreadDone {
            spreadDone = nil
            timer?.invalidate()
            timer = nil
            done()
            return
        }
        draw(time: now - started)
    }

    private func draw(time: CFTimeInterval) {
        // Stretch along the direction of travel, keeping the area about the same, plus a faint
        // breathing so it never looks frozen.
        let speed = hypot(velocity.dx, velocity.dy)
        let stretch = min(0.2, speed / 6000)
        let angle = atan2(velocity.dy, velocity.dx)
        let breath = 1 + 0.01 * CGFloat(sin(time * 2.6))
        let scale = radius / Portal.size * breath
        let sx = scale * (1 + stretch), sy = scale / (1 + stretch * 0.8)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shape = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle).scaledBy(x: sx, y: sy)
        let path = CGMutablePath()
        path.addRect(picture.bounds)
        path.addEllipse(in: CGRect(x: -Portal.size, y: -Portal.size, width: Portal.size * 2, height: Portal.size * 2), transform: shape)
        hole.frame = picture.bounds
        hole.path = path

        bubble.position = center
        bubble.setAffineTransform(CGAffineTransform(rotationAngle: angle).scaledBy(x: sx, y: sy))
        // The film turns slowly; the glint stays top left whichever way the bubble points.
        film.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(time * 0.5) - angle))
        highlight.setAffineTransform(CGAffineTransform(rotationAngle: -angle))
        // Fades as it grows past its usual size, so spreading reads as the picture dissolving away.
        let beyond = max(0, radius - Portal.size) / (Portal.size * 1.5)
        bubble.opacity = Float(min(1, radius / 30) * max(0, 1 - beyond))
        CATransaction.commit()
    }

    private func finishClosing() {
        timer?.invalidate()
        timer = nil
        closingIn = false
        radius = 0
        radiusVelocity = 0
        picture.mask = nil
        bubble.isHidden = true
        window.isOpaque = true
        window.backgroundColor = .black
    }
}
