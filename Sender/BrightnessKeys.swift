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

    private var tap: CFMachPort?
    private var retry: Timer?

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which leads to Privacy & Security → Accessibility.
    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { remove() }
    }

    private func install() {
        guard tap == nil else { return }
        let systemDefined: UInt32 = 14 // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << systemDefined),
                                          callback: brightnessKeyCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // Not allowed yet; keep trying, so it starts working as soon as permission is given.
            if retry == nil {
                retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard BrightnessKeys.isAllowed else { return }
                    self?.retry?.invalidate()
                    self?.retry = nil
                    self?.install()
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        log("brightness keys: listening")
    }

    private func remove() {
        retry?.invalidate()
        retry = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Aux control buttons: data1 holds the key in the high 16 bits and its state below.
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0x0A
        let brightnessUp = 2, brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        guard key == brightnessUp || key == brightnessDown, let target = targetDisplay(), pointerIsOn(target, event) else {
            return Unmanaged.passUnretained(event)
        }
        if isDown {
            let fine = ns.modifierFlags.contains([.option, .shift])
            DispatchQueue.main.async { self.onPress(key == brightnessUp ? 1 : -1, fine) }
        }
        return nil
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

@available(macOS 14, *)
private func brightnessKeyCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                   _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<BrightnessKeys>.fromOpaque(info).takeUnretainedValue().handle(type, event)
}
