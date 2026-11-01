import CoreGraphics
import Foundation

/// A virtual display sized to match the receiver's panel: Retina, with "looks like" sizes, when
/// the panel is Retina; otherwise plain resolutions like any ordinary monitor. It exists for as
/// long as this object is alive, so dropping it is the equivalent of unplugging the monitor.
@available(macOS 14, *)
final class VirtualScreen {
    let display: CGVirtualDisplay
    let hello: Hello
    var displayID: CGDirectDisplayID { display.displayID }
    /// The panel is sharp enough for macOS to draw at twice the "looks like" size.
    let isRetina: Bool

    /// Whether this display already fits a receiver, so it can be kept across a reconnect.
    func matches(_ other: Hello) -> Bool {
        hello.width == other.width && hello.height == other.height && hello.name == other.name
    }

    init?(hello: Hello) {
        let retina = VirtualScreen.isRetina(hello)
        let modes = VirtualScreen.modes(nativeWidth: hello.width, nativeHeight: hello.height, retina: retina)
        let largest = modes.max { $0.0 < $1.0 }!
        let scale = retina ? 2 : 1

        let d = CGVirtualDisplayDescriptor()
        d.queue = .main
        d.name = hello.name
        // HiDPI modes render at 2x the "looks like" size, so allow room for the largest one.
        d.maxPixelsWide = UInt32(largest.0 * scale)
        d.maxPixelsHigh = UInt32(largest.1 * scale)
        d.sizeInMillimeters = CGSize(width: hello.mmWide, height: hello.mmHigh)
        // A stable identity lets macOS remember the arrangement and chosen resolution.
        d.vendorID = 0x5F5
        d.productID = 0x5000
        d.serialNum = VirtualScreen.stableSerial(hello.name)
        // Display P3, like Apple's panels.
        d.redPrimary = CGPoint(x: 0.680, y: 0.320)
        d.greenPrimary = CGPoint(x: 0.265, y: 0.690)
        d.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        d.terminationHandler = { _, _ in log("virtual display terminated by the system") }

        guard let display = CGVirtualDisplay(descriptor: d) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = retina ? 1 : 0
        settings.modes = modes.map { CGVirtualDisplayMode(width: UInt32($0.0), height: UInt32($0.1), refreshRate: 60) }
        guard display.apply(settings) else { return nil }
        self.display = display
        self.hello = hello
        isRetina = retina
        log("virtual display \(display.displayID) created: \(hello.name), \(retina ? "Retina" : "standard"), modes \(modes.map { "\($0.0)x\($0.1)" })")
    }

    struct Resolution {
        let mode: CGDisplayMode
        var width: Int { mode.width }
        var height: Int { mode.height }
        let isDefault: Bool
        let isCurrent: Bool
    }

    /// The sizes offered in System Settings, smallest first: "looks like" sizes on Retina.
    func resolutions() -> [Resolution] {
        let scale = isRetina ? 2 : 1
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return [] }
        let current = CGDisplayCopyDisplayMode(displayID)
        var seen = Set<Int>()
        return all
            .filter { $0.pixelWidth == $0.width * scale && $0.isUsableForDesktopGUI() }
            .sorted { $0.width < $1.width }
            .filter { seen.insert($0.width).inserted }
            .map { Resolution(mode: $0, isDefault: $0.width == hello.width / scale,
                              isCurrent: $0.width == current?.width && $0.pixelWidth == current?.pixelWidth) }
    }

    func use(_ resolution: Resolution) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, resolution.mode, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    /// Retina-class panels are around 220 pixels per inch; ordinary monitors around 100.
    static func isRetina(_ hello: Hello) -> Bool {
        guard hello.mmWide > 0 else { return hello.width >= 3840 }
        return Double(hello.width) / (hello.mmWide / 25.4) >= 150
    }

    /// Sizes offered in System Settings, the default first. On Retina, the "looks like" sizes
    /// macOS shows for a real Retina panel of this size, around half the native size. Otherwise
    /// the native size, and smaller ones for larger text (scaled up, so softer), as on a monitor.
    static func modes(nativeWidth: Int, nativeHeight: Int, retina: Bool) -> [(Int, Int)] {
        let base = Double(retina ? nativeWidth / 2 : nativeWidth)
        let factors = retina ? [1.0, 0.5, 0.625, 0.75, 0.8, 0.9, 1.125, 1.25, 1.5] : [1.0, 0.625, 0.75, 0.8, 0.9]
        var seen = Set<Int>()
        return factors.compactMap { f in
            let w = Int((base * f / 8).rounded()) * 8
            let h = Int((Double(w) * Double(nativeHeight) / Double(nativeWidth) / 2).rounded()) * 2
            return seen.insert(w).inserted ? (w, h) : nil
        }
    }

    private static func stableSerial(_ name: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }
}
