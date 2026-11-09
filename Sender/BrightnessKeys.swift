import AppKit
import ApplicationServices

/// While the pointer is on the iMac, the MacBook's brightness keys change the iMac instead.
///
/// The keys arrive as system-defined events, which an event tap can see and stop before macOS
/// acts on them. A tap that can stop events needs Accessibility permission.
@available(macOS 14, *)
final class BrightnessKeys {
    /// The iMac's display, if connected.
    var targetDisplay: () -> CGDirectDisplayID? = { nil }
    /// Called with +1 or -1 steps, and whether Option-Shift asked for a finer step.
    var onPress: (_ direction: Float, _ fine: Bool) -> Void = { _, _ in }

    private lazy var tap = EventTap { [unowned self] _, event in self.handle(event) ? nil : event }
    private var retry: Timer?

    func setEnabled(_ enabled: Bool) {
        retry?.invalidate()
        retry = nil
        guard enabled else { return tap.stop() }
        tap.watch([EventTap.systemDefined])
        guard !Accessibility.isAllowed else { return log("brightness keys: listening") }
        // Not allowed yet; keep trying, so it starts working as soon as permission is given.
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, Accessibility.isAllowed else { return }
            self.retry?.invalidate()
            self.retry = nil
            self.tap.watch([EventTap.systemDefined])
            log("brightness keys: listening")
        }
    }

    /// True if the key was used up, so macOS doesn't act on it.
    private func handle(_ event: CGEvent) -> Bool {
        // Aux control buttons: data1 holds the key in the high 16 bits and its state below.
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return false }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0x0A
        let brightnessUp = 2, brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        guard key == brightnessUp || key == brightnessDown, let target = targetDisplay(), pointerIsOn(target, event) else { return false }
        if isDown {
            let fine = ns.modifierFlags.contains([.option, .shift])
            DispatchQueue.main.async { self.onPress(key == brightnessUp ? 1 : -1, fine) }
        }
        return true
    }

    private func pointerIsOn(_ display: CGDirectDisplayID, _ event: CGEvent) -> Bool {
        // Where the pointer is now, not the event's location: keys from the iMac's keyboard are
        // posted without one, which reads as the top left of the main screen.
        guard let location = CGEvent(source: nil)?.location else { return false }
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(location, 1, &id, &count)
        return count > 0 && id == display
    }
}
