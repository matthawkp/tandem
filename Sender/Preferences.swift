import Foundation

/// Choices from the menu, remembered between launches.
@available(macOS 14, *)
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    var sleepsReceiver: Bool {
        get { bool("sleepsReceiver", true) }
        set { defaults.set(newValue, forKey: "sleepsReceiver") }
    }
    var wakesReceiver: Bool {
        get { bool("wakesReceiver", true) }
        set { defaults.set(newValue, forKey: "wakesReceiver") }
    }
    var followsBrightness: Bool {
        get { bool("followsBrightness", true) }
        set { defaults.set(newValue, forKey: "followsBrightness") }
    }
    /// How much brighter or dimmer than this Mac the display Mac should be.
    var brightnessOffset: Float {
        get { defaults.float(forKey: "brightnessOffset") }
        set { defaults.set(newValue, forKey: "brightnessOffset") }
    }
    var matchesColor: Bool {
        get { bool("matchesColor", true) }
        set { defaults.set(newValue, forKey: "matchesColor") }
    }
    var quality: TileEncoder.Quality {
        get { defaults.string(forKey: "quality").flatMap(TileEncoder.Quality.init) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }
    /// The brightness keys change the display Mac while the pointer is on it.
    var brightnessKeysFollowPointer: Bool {
        get { bool("brightnessKeysFollowPointer", true) }
        set { defaults.set(newValue, forKey: "brightnessKeysFollowPointer") }
    }
    /// The display Mac's keyboard and mouse can control this Mac.
    var usesReceiverInput: Bool {
        get { bool("usesReceiverInput", true) }
        set { defaults.set(newValue, forKey: "usesReceiverInput") }
    }
    /// Multipliers on the display Mac's own tracking and scrolling speeds.
    var pointerSpeed: Double {
        get { defaults.object(forKey: "pointerSpeed") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "pointerSpeed") }
    }
    var scrollSpeed: Double {
        get { defaults.object(forKey: "scrollSpeed") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "scrollSpeed") }
    }
    var reversesScrolling: Bool {
        get { bool("reversesScrolling", false) }
        set { defaults.set(newValue, forKey: "reversesScrolling") }
    }
    var cameraMode: CameraSwitcher.Mode {
        get {
            // Before Tandem, the choices were named after the two Macs.
            let legacy = ["iMac": "remote", "macBook": "local"]
            let raw = defaults.string(forKey: "cameraMode").map { legacy[$0] ?? $0 }
            return raw.flatMap(CameraSwitcher.Mode.init) ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: "cameraMode") }
    }
    var cameraPace: CameraSwitcher.Pace {
        get { defaults.string(forKey: "cameraPace").flatMap(CameraSwitcher.Pace.init) ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "cameraPace") }
    }
    /// Tandem Camera is installed for other apps to use.
    var offersCamera: Bool {
        get { bool("offersCamera", true) }
        set { defaults.set(newValue, forKey: "offersCamera") }
    }
    var askedForAccessibility: Bool {
        get { bool("askedForAccessibility", false) }
        set { defaults.set(newValue, forKey: "askedForAccessibility") }
    }
    var hasLaunchedBefore: Bool {
        get { bool("hasLaunchedBefore", false) }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }
}
