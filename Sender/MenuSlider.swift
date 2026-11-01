import AppKit

/// A slider cell that always draws the active look. A menu's window never becomes key, so a
/// standard slider in a menu draws its track grey, as if disabled.
final class MenuSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        var fill = bar
        fill.size.width = max(0, knobRect(flipped: flipped).midX - bar.minX)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        // The standard tick marks go with the standard bar, so draw them too.
        NSColor.tertiaryLabelColor.setFill()
        for i in 0..<numberOfTickMarks {
            let tick = rectOfTickMark(at: i)
            NSBezierPath(ovalIn: NSRect(x: tick.midX - 1.5, y: flipped ? bar.maxY + 3 : bar.minY - 6, width: 3, height: 3)).fill()
        }
    }
}
