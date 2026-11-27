import AppKit
import IOKit.pwr_mgt
import Network

struct ReceiverOptions {
    var windowedSize: (Int, Int)?
    var port = Wire.port

    init(arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--windowed":
                // --windowed 5120x2880: run in a normal window, pretending to be a panel of that size.
                let parts = (it.next() ?? "").split(separator: "x").compactMap { Int($0) }
                windowedSize = parts.count == 2 ? (parts[0], parts[1]) : (5120, 2880)
            case "--port":
                port = it.next().flatMap(UInt16.init) ?? port
            default: break
            }
        }
    }
}

final class FullScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class StreamView: NSView {
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// While streaming, this Mac's own pointer is meaningless, so keep it invisible.
    var hidesCursor = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func resetCursorRects() {
        if hidesCursor { addCursorRect(bounds, cursor: StreamView.blankCursor) }
    }

    /// Files dropped on the picture go to the other Mac, when it takes them.
    var acceptsFiles: () -> Bool = { false }
    /// Where they were let go, as fractions of the picture from the top left.
    var onDropFiles: ([URL], CGPoint) -> Void = { _, _ in }
    /// Files dragged over the picture, before they're dropped.
    var onDragFiles: ([URL]) -> Void = { _ in }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(sender)
        guard acceptsFiles(), !urls.isEmpty else { return [] }
        onDragFiles(urls)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFiles() && !fileURLs(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard acceptsFiles(), !urls.isEmpty, bounds.width > 0, bounds.height > 0 else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onDropFiles(urls, CGPoint(x: point.x / bounds.width, y: 1 - point.y / bounds.height))
        return true
    }

    /// Esc quits only from the waiting screen; with a picture up, it's a monitor.
    var quitsOnEscape: () -> Bool = { true }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && quitsOnEscape() { NSApp.terminate(nil) } else { super.keyDown(with: event) }
    }
}

