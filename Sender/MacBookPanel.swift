import Foundation

/// What the MacBook's own panel is doing, so the iMac can match it.
@available(macOS 14, *)
enum MacBookPanel {
    private static let client: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let type = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else { return nil }
        return type.init()
    }()
    private static let copyProperty = NSSelectorFromString("copyPropertyForKey:")

    /// Brightness slider position, 0–1. Nil when the lid is closed.
    static func brightness() -> Float? {
        BuiltInBrightness.get()
    }

    /// The colour matrix macOS applies to the built-in panel for True Tone and Night Shift:
    /// row-major, linear light. Nil if unavailable.
    static func colorMatrix() -> [Float]? {
        guard let client, client.responds(to: copyProperty),
              let ramp = client.perform(copyProperty, with: "ColorRamp")?.takeRetainedValue() as? [String: Any],
              let target = ramp["ColorRampTarget"] as? [Any], target.count == 9
        else { return nil }
        let values = target.compactMap { v -> Float? in
            if let n = v as? NSNumber { return n.floatValue }
            return (v as? String).flatMap(Float.init)
        }
        return values.count == 9 && values.allSatisfy({ $0.isFinite && abs($0) < 4 }) ? values : nil
    }
}
