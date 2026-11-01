import AppKit
import ApplicationServices

/// Which window an Accessibility window element is. Private, but long-standing and what every
/// window manager uses: there's no public way to match the two.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// What's on screen at a point: which window, and in the Finder which item or folder. Used to
/// tell a double-click on empty wallpaper from one on an icon, to bring a window opened from the
/// bubble under it, and to drop a file pulled through it into the folder it was let go over.
/// Everything past the window list needs Accessibility. Points are global, from the top left.
enum ScreenProbe {
    struct Window {
        var id: CGWindowID
        var pid: pid_t
        var layer: Int
        var bounds: CGRect
        var isFinder: Bool { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" }
        /// The Finder's desktop, with its icons, below every window.
        var isDesktop: Bool { layer < 0 }
    }

    /// On-screen windows, front to back, other than this app's.
    static func windows() -> [Window] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return Window(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// The window under a point: an ordinary window, or the desktop. The menu bar, Dock and other
    /// things above windows don't count.
    static func window(at point: CGPoint) -> Window? {
        windows().first { $0.layer <= 0 && $0.bounds.contains(point) && ($0.layer == 0 || $0.isFinder) }
    }

    /// The Finder item at a point, if there's one: its file URL.
    static func finderItem(at point: CGPoint, in window: Window) -> URL? {
        guard let element = element(at: point, pid: window.pid) else { return nil }
        // An icon, or its name under it; not the window or desktop around them.
        var current: AXUIElement? = element
        for _ in 0..<3 {
            guard let el = current else { break }
            let role = string(el, kAXRoleAttribute) ?? ""
            if ["AXWindow", "AXScrollArea", "AXSplitGroup", "AXOutline", "AXBrowser"].contains(role) { return nil }
            if let url = url(el, kAXURLAttribute) { return url }
            current = parent(el)
        }
        return nil
    }

    /// The folder shown by the Finder window at a point, asked of the Finder itself: its windows
    /// don't say through Accessibility. Front to back, so it's the one on top. Needs permission to
    /// control the Finder, and blocks while it answers.
    static func finderFolder(at point: CGPoint) -> URL? {
        let x = Int(point.x), y = Int(point.y)
        let script = """
            tell application "Finder"
                -- By number, front to back. Never "item" (even hidden in "repeat with w in"):
                -- to the Finder, an item is a file.
                repeat with i from 1 to (count of Finder windows)
                    set {l, t, r, bt} to bounds of Finder window i
                    if \(x) ≥ l and \(x) < r and \(y) ≥ t and \(y) < bt then
                        try
                            return POSIX path of (target of Finder window i as alias)
                        end try
                        return ""
                    end if
                end repeat
            end tell
            """
        guard let path = osascript(script), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Runs an AppleScript in osascript, which can be used off the main thread, unlike
    /// NSAppleScript. Its output, or nil if it failed (which is logged).
    @discardableResult
    static func osascript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            log("osascript: \(error.localizedDescription)")
            return nil
        }
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            log("osascript: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The main screen less its menu bar and Dock, in the same coordinates. On the main thread.
    static func usableArea() -> CGRect {
        guard let screen = NSScreen.screens.first else { return CGDisplayBounds(CGMainDisplayID()) }
        let visible = screen.visibleFrame
        // While Tandem hides the menu bar, the visible frame includes its strip; it shows again as
        // soon as another app is in front.
        let top = max(screen.frame.maxY - visible.maxY, NSStatusBar.system.thickness)
        return CGRect(x: visible.minX, y: top, width: visible.width, height: screen.frame.maxY - top - (visible.minY - screen.frame.minY))
    }

    /// Moves a window so it's centred on a point, kept within `area` (see `usableArea`).
    static func move(_ window: Window, centredOn point: CGPoint, within area: CGRect) {
        guard let ax = axWindow(window) else { return }
        let size = window.bounds.size
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
        origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, value)
    }

    // MARK: Accessibility

    private static func element(at point: CGPoint, pid: pid_t) -> AXUIElement? {
        var element: AXUIElement?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    private static func axWindow(_ window: Window) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { ax in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(ax, &id) == .success && id == window.id
        }
    }

    private static func parent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// A URL attribute, which apps give as a URL or as a string.
    private static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let url = value as? URL { return url.isFileURL ? url : nil }
        if let string = value as? String, let url = URL(string: string), url.isFileURL { return url }
        return nil
    }
}
