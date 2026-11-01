// Draws Tandem's icon. Run Tools/make-icons.sh, which writes Resources/Tandem.icns.
//
// Two Macs side by side, a display and a laptop in front, with one picture running across
// both screens: the two working as one.
import AppKit

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// A screen: silver bezel and a vivid gradient panel. The gradient spans `picture`, so screens
/// sharing one show one continuous image.
func screen(_ ctx: CGContext, _ r: CGRect, bezel: CGFloat, radius: CGFloat, picture: CGRect) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.45))
    ctx.addPath(roundedRect(r, radius)); ctx.setFillColor(color(0xE8EBF2)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(r, radius)); ctx.clip()
    linear(ctx, [color(0xF7F8FB), color(0xC9CED9)], from: CGPoint(x: r.midX, y: r.maxY), to: CGPoint(x: r.midX, y: r.minY))
    ctx.restoreGState()

    let panel = r.insetBy(dx: bezel, dy: bezel)
    ctx.saveGState()
    ctx.addPath(roundedRect(panel, max(radius - bezel, 4))); ctx.clip()
    linear(ctx, [color(0x2EE6D6), color(0x3A7BFF), color(0x8E4DFF)], from: CGPoint(x: picture.minX, y: picture.maxY), to: CGPoint(x: picture.maxX, y: picture.minY))
    // Soft highlight across the glass.
    linear(ctx, [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)], from: CGPoint(x: panel.minX, y: panel.maxY), to: CGPoint(x: panel.midX, y: panel.midY))
    ctx.restoreGState()

}

func draw() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Body: the standard macOS icon shape and margins.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(roundedRect(body, 185)); ctx.setFillColor(color(0x151A3A)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(body, 185)); ctx.clip()
    linear(ctx, [color(0x2A2F6E), color(0x10132C)], from: CGPoint(x: body.midX, y: body.maxY), to: CGPoint(x: body.midX, y: body.minY))
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x5B6CFF, 0.45), color(0x5B6CFF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0, endCenter: CGPoint(x: 512, y: 600), endRadius: 420, options: [])
    ctx.restoreGState()

    // Centre the pair in the body.
    ctx.translateBy(x: 20, y: 18)

    // The display on its stand, behind and to the right.
    let display = CGRect(x: 330, y: 410, width: 520, height: 330)
    let laptopLid = CGRect(x: 168, y: 262, width: 340, height: 214)
    let picture = display.union(laptopLid)
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: display.midX - 46, y: display.minY + 10))
    neck.addLine(to: CGPoint(x: display.midX + 46, y: display.minY + 10))
    neck.addLine(to: CGPoint(x: display.midX + 60, y: 300))
    neck.addLine(to: CGPoint(x: display.midX - 60, y: 300))
    neck.closeSubpath()
    ctx.addPath(neck); ctx.setFillColor(color(0xB9BFCC)); ctx.fillPath()
    ctx.addPath(roundedRect(CGRect(x: display.midX - 120, y: 282, width: 240, height: 26), 13)); ctx.setFillColor(color(0xD5DAE3)); ctx.fillPath()
    screen(ctx, display, bezel: 18, radius: 32, picture: picture)

    // The laptop in front, lower left.
    screen(ctx, laptopLid, bezel: 12, radius: 22, picture: picture)
    let base = CGMutablePath()
    base.move(to: CGPoint(x: laptopLid.minX - 34, y: laptopLid.minY))
    base.addLine(to: CGPoint(x: laptopLid.maxX + 34, y: laptopLid.minY))
    base.addLine(to: CGPoint(x: laptopLid.maxX + 22, y: laptopLid.minY - 22))
    base.addLine(to: CGPoint(x: laptopLid.minX - 22, y: laptopLid.minY - 22))
    base.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.4))
    ctx.addPath(base); ctx.setFillColor(color(0xD9DDE6)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(CGRect(x: laptopLid.midX - 40, y: laptopLid.minY - 8, width: 80, height: 8), 4)); ctx.setFillColor(color(0xAEB4C1)); ctx.fillPath()
    NSGraphicsContext.current = nil
    return rep
}

let out = CommandLine.arguments[1]
try! draw().representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/Tandem.png"))
