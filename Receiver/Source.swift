import Foundation

/// One Mac connected over the cable. An iMac has two Thunderbolt ports, so two Macs can extend
/// onto it at once. Like a monitor with two inputs, it shows one at a time; the other keeps its
/// display, and the windows on it, but stops sending its picture until it's shown.
///
/// What it last asked for (brightness, colour, its pointer, whether it takes the keyboard and
/// mouse) is kept, so showing it again puts all of that back at once.
final class Source {
    let channel: MessageChannel

    // Main thread.
    var peer: Peer?
    /// Its number for ⌃⌥1, ⌃⌥2…; 0 until it has said who it is.
    var number = 0
    var canSwap = false
    var takesFiles = false
    var inputState: Wire.InputState = .off
    var display: DisplayState?
    var cursorShape: CursorShape?
    var cursorPosition: CursorPosition?
    /// Why it has no picture, if it said; cleared by its next frame.
    var status: String?
    /// It went to sleep, or turned its screens off, and said so.
    var asleep = false
    /// It has a picture to show, as far as it has said.
    var hasPicture: Bool { !asleep && status == nil }

    var name: String { peer?.name ?? "Mac" }
    var kind: String { peer?.kind ?? "Mac" }

    init(channel: MessageChannel) {
        self.channel = channel
    }

    // For the network queue, which draws frames as they come.
    private let lock = NSLock()
    private var shown = false
    private var sawFrame = false

    /// Whether its picture is the one on screen.
    var isShown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shown
    }

    func setShown(_ shown: Bool) {
        lock.lock()
        self.shown = shown
        sawFrame = false
        lock.unlock()
    }

    /// It said why it has no picture, or went to sleep: its next frame starts the picture again.
    func pictureStopped() {
        lock.lock()
        sawFrame = false
        lock.unlock()
    }

    /// For each frame: whether to draw it, and whether it's the first since being shown or since
    /// its picture stopped.
    func frameArrived() -> (draw: Bool, first: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard shown else { return (false, false) }
        let first = !sawFrame
        sawFrame = true
        return (true, first)
    }
}

/// Each Mac this one has shown keeps the same number, so ⌃⌥1 is always the same Mac: the first
/// seen is 1, the next 2, and so on. A Mac new to a full list takes the place of one that isn't
/// connected.
enum MacNumbers {
    private static let key = "macNumbers"
    private static let limit = SwitchKey.numbers.count

    static func number(for name: String, connected: [String]) -> Int {
        var names = UserDefaults.standard.stringArray(forKey: key) ?? []
        if let index = names.firstIndex(of: name) { return index + 1 }
        if names.count < limit {
            names.append(name)
        } else if let index = names.firstIndex(where: { !connected.contains($0) }) {
            names[index] = name
        } else {
            return 0
        }
        UserDefaults.standard.set(names, forKey: key)
        return names.firstIndex(of: name)! + 1
    }

    /// The name of the Mac with this number, connected or not.
    static func name(of number: Int) -> String? {
        let names = UserDefaults.standard.stringArray(forKey: key) ?? []
        return names.indices.contains(number - 1) ? names[number - 1] : nil
    }
}
