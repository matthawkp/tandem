import CoreGraphics
import Foundation

/// The built-in panel's brightness (0–1), through the private DisplayServices framework that
/// the brightness keys and Control Center use.
enum BuiltInBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    /// The built-in panel, if it's on (not when a MacBook's lid is closed).
    static var displayID: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }

    /// There is a built-in panel, even if it's asleep right now.
    static var hasPanel: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard getter != nil, CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let getter, let id = displayID else { return nil }
        var value: Float = -1
        return getter(id, &value) == 0 && value >= 0 ? value : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let setter, let id = displayID else { return false }
        return setter(id, min(max(value, 0), 1)) == 0
    }
}