/// Full-screen receiver. Listens on the network (advertised over Bonjour), tells the sender
/// its panel size, then draws whatever arrives pixel-for-pixel.
final class ReceiverApp: NSObject, NSApplicationDelegate {
    private let options = ReceiverOptions(arguments: CommandLine.arguments)
    private let netQueue = DispatchQueue(label: "net", qos: .userInteractive)
    private var window: NSWindow!
    private var streamView: StreamView!
    private var cursorHidden = false
    private var splash: SplashView!
    /// The other Mac's pointer, drawn here so it moves without waiting for frames.
    private var cursorOverlay: CursorOverlay!
    private var peek: PeekSession!
    private var lastStatus: String?
    private var renderer: Renderer!
    private var input: InputCapture!
    private var hello: Hello!
    private var listener: NWListener?
    /// Every Mac connected, one per Thunderbolt port, and the one shown. The rest wait, keeping
    /// their displays, until they're shown.
    private var sources: [Source] = []
    private var active: Source?
    /// The shown Mac's connection.
    private var channel: MessageChannel? { active?.channel }
    /// The Mac last chosen with ⌃⌥ and a number or arrow: shown again whenever it connects.
    private var chosenMac: String? {
        get { UserDefaults.standard.string(forKey: "chosenMac") }
        set { UserDefaults.standard.set(newValue, forKey: "chosenMac") }
    }
    /// In case a Mac that's been shown never sends a picture.
    private var pictureCheck: DispatchWorkItem?
    private var sleepAssertion: IOPMAssertionID = 0
    private var disconnectedSleep: DisconnectedSleep?
    private let camera = CameraServer()
    /// What the other Mac last asked for; reapplied when the screen wakes.
    private var wantedBrightness: Float?
    private var activityAssertion: IOPMAssertionID = 0
    /// The other Mac is asleep and turned this screen off; it may wake it again.
    private var asleepWithMac = false
    /// The Mac whose display this shows, for wording.
    private var peerKind = Peer.last?.kind ?? "Mac"
    /// The connected Mac can become a display, so the two can swap roles in one go.
    private var senderCanSwap: Bool { active?.canSwap ?? false }
    private let fileSender = FileSender()
    private var hud: InputHUD!
    private lazy var permissionsWindow: PermissionsWindow = {
        let permissions = PermissionsWindow(role: .display)
        permissions.beforeOpeningSettings = { [weak self] in self?.getOutOfTheWay() }
        return permissions
    }()
    /// The other Mac takes files pulled through the bubble.
    private var senderTakesFiles: Bool { active?.takesFiles ?? false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let screen = NSScreen.main!
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let mm = CGDisplayScreenSize(displayID)
        let name = Machine.name

        let frame: NSRect
        if let (w, h) = options.windowedSize {
            hello = Hello(width: w, height: h, mmWide: mm.width, mmHigh: mm.height, name: name)
            frame = NSRect(x: 100, y: 100, width: 1280, height: 720)
            window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Tandem (\(w)×\(h))"
        } else {
            let (w, h) = Self.panelPixels(of: screen)
            hello = Hello(width: w, height: h, mmWide: mm.width, mmHigh: mm.height, name: name)
            frame = screen.frame
            window = FullScreenWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.level = .normal
            window.collectionBehavior = [.fullScreenPrimary]
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }

        guard let renderer = Renderer(width: hello.width, height: hello.height) else {
            fatalError("Metal is not available")
        }
        self.renderer = renderer

        let bounds = NSRect(origin: .zero, size: frame.size)
        let container = NSView(frame: bounds)
        container.wantsLayer = true

        let view = StreamView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer = renderer.layer
        renderer.layer.contentsScale = window.backingScaleFactor
        renderer.layer.contentsGravity = .resizeAspect
        container.addSubview(view)

        cursorOverlay = CursorOverlay(frame: bounds, streamSize: CGSize(width: hello.width, height: hello.height))
        cursorOverlay.autoresizingMask = [.width, .height]
        container.addSubview(cursorOverlay)

        splash = SplashView(frame: bounds, footerText: "\(name)  ·  \(hello.width) × \(hello.height)  ·  Press Esc to quit")
        splash.onSettings = { [weak self] button in self?.showSettings(from: button) }
        splash.autoresizingMask = [.width, .height]
        container.addSubview(splash)

        hud = InputHUD(frame: .zero)
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -frame.height * 0.16),
        ])

        window.contentView = container
        input = InputCapture(window: window, hud: hud)
        input.peerKind = peerKind
        input.send = { [weak self] event in self?.channel?.send(.input, event.encoded()) }
        peek = PeekSession(window: window, picture: view, overlay: cursorOverlay, input: input, playerQueue: netQueue)
        peek.send = { [weak self] body in self?.channel?.send(.peek, body) }
        peek.isStreaming = { [weak self] in self?.streaming ?? false }
        peek.setCursorHidden = { [weak self] hidden in self?.setCursorHidden(hidden) }
        peek.restoreFullScreen = { [weak self] in
            guard let self, self.options.windowedSize == nil else { return }
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        input.onPeekHold = { [weak self] in self?.peek.heldHere() }
        input.takesClick = { [weak self] event in self?.peek.takesClick(event) ?? false }
        input.onLocalMouse = { [weak self] in self?.peek.macPointerMovedLast = false }
        input.onSwitchKey = { [weak self] show, number in self?.switchKey(show, number) ?? false }
        cursorOverlay.onMove = { [weak self] in
            guard let self, self.cursorOverlay.hotspot != nil else { return }
            self.peek.macPointerMovedLast = true
        }
        view.quitsOnEscape = { [weak self] in
            guard let splash = self?.splash else { return true }
            return !splash.isHidden && splash.alphaValue > 0
        }
        streamView = view
        view.registerForDraggedTypes([.fileURL])
        view.acceptsFiles = { [weak self] in
            guard let self else { return false }
            return self.streaming && self.senderTakesFiles && self.channel != nil
        }
        view.onDragFiles = { [weak self] urls in
            guard let self else { return }
            self.hud.show("Copy \(Self.describe(urls)) to your \(self.peerKind)", "Let go where you want it.")
        }
        view.onDropFiles = { [weak self] urls, point in
            guard let self else { return }
            log("files: \(urls.count) dropped on the picture")
            self.hud.show("Copying \(Self.describe(urls)) to your \(self.peerKind)…", "")
            guard let channel = self.channel else { return }
            self.fileSender.send(urls, at: point, over: channel)
        }
        fileSender.onSent = { [weak self] name, sent in
            guard let self else { return }
            if sent {
                self.hud.show("Copied “\(name)” to your \(self.peerKind)", "")
            } else {
                self.hud.show("Couldn't copy “\(name)”", "Try dragging it again.")
            }
        }
        window.backgroundColor = .black
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        renderer.redraw()

        log("receiver \(hello.width)x\(hello.height), \(Int(mm.width))x\(Int(mm.height)) mm, \(name)")
        if options.windowedSize == nil { LoginItem.enableOnFirstLaunch() }
        // Everything this Mac will need, asked for once up front.
        if options.windowedSize == nil, !UserDefaults.standard.bool(forKey: "askedForPermissions") {
            UserDefaults.standard.set(true, forKey: "askedForPermissions")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.permissionsWindow.show(on: self.window.screen) }
        }
        showWaiting()
        if options.windowedSize == nil { disconnectedSleep = DisconnectedSleep() }
        startListening()
        if options.windowedSize == nil { camera.start(name: name) }
        MonitorMode.refresh { [weak self] in self?.sendSettings() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // Once it has settled: a change comes as several notices, and so does waking.
            self?.screenChangeWork?.cancel()
            let work = DispatchWorkItem { self?.screenChanged() }
            self?.screenChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.willSleep()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let brightness = self.wantedBrightness { BuiltInBrightness.set(brightness) }
            guard self.asleepWithMac else { return }
            if self.streaming {
                // Woken by hand while the other Mac is already back and streaming.
                self.setAsleepWithMac(false)
            } else if let channel = self.channel {
                // Woken by its own keyboard or mouse while the other Mac's screens are off but it's
                // still awake: wake that Mac too, as its own keyboard would.
                log("woken by hand, waking the \(self.peerKind)")
                channel.send(.power, Data([Wire.Power.wake.rawValue]))
            }
        }
    }

    /// The size of picture to ask for. At the default "looks like" setting the window's backing
    /// store is the panel's own pixels, so frames map 1:1 onto them. At a "More Space" setting
    /// the backing store is bigger than the panel (6400×3600 on a 5K iMac), and macOS scales it
    /// down: asking for that would send half as much again only to have it thrown away, so ask
    /// for the panel's own size instead.
    private static func panelPixels(of screen: NSScreen) -> (Int, Int) {
        let scale = screen.backingScaleFactor
        let backing = (Int(screen.frame.width * scale), Int(screen.frame.height * scale))
        guard scale >= 2, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return backing }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let nativeFlag: UInt32 = 0x0200_0000 // kDisplayModeNativeFlag, from IOKit's graphics types
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let native = modes.filter({ $0.ioFlags & nativeFlag != 0 }).max(by: { $0.pixelWidth < $1.pixelWidth }),
              native.pixelWidth > 0, native.pixelHeight > 0, native.pixelWidth < backing.0, backing.1 > 0
        else { return backing }
        // Only the same shape: some settings leave part of the panel out (below a notch, say).
        let shape = Double(native.pixelWidth) / Double(native.pixelHeight), backingShape = Double(backing.0) / Double(backing.1)
        guard abs(shape - backingShape) < 0.01 * backingShape else { return backing }
        return (native.pixelWidth, native.pixelHeight)
    }

    /// This Mac's display settings changed. The window follows its screen; and if the size of
    /// picture to ask for is different now, Tandem starts again, as everything is built for
    /// one size (and the other Mac's virtual display with it).
    private func screenChanged() {
        guard options.windowedSize == nil, let screen = window.screen ?? NSScreen.main else { return }
        let (w, h) = Self.panelPixels(of: screen)
        if (w, h) != (hello.width, hello.height) {
            log("this screen is now \(w)x\(h), was \(hello.width)x\(hello.height): starting again")
            input?.release(quietly: true)
            return relaunch()
        }
        if window.frame != screen.frame, peek?.isAway != true { window.setFrame(screen.frame, display: true) }
    }
    private var screenChangeWork: DispatchWorkItem?

    func applicationDidBecomeActive(_ notification: Notification) {
        // Back from this Mac's desktop, by the Dock icon.
        if peek?.isAway == true { return peek.comeBack() }
        // Back from System Settings: full screen again.
        guard options.windowedSize == nil, let window, !window.isVisible || NSApp.presentationOptions.isEmpty else { return }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        input?.release(quietly: true)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Tandem", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    // MARK: Settings

    private func showSettings(from button: NSView) {
        MonitorMode.refresh { [weak self] in self?.sendSettings() }
        settingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    /// This Mac's settings, shown from the waiting screen here and in the other Mac's Tandem menu.
    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(sectionHeader("Use This \(Machine.kind) as a Monitor"))
        menu.addItem(toggle("Open at Login", LoginItem.isEnabled, #selector(toggleLoginItem)))
        menu.addItem(toggle("Start Up After Power Failure", MonitorMode.restartsAfterPowerFailure, #selector(toggleAutoRestart)))
        let automaticLogin = item("Automatic Login…", #selector(openAutomaticLogin))
        automaticLogin.identifier = RemoteMenu.local
        menu.addItem(automaticLogin)
        if let disconnectedSleep {
            let sleepItem = NSMenuItem(title: "Sleep When No Mac Is Connected", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for minutes in DisconnectedSleep.choices {
                let title = minutes == 0 ? "Never" : minutes == 60 ? "After 1 Hour" : minutes == 1 ? "After 1 Minute" : "After \(minutes) Minutes"
                if minutes == 0 { sub.addItem(.separator()) }
                let choice = toggle(title, disconnectedSleep.minutes == minutes, #selector(chooseDisconnectedSleep(_:)))
                choice.tag = minutes
                sub.addItem(choice)
            }
            sleepItem.submenu = sub
            sleepItem.toolTip = "Until then this \(Machine.kind) stays awake, ready for your \(peerKind). Asleep, it can't be reached over the cable, so wake it with its power button."
            menu.addItem(sleepItem)
        }
        menu.addItem(.separator())
        // Opens a window here, so it's only useful at this Mac.
        let permissions = item("Permissions…", #selector(showPermissions))
        permissions.identifier = RemoteMenu.local
        menu.addItem(permissions)
        let switchRole = item(canSwap ? "Swap Roles with \(peerKind)…" : "Extend This Mac Instead…", #selector(switchRole))
        // The other Mac's menu has its own.
        switchRole.identifier = RemoteMenu.local
        menu.addItem(switchRole)
        let quit = item("Quit Tandem", #selector(NSApplication.terminate(_:)))
        quit.keyEquivalent = "q"
        quit.identifier = RemoteMenu.local
        menu.addItem(quit)
        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item: NSMenuItem
        if #available(macOS 14.0, *) {
            item = .sectionHeader(title: title)
        } else {
            item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        item.identifier = RemoteMenu.header
        return item
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    @objc private func chooseDisconnectedSleep(_ item: NSMenuItem) {
        disconnectedSleep?.minutes = item.tag
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func toggleAutoRestart() {
        MonitorMode.setRestartsAfterPowerFailure(!MonitorMode.restartsAfterPowerFailure) { [weak self] in self?.sendSettings() }
    }

    /// A Mac has said who it is. It's shown if it's the one last chosen, or if the one shown has
    /// nothing to show; otherwise it waits, and the HUD says how to show it.
    private func met(_ peer: Peer, _ source: Source) {
        source.peer = peer
        if source.number == 0 {
            source.number = MacNumbers.number(for: peer.name, connected: sources.compactMap { $0.peer?.name })
        }
        log("\(peer.name), a \(peer.kind), is Mac \(source.number)")
        defer {
            sendSettings(to: source)
            sendLineup()
        }
        // The same Mac again, before its last connection has timed out: this one takes its place.
        if let stale = sources.first(where: { $0 !== source && $0.peer?.name == peer.name }) {
            log("\(peer.name) connected again, dropping its last connection")
            if active === stale { show(source, quietly: true) }
            // Gone from the lineup now, rather than once it has closed.
            sources.removeAll { $0 === stale }
            stale.channel.cancel()
        }
        if active === source {
            // The only Mac, so it's the one to come back to when another has been shown since.
            if sources.count == 1 { chosenMac = peer.name }
            return showingPeer(peer)
        }
        guard let active else { return }
        if peer.name == chosenMac && active.name != chosenMac {
            show(source, clearing: !streaming)
        } else if !active.hasPicture {
            show(source, clearing: true)
        } else if source.number > 0 {
            hud.show("\(peer.name) is connected too", "Press ⌃⌥\(source.number) to show it, and ⌃⌥\(active.number) to come back.")
        }
    }

    /// Wording for the Mac shown.
    private func showingPeer(_ peer: Peer) {
        Peer.last = peer
        peerKind = peer.kind
        splash.peerKind = peer.kind
        input.peerKind = peer.kind
    }

    private static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    /// Lets the other Macs show this Mac's settings in their own Tandem menus.
    private func sendSettings(to only: Source? = nil) {
        guard !sources.isEmpty, let data = try? JSONEncoder().encode(RemoteMenu(settingsMenu())) else { return }
        for source in only.map({ [$0] }) ?? sources { source.channel.send(.settings, data) }
    }

    /// A setting chosen from the other Mac's menu: chosen here, then the new state sent back.
    private func chooseSetting(_ choice: RemoteMenu.Choice) {
        guard let (menu, index) = RemoteMenu.item(for: choice, in: settingsMenu()) else {
            log("settings: \(choice.title) has gone from the menu")
            return sendSettings()
        }
        log("settings: \(choice.title), chosen from the \(peerKind)")
        menu.performActionForItem(at: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.sendSettings() }
    }

    /// Not with another Mac connected too, which would lose its display.
    private var canSwap: Bool { channel != nil && sources.count == 1 && senderCanSwap && Role.canExtend }

    @objc private func switchRole() {
        let alert = NSAlert()
        let swap = canSwap
        if swap {
            alert.messageText = "Swap roles with the \(peerKind)?"
            alert.informativeText = "This \(Machine.kind) will extend onto the \(peerKind), which becomes its display. Both Macs restart Tandem to swap."
            alert.addButton(withTitle: "Swap Roles")
        } else {
            alert.messageText = "Extend this \(Machine.kind) instead?"
            alert.informativeText = "It will stop being a display, and use another Mac's screen as its own extra display instead."
            alert.addButton(withTitle: "Extend This Mac")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The other Mac may have gone while the alert was up.
        guard swap, canSwap, let channel else { return Role.switchTo(.extend) }
        log("asking \(peerKind) to swap roles")
        channel.sendSoon(.swap, Data([Wire.Swap.now.rawValue])) { Role.switchTo(.extend) }
    }

    @objc private func showPermissions() {
        permissionsWindow.show(on: window.screen)
    }

    /// Full screen would hide System Settings.
    private func getOutOfTheWay() {
        NSApp.presentationOptions = []
        window.orderBack(nil)
    }

    @objc private func openAutomaticLogin() {
        getOutOfTheWay()
        MonitorMode.openAutomaticLoginSettings()
    }

    private func showWaiting() {
        splash.show(.waiting)
        setCursorHidden(false)
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        streamView.hidesCursor = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    private func startListening() {
        do {
            let listener = try NWListener(using: Wire.tcpParameters(allowWiFi: false), on: NWEndpoint.Port(rawValue: options.port)!)
            listener.service = NWListener.Service(name: hello.name, type: Wire.serviceType)
            let testing = options.windowedSize != nil
            listener.newConnectionHandler = { [weak self] connection in
                // Turned away before it can replace the Mac already connected.
                guard testing || Wire.cameOverThunderbolt(connection) else {
                    log("refused a connection from \(connection.endpoint): not over Thunderbolt")
                    return connection.cancel()
                }
                DispatchQueue.main.async { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in log("listener \(state)") }
            listener.start(queue: netQueue)
            self.listener = listener
        } catch {
            splash.show(.disconnected("Couldn't listen on port \(options.port): \(error.localizedDescription)"))
        }
    }

    private func accept(_ connection: NWConnection) {
        let channel = MessageChannel(connection, queue: netQueue)
        let source = Source(channel: channel)
        var hello = self.hello!
        if renderer.supportsBC7 { hello.capabilities.insert(.bc7) }
        hello.capabilities.insert(.cursor)
        if Role.canExtend { hello.capabilities.insert(.swap) }
        hello.capabilities.formUnion([.peek, .settings])
        // Even while the screen is asleep (just woken from sleep, say): the brightness is then
        // unknown, and set once the screen is back.
        if options.windowedSize == nil, BuiltInBrightness.hasPanel {
            hello.capabilities.insert(.brightness)
        }
        channel.onReady = { [weak self, weak source] in
            DispatchQueue.main.async {
                guard let self, let source, self.sources.contains(where: { $0 === source }) else { return }
                // A Mac that isn't shown hears so first, so it doesn't start sending its picture.
                if !source.isShown { self.sendLineup(to: source) }
                var hello = hello
                if hello.capabilities.contains(.brightness) { hello.brightness = BuiltInBrightness.get() ?? -1 }
                source.channel.send(.hello, hello.encoded())
            }
        }
        channel.onMessage = { [weak self, weak source] kind, body in
            guard let self, let source else { return }
            self.received(kind, body, from: source)
        }
        channel.onClose = { [weak self, weak source] _ in
            DispatchQueue.main.async {
                guard let self, let source else { return }
                self.closed(source)
            }
        }
        sources.append(source)
        updateDisconnectedSleep()
        log("sender connected from \(connection.endpoint)")
        if active == nil {
            cursorOverlay.reset()
            lastStatus = nil
            active = source
            source.setShown(true)
            if !streaming { splash.show(.connected(nil)) }
        }
        channel.start()
    }

    /// A message from one of the Macs, on the network queue. Frames are drawn here; most of the
    /// rest is handled on the main thread, and only for the Mac that's shown.
    private func received(_ kind: Wire.Kind, _ body: Data, from source: Source) {
        let channel = source.channel
        /// On the main thread, if this Mac is (still) the one shown.
        func ifShown(_ work: @escaping () -> Void) {
            DispatchQueue.main.async { if self.active === source { work() } }
        }
        switch kind {
        case .frame:
            let (draw, first) = source.frameArrived()
            guard draw else {
                // Sent before it heard it isn't shown. Acknowledged, so it isn't left waiting.
                if body.count >= 4 { channel.send(.ack, body.prefix(4)) }
                return
            }
            if first {
                ifShown {
                    source.status = nil
                    self.streaming = true
                    self.startedStreaming()
                }
            }
            renderer.apply(body, presented: { frameNo in
                var ack = Data()
                ack.appendLE(frameNo)
                channel.send(.ack, ack)
            }, rejected: {
                // The sender starts again with a whole frame, rather than wait for an answer.
                channel.cancel()
            })
        case .status:
            source.pictureStopped()
            let text = String(decoding: body, as: UTF8.self)
            log("status from sender: \(text)")
            DispatchQueue.main.async {
                source.status = text
                if self.active === source { self.senderStatus(text) }
            }
        case .power:
            guard let power = body.first.flatMap(Wire.Power.init) else { return }
            if power == .sleep { source.pictureStopped() }
            DispatchQueue.main.async { self.power(power, from: source) }
        case .about:
            guard let peer = Peer(body) else { return }
            DispatchQueue.main.async { self.met(peer, source) }
        case .features:
            let features = body.count >= 2 ? Wire.Capabilities(rawValue: body.readLE(UInt16.self, at: 0)) : []
            DispatchQueue.main.async {
                source.takesFiles = features.contains(.files)
                source.canSwap = features.contains(.swap)
            }
        case .settings:
            DispatchQueue.main.async {
                self.sendSettings(to: source)
                // And again if a setting kept by macOS turns out to have changed.
                MonitorMode.refresh { [weak self] in self?.sendSettings() }
            }
        case .settingsChoice:
            guard let choice = try? JSONDecoder().decode(RemoteMenu.Choice.self, from: body) else { return }
            DispatchQueue.main.async { self.chooseSetting(choice) }
        case .peek:
            guard let command = body.first.flatMap(Wire.Peek.init) else { return }
            ifShown { self.peek.macAsked(command) }
        case .input:
            if source.isShown, let input = InputEvent(body) { peek.play(input) }
        case .swap:
            guard body.first == Wire.Swap.now.rawValue else { return }
            ifShown {
                // Not with another Mac connected too, which would lose its display.
                guard Role.canExtend, self.sources.count == 1 else { return }
                log("\(self.peerKind) asked to swap roles, extending this Mac")
                Role.switchTo(.extend)
            }
        case .inputState:
            guard let state = body.first.flatMap(Wire.InputState.init) else { return }
            DispatchQueue.main.async {
                source.inputState = state
                if self.active === source { self.input.macState = state }
            }
        case .cursor:
            guard let position = CursorPosition(body) else { return }
            DispatchQueue.main.async {
                source.cursorPosition = position
                if self.active === source { self.cursorOverlay.setPosition(position) }
            }
        case .cursorShape:
            guard let shape = CursorShape(body) else { return }
            DispatchQueue.main.async {
                source.cursorShape = shape
                if self.active === source { self.cursorOverlay.setShape(shape) }
            }
        case .probe:
            var size = Data()
            size.appendLE(UInt32(body.count))
            channel.send(.probeAck, size)
        case .display:
            guard let state = DisplayState(body) else { return }
            DispatchQueue.main.async {
                source.display = state
                if self.active === source { self.applyDisplay(state) }
            }
        case .show:
            guard let request = body.first.flatMap(Wire.Show.init) else { return }
            let number = body.count > 1 ? Int(body[body.startIndex + 1]) : 0
            DispatchQueue.main.async {
                log("\(source.name) asked to show \(request == .number ? "Mac \(number)" : "\(request)")")
                _ = self.switchKey(request, number)
            }
        case .hello, .ack, .ping, .probeAck, .cameraFrame, .file, .lineup:
            break
        }
    }

    /// The brightness and colour a Mac asked for, now that it's shown.
    private func applyDisplay(_ state: DisplayState) {
        renderer.setColorMatrix(state.colorMatrix)
        cursorOverlay.setColorMatrix(state.colorMatrix)
        guard state.brightness >= 0, options.windowedSize == nil else { return }
        wantedBrightness = state.brightness
        BuiltInBrightness.set(state.brightness)
    }

    private func closed(_ source: Source) {
        guard let index = sources.firstIndex(where: { $0 === source }) else { return }
        sources.remove(at: index)
        updateDisconnectedSleep()
        log("\(source.name) disconnected")
        guard active === source else { return sendLineup() }
        if let next = nextToShow() {
            return show(next, clearing: true, reason: "\(source.name) disconnected")
        }
        active = nil
        source.setShown(false)
        peek.pictureStopped()
        streaming = false
        renderer.setColorMatrix(DisplayState.identity)
        cursorOverlay.setColorMatrix(DisplayState.identity)
        input.macState = .off
        log("sender disconnected")
        stoppedStreaming()
    }

    /// When the shown Mac goes: one with a picture to show, if there is one.
    private func nextToShow() -> Source? {
        let others = sources.filter { $0 !== active }
        return others.first { $0.hasPicture && $0.name == chosenMac } ?? others.first { $0.hasPicture } ?? others.first
    }

    // MARK: Switching Macs

    /// ⌃⌥ with a number or an arrow, on this Mac's keyboard or one of the others'. Only with more
    /// than one Mac connected; otherwise false, and the keys carry on as usual.
    private func switchKey(_ request: Wire.Show, _ number: Int) -> Bool {
        let macs = sources.filter { $0.number > 0 }.sorted { $0.number < $1.number }
        guard macs.count > 1 else { return false }
        let target: Source?
        switch request {
        case .number:
            target = macs.first { $0.number == number }
            if target == nil {
                let name = MacNumbers.name(of: number)
                hud.show(name.map { "\($0) isn't connected" } ?? "There's no Mac \(number)", shortcutHint(macs))
                return true
            }
        case .next, .previous:
            let at = macs.firstIndex { $0 === active } ?? (request == .next ? -1 : 0)
            target = macs[(at + (request == .next ? 1 : -1) + macs.count) % macs.count]
        }
        guard let target else { return true }
        chosenMac = target.name
        if target === active {
            hud.show(target.name, shortcutHint(macs))
        } else {
            show(target)
        }
        return true
    }

    /// "⌃⌥1 MacBook Pro   ⌃⌥2 Mac mini", or with their names if they're the same kind of Mac.
    private func shortcutHint(_ macs: [Source]) -> String {
        let byKind = Set(macs.map(\.kind)).count == macs.count
        return macs.map { "⌃⌥\($0.number)  \(byKind ? $0.kind : $0.name)" }.joined(separator: "     ")
    }

    /// Shows another Mac. Its picture replaces the last one's as soon as it arrives; with
    /// `clearing`, the screen goes dark until then (the last Mac has gone). The HUD names it, and
    /// says why if it wasn't asked for.
    private func show(_ source: Source, clearing: Bool = false, reason: String? = nil, quietly: Bool = false) {
        guard source !== active, sources.contains(where: { $0 === source }) else { return }
        if let old = active {
            log("showing \(source.name) instead of \(old.name)")
            // Keys held to switch, say, would otherwise stay down there.
            if input.engaged { old.channel.send(.input, InputEvent(type: InputEvent.releaseAll).encoded()) }
            old.setShown(false)
        } else {
            log("showing \(source.name)")
        }
        peek.pictureStopped()
        active = source
        source.setShown(true)
        streaming = false
        if let peer = source.peer { showingPeer(peer) }
        cursorOverlay.isActive = false
        cursorOverlay.reset()
        if let shape = source.cursorShape { cursorOverlay.setShape(shape) }
        if let position = source.cursorPosition { cursorOverlay.setPosition(position) }
        applyDisplay(source.display ?? DisplayState(colorMatrix: DisplayState.identity))
        // Carries on controlling the newly shown Mac, if it takes the keyboard and mouse.
        input.macState = source.inputState
        if clearing { renderer.clear() }
        lastStatus = source.status
        if asleepWithMac && !source.asleep {
            IOPMAssertionDeclareUserActivity("Tandem: showing another Mac" as CFString, kIOPMUserActiveLocal, &activityAssertion)
            setAsleepWithMac(false)
        }
        if let status = source.status {
            senderStatus(status)
        } else if source.asleep {
            // Like a key pressed on its keyboard.
            source.channel.send(.power, Data([Wire.Power.wake.rawValue]))
            splash.show(.asleep)
        } else if clearing {
            splash.show(.connected(nil))
        }
        if !source.hasPicture || clearing { input.available = false; setCursorHidden(false) }
        sendLineup()
        let macs = sources.filter { $0.number > 0 }.sorted { $0.number < $1.number }
        if !quietly { hud.show(source.name, reason ?? (macs.count > 1 ? shortcutHint(macs) : "")) }
        // If no picture comes, say so rather than leave the last Mac's up.
        pictureCheck?.cancel()
        let check = DispatchWorkItem { [weak self, weak source] in
            guard let self, let source, self.active === source, !self.streaming, source.hasPicture else { return }
            log("no picture from \(source.name) yet")
            self.input.available = false
            self.setCursorHidden(false)
            self.splash.show(.connected(nil))
        }
        pictureCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: check)
    }

    /// Tells each Mac which Macs are connected and which is shown: the ones not shown stop
    /// sending, and each lists the others in its Tandem menu.
    private func sendLineup(to only: Source? = nil) {
        // To everyone once, however many changes come together.
        if only == nil {
            guard !lineupQueued else { return }
            lineupQueued = true
            return DispatchQueue.main.async {
                self.lineupQueued = false
                self.sendLineupNow()
            }
        }
        sendLineupNow(to: only)
    }
    private var lineupQueued = false

    private func sendLineupNow(to only: Source? = nil) {
        for source in only.map({ [$0] }) ?? sources {
            // Each Mac once it has said who it is, and always the one it's sent to.
            let macs = sources.filter { $0.number > 0 || $0 === source }
            let lineup = Lineup(macs: macs.map {
                Lineup.Mac(name: $0.name, number: $0.number, shown: $0 === active, you: $0 === source)
            })
            guard let data = try? JSONEncoder().encode(lineup) else { continue }
            source.channel.send(.lineup, data)
        }
    }

    /// A Mac going to sleep or waking. If the shown one sleeps while another is awake, the other
    /// is shown; a Mac waking is shown if the one shown has nothing to show.
    private func power(_ power: Wire.Power, from source: Source) {
        source.asleep = power == .sleep
        if active === source {
            if power == .sleep, let other = sources.first(where: { $0 !== source && $0.hasPicture }) {
                log("\(source.name) went to sleep, showing \(other.name)")
                return show(other, clearing: true, reason: "\(source.name) went to sleep")
            }
            return macPower(power)
        }
        guard power == .wake, let active else { return }
        if !active.hasPicture {
            log("\(source.name) woke while \(active.name) is asleep")
            show(source, clearing: true, reason: "\(active.name) is asleep")
        } else if source.name == chosenMac && active.name != chosenMac {
            // The Mac last chosen, back from sleep: shown again, as when it connects again.
            log("\(source.name) woke, and was the Mac last chosen")
            show(source)
        }
    }

    /// The sender explaining why there's no picture, e.g. missing permission or paused.
    private func senderStatus(_ text: String) {
        lastStatus = text
        streaming = false
        peek.pictureStopped()
        input.available = false
        cursorOverlay.isActive = false
        setCursorHidden(false)
        splash.show(.connected(text))
    }

    private var streaming = false

    /// Follows the other Mac going to sleep and waking, like a monitor would.
    private func macPower(_ power: Wire.Power) {
        log("\(peerKind) power: \(power)")
        switch power {
        case .sleep:
            setAsleepWithMac(true)
            streaming = false
            peek.pictureStopped()
            input.available = false
            cursorOverlay.isActive = false
            releaseDisplayAssertion()
            setCursorHidden(false)
            splash.show(.asleep)
            let pmset = Process()
            pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmset.arguments = ["displaysleepnow"]
            try? pmset.run()
        case .wake:
            IOPMAssertionDeclareUserActivity("Tandem: the other Mac woke" as CFString, kIOPMUserActiveLocal, &activityAssertion)
            setAsleepWithMac(false)
        }
    }

    /// This whole Mac is going to sleep, from its power button or the Apple menu. It's about to
    /// drop off the link, so say goodbye rather than leave the other Mac waiting on a silent cable.
    private func willSleep() {
        guard !sources.isEmpty else { return }
        log("going to sleep")
        input.available = false
        let sent = DispatchGroup()
        for source in sources {
            sent.enter()
            source.channel.send(.power, Data([Wire.Power.sleep.rawValue])) { sent.leave() }
        }
        // macOS sleeps as soon as observers return, so get the messages out first.
        _ = sent.wait(timeout: .now() + 0.5)
        sources.forEach { $0.channel.cancel() }
    }

    /// Only the screen sleeps. If this whole Mac slept, it would drop off the Thunderbolt
    /// link and the other Mac couldn't reach it to wake it again.
    private func setAsleepWithMac(_ asleep: Bool) {
        asleepWithMac = asleep
        updateDisconnectedSleep()
    }

    /// The sleep countdown only runs while no Mac is connected, and not while the other Mac is
    /// asleep: it will wake this one, which it can't do once this one sleeps too.
    private func updateDisconnectedSleep() {
        disconnectedSleep?.paused = !sources.isEmpty || asleepWithMac
    }

    private func startedStreaming() {
        lastStatus = nil
        splash.setVisible(false)
        cursorOverlay.isActive = true
        input.available = true
        if options.windowedSize == nil { setCursorHidden(true) }
        guard sleepAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Tandem is showing the other Mac's display" as CFString, &sleepAssertion)
    }

    private func stoppedStreaming() {
        peek.pictureStopped()
        input.available = false
        cursorOverlay.isActive = false
        releaseDisplayAssertion()
        renderer.clear()
        splash.show(asleepWithMac ? .asleep : .disconnected(lastStatus))
        setCursorHidden(false)
    }

    private func releaseDisplayAssertion() {
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}
