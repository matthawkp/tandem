import AppKit
import Carbon.HIToolbox

/// Control-Option with a number or an arrow chooses which Mac the display Mac shows, like the input
/// buttons on a monitor. ⌃⌥1 shows Mac 1, ⌃⌥2 Mac 2, and ⌃⌥← and ⌃⌥→ step through the Macs that
/// are connected. They only do this while more than one Mac is connected; otherwise the keys are
/// left alone, as window managers such as Rectangle use ⌃⌥← and ⌃⌥→.
enum SwitchKey {
    /// By position, so they're the same keys whatever the keyboard layout.
    static let numbers: [Int64] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                   kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map(Int64.init)
    static let codes = numbers + [Int64(kVK_LeftArrow), Int64(kVK_RightArrow)]

    /// What a key pressed with Control-Option asks for, if it's one of these. The number is only
    /// for `.number`.
    static func request(for keyCode: Int64) -> (Wire.Show, Int)? {
        if keyCode == kVK_LeftArrow { return (.previous, 0) }
        if keyCode == kVK_RightArrow { return (.next, 0) }
        if let index = numbers.firstIndex(of: keyCode) { return (.number, index + 1) }
        return nil
    }

    /// For a key down or up with exactly Control and Option held.
    static func request(for event: CGEvent) -> (Wire.Show, Int)? {
        guard event.type == .keyDown || event.type == .keyUp, event.modifierKeys == .peekKeys else { return nil }
        return request(for: event.getIntegerValueField(.keyboardEventKeycode))
    }
}

/// The switching keys on an extending Mac's own keyboard, as system-wide hot keys: they need no
/// permission, and cost other keys nothing. Only registered while `enabled`, i.e. while the
/// display Mac has more than one Mac connected.
final class SwitchHotKeys {
    var onPress: (Wire.Show, Int) -> Void = { _, _ in }
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { register() } else { unregister() }
        }
    }

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x546E_646D // "Tndm"

    private func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
                guard let event, let info else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == SwitchHotKeys.signature else { return OSStatus(eventNotHandledErr) }
                Unmanaged<SwitchHotKeys>.fromOpaque(info).takeUnretainedValue().pressed(Int(id.id))
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let modifiers = UInt32(controlKey | optionKey)
        for (index, code) in SwitchKey.codes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            if RegisterEventHotKey(UInt32(code), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                hotKeys.append(ref)
            }
        }
        log("switching keys: \(hotKeys.count) of \(SwitchKey.codes.count) registered")
    }

    private func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
    }

    private func pressed(_ index: Int) {
        guard SwitchKey.codes.indices.contains(index), let request = SwitchKey.request(for: SwitchKey.codes[index]) else { return }
        onPress(request.0, request.1)
    }
}
