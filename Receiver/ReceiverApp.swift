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
    private var channel: MessageChannel?
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
    private var senderCanSwap = false
    private let fileSender = FileSender()
    private var hud: InputHUD!
    private lazy var permissionsWindow: PermissionsWindow = {
        let permissions = PermissionsWindow(role: .display)
        permissions.beforeOpeningSettings = { [weak self] in self?.getOutOfTheWay() }
        return permissions
    }()
    /// The other Mac takes files pulled through the bubble.
    private var senderTakesFiles = false

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
            // The backing store size is the panel's native resolution when the Mac is at its
            // default "looks like 2560×1440" setting, so frames map 1:1 onto physical pixels.
            let scale = screen.backingScaleFactor
            hello = Hello(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale),
                          mmWide: mm.width, mmHigh: mm.height, name: name)
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
        MonitorMode.setRestartsAfterPowerFailure(!MonitorMode.restartsAfterPowerFailure)
    }

    private func met(_ peer: Peer) {
        log("showing \(peer.name), a \(peer.kind)")
        Peer.last = peer
        peerKind = peer.kind
        splash.peerKind = peer.kind
        input.peerKind = peer.kind
        sendSettings()
    }

    private static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    /// Lets the other Mac show this Mac's settings in its own Tandem menu.
    private func sendSettings() {
        guard let channel, let data = try? JSONEncoder().encode(RemoteMenu(settingsMenu())) else { return }
        channel.send(.settings, data)
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

    private var canSwap: Bool { channel != nil && senderCanSwap && Role.canExtend }

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
        channel?.cancel()
        let channel = MessageChannel(connection, queue: netQueue)
        var hello = self.hello!
        if renderer.supportsBC7 { hello.capabilities.insert(.bc7) }
        hello.capabilities.insert(.cursor)
        if Role.canExtend { hello.capabilities.insert(.swap) }
        hello.capabilities.formUnion([.peek, .settings])
        cursorOverlay.reset()
        // Even while the screen is asleep (just woken from sleep, say): the brightness is then
        // unknown, and set once the screen is back.
        if options.windowedSize == nil, BuiltInBrightness.hasPanel {
            hello.capabilities.insert(.brightness)
            hello.brightness = BuiltInBrightness.get() ?? -1
        }
        channel.onReady = { [weak channel, hello] in channel?.send(.hello, hello.encoded()) }
        channel.onMessage = { [weak self, weak channel] kind, body in
            guard let self else { return }
            if kind == .status {
                let text = String(decoding: body, as: UTF8.self)
                log("status from sender: \(text)")
                DispatchQueue.main.async { self.senderStatus(text) }
                return
            }
            if kind == .power {
                guard let power = body.first.flatMap(Wire.Power.init) else { return }
                DispatchQueue.main.async { self.macPower(power) }
                return
            }
            if kind == .about {
                guard let peer = Peer(body) else { return }
                DispatchQueue.main.async { self.met(peer) }
                return
            }
            if kind == .features {
                let features = body.count >= 2 ? Wire.Capabilities(rawValue: body.readLE(UInt16.self, at: 0)) : []
                DispatchQueue.main.async {
                    guard self.channel === channel else { return }
                    self.senderTakesFiles = features.contains(.files)
                    self.senderCanSwap = features.contains(.swap)
                }
                return
            }
            if kind == .settings {
                DispatchQueue.main.async { self.sendSettings() }
                return
            }
            if kind == .settingsChoice {
                guard let choice = try? JSONDecoder().decode(RemoteMenu.Choice.self, from: body) else { return }
                DispatchQueue.main.async { self.chooseSetting(choice) }
                return
            }
            if kind == .peek {
                guard let command = body.first.flatMap(Wire.Peek.init) else { return }
                DispatchQueue.main.async {
                    guard self.channel === channel else { return }
                    self.peek.macAsked(command)
                }
                return
            }
            if kind == .input {
                if let input = InputEvent(body) { self.peek.play(input) }
                return
            }
            if kind == .swap {
                guard body.first == Wire.Swap.now.rawValue else { return }
                DispatchQueue.main.async {
                    guard self.channel === channel, Role.canExtend else { return }
                    log("\(self.peerKind) asked to swap roles, extending this Mac")
                    Role.switchTo(.extend)
                }
                return
            }
            if kind == .inputState {
                guard let state = body.first.flatMap(Wire.InputState.init) else { return }
                DispatchQueue.main.async { self.input.macState = state }
                return
            }
            if kind == .cursor {
                guard let position = CursorPosition(body) else { return }
                DispatchQueue.main.async { self.cursorOverlay.setPosition(position) }
                return
            }
            if kind == .cursorShape {
                guard let shape = CursorShape(body) else { return }
                DispatchQueue.main.async { self.cursorOverlay.setShape(shape) }
                return
            }
            if kind == .probe {
                var size = Data()
                size.appendLE(UInt32(body.count))
                channel?.send(.probeAck, size)
                return
            }
            if kind == .display {
                guard let state = DisplayState(body) else { return }
                self.renderer.setColorMatrix(state.colorMatrix)
                if state.brightness >= 0 && self.options.windowedSize == nil {
                    DispatchQueue.main.async {
                        self.wantedBrightness = state.brightness
                        BuiltInBrightness.set(state.brightness)
                    }
                }
                return
            }
            guard kind == .frame else { return }
            if !self.streaming { DispatchQueue.main.async { self.startedStreaming() } }
            self.streaming = true
            self.renderer.apply(body) { frameNo in
                var ack = Data()
                ack.appendLE(frameNo)
                channel?.send(.ack, ack)
            }
        }
        channel.onClose = { [weak self, weak channel] _ in
            DispatchQueue.main.async {
                guard let self, let channel, self.channel === channel else { return }
                self.channel = nil
                self.senderCanSwap = false
                self.senderTakesFiles = false
                self.peek.pictureStopped()
                self.updateDisconnectedSleep()
                self.streaming = false
                self.renderer.setColorMatrix(DisplayState.identity)
                self.input.macState = .off
                log("sender disconnected")
                self.stoppedStreaming()
            }
        }
        self.channel = channel
        updateDisconnectedSleep()
        lastStatus = nil
        if !streaming { splash.show(.connected(nil)) }
        log("sender connected from \(connection.endpoint)")
        channel.start()
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
        guard let channel else { return }
        log("going to sleep")
        input.available = false
        let sent = DispatchSemaphore(value: 0)
        channel.send(.power, Data([Wire.Power.sleep.rawValue])) { sent.signal() }
        // macOS sleeps as soon as observers return, so get the message out first.
        _ = sent.wait(timeout: .now() + 0.5)
        channel.cancel()
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
        disconnectedSleep?.paused = channel != nil || asleepWithMac
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
