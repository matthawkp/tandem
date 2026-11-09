import AppKit
import CoreGraphics
import CoreVideo
import IOKit.pwr_mgt
import Network
import ScreenCaptureKit

@available(macOS 14, *)
struct SenderOptions {
    var host: String?
    var port = Wire.port
    var synthetic = false
    var allowWiFi = false

    init(arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--host": host = it.next()
            case "--port": port = it.next().flatMap(UInt16.init) ?? port
            case "--synthetic": synthetic = true
            case "--allow-wifi": allowWiFi = true
            default: break
            }
        }
        if ProcessInfo.processInfo.environment["TANDEM_ALLOW_WIFI"] != nil { allowWiFi = true }
    }
}

private let stressEnabled = ProcessInfo.processInfo.environment["TANDEM_STRESS"] != nil

/// Finds the receiver, creates the virtual display when it connects, and streams frames to it.
/// Connection state lives on the main thread; encoding state lives on `encodeQueue`.
@available(macOS 14, *)
final class SenderController: @unchecked Sendable {
    private(set) var status = "Looking for your iMac…"
    private(set) var stats = ""
    private(set) var needsPermission = false
    private(set) var paused = false
    private(set) var isStreaming = false
    /// The connected iMac, if any.
    private(set) var receiverName: String?
    /// The display Mac, or the last one seen, for wording like "Sleep iMac with MacBook Pro".
    private(set) var peer = Peer.last
    var peerKind: String { peer?.kind ?? "other Mac" }
    private var advertiser: NWListener?
    /// How the iMac is connected, e.g. "Thunderbolt", and the measured link speed in bytes per second.
    private(set) var linkName: String?
    private(set) var linkRate: Double?
    /// The iMac's brightness as last set, for the menu's slider. Nil if it can't be changed.
    private(set) var receiverBrightness: Float?
    var onChange: (() -> Void)?

    let prefs = Preferences.shared
    private let options: SenderOptions
    private let netQueue = DispatchQueue(label: "net", qos: .userInteractive)
    private let encodeQueue = DispatchQueue(label: "encode", qos: .userInteractive)

    // Main thread.
    private var browser: NWBrowser?
    private var browseResults: [NWBrowser.Result] = []
    private var channel: MessageChannel?
    private(set) var screen: VirtualScreen? {
        didSet { fileReceiver.setDisplay(screen?.displayID) }
    }
    private var hello: Hello?
    private lazy var capture = Capture(
        onFrame: { [weak self] buffer in self?.frameArrived(buffer) },
        onStop: { [weak self] error in DispatchQueue.main.async { self?.captureStopped(error) } })
    private var restartWork: DispatchWorkItem?
    /// Draws the pointer on the receiver, when it can.
    private var cursorTracker: CursorTracker?
    private var receiverDrawsCursor = false
    /// Between this Mac going to sleep and waking. It still runs now and then while asleep (to
    /// check mail, say), and would otherwise find the display Mac, connect, test the link and
    /// lose it again, every minute for as long as it sleeps.
    private var asleep = false
    /// The connection was made before this Mac slept, so the other end has probably gone.
    private var connectedBeforeSleep = false
    /// The receiver has said hello on this connection, whether or not a picture followed.
    private var heardHello = false
    /// The last link test, which holds for a while: reconnecting doesn't send it all again.
    private var lastLink: (rate: Double, name: String, peer: String, at: Date)?
    private let linkTestLifetime: TimeInterval = 600
    private var wakePending = false
    private var askedForScreenRecording = false
    /// The iMac said it was going to sleep, so its disappearance isn't a pulled cable.
    private var receiverAsleep = false
    private var holdScreen = false
    private var screensOff = false
    private var dropScreenWork: DispatchWorkItem?
    private var displayTimer: Timer?
    private var sentDisplay: DisplayState?
    private var colorMatrix: [Float]?
    private var displayTicks = 0
    /// On netQueue.
    private let inputPlayer = InputPlayer()
    private let remotePeek = RemotePeek()
    private let fileReceiver = FileReceiver()
    private var sentInputState: Wire.InputState?
    /// Link test, on netQueue: when the first reply came, and how many are still to come.
    private var probe: (first: DispatchTime?, remaining: Int)?
    private let probeCount = 24
    private lazy var probeChunk: Data = {
        var d = Data(count: 4 << 20)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return d
    }()

    // encodeQueue.
    private var encoder: TileEncoder?
    private var sendChannel: MessageChannel?
    private var latest: CVPixelBuffer?
    /// The last frame encoded, kept so lossy tiles can be made sharp once the screen is still.
    private var lastBuffer: CVPixelBuffer?
    private var inFlight = 0
    private var frameNo: UInt32 = 0
    /// Lossless bytes in each frame not yet acked, and when the last ack came, to measure how
    /// much the receiver keeps up with (TileEncoder.observePipeline).
    private var unacked: [UInt32: Int] = [:]
    private var lastAck: Double?
    /// When the last frame went, to notice a receiver that has stopped acknowledging them.
    private var lastFrameSent: Double?
    private let ackTimeout = 10.0
    private var synthetic: SyntheticSource?
    private var syntheticTimer: DispatchSourceTimer?
    private var counted = (frames: 0, raw: 0, sent: 0, bc7: 0)
    private let maxInFlight = 2

    init(options: SenderOptions) {
        self.options = options
    }

    func start() {
        if !options.synthetic && !CGPreflightScreenCaptureAccess() {
            needsPermission = true
        }
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.macWillSleep(system: true)
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.macWillSleep(system: false)
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.macDidWake(system: true)
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.macDidWake(system: false)
        }
        inputPlayer.onKeyTyped = { [weak self] in self?.cursorTracker?.keyTyped() }
        inputPlayer.onBrightnessKey = { [weak self] direction, fine in
            self?.receiverKeyboardBrightness(direction, fine: fine) ?? false
        }
        remotePeek.send = { [weak self] command in self?.channel?.send(.peek, Data([command.rawValue])) }
        remotePeek.sendInput = { [weak self] input in self?.channel?.send(.input, input.encoded()) }
        remotePeek.displayID = { [weak self] in self?.screen?.displayID }
        fileReceiver.folder = { Self.folder(at: $0) }
        fileReceiver.onSaved = { Self.placeOnDesktop($0, at: $1) }
        startStatsTimer()
        startSettleTimer()
        if options.host == nil { startBrowsing() } else { connect() }
        advertise()
        setStatus(options.host.map { "Connecting to \($0)…" } ?? "Looking for your \(peerKind)…")
    }

    /// Lets a new Tandem on the other Mac see that this one extends, so it suggests being the
    /// display. Only on wired links; nothing ever connects.
    private func advertise() {
        guard let listener = try? NWListener(using: Wire.tcpParameters(allowWiFi: false)) else { return }
        listener.service = NWListener.Service(name: Machine.name, type: Wire.extenderServiceType)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        advertiser = listener
    }

    /// Call after Screen Recording permission may have been granted.
    func recheckPermission() {
        guard needsPermission, CGPreflightScreenCaptureAccess() else { return }
        needsPermission = false
        reconnect()
    }

    func reconnect() {
        if channel == nil { connect() } else { channel?.cancel() }
    }

    /// Disconnects and removes the virtual display, so windows and the pointer return here.
    func pause(reason: String = "Paused on your \(Machine.kind). Choose Resume Tandem in the Tandem menu to continue.") {
        paused = true
        setStatus("Paused")
        guard let channel else { return }
        // No more frames: one after the reason would bring the picture back over it.
        setSending(false)
        // Let the iMac show why it went dark before hanging up.
        var cancelled = false
        let hangUp = { if !cancelled { cancelled = true; channel.cancel() } }
        channel.send(.status, Data(reason.utf8)) { DispatchQueue.main.async(execute: hangUp) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: hangUp)
    }

    func resume() {
        paused = false
        setStatus(options.host == nil ? "Looking for your \(peerKind)…" : "Connecting…")
        connect()
    }

    /// Stops frames going out, or lets them go again. Stopping waits for a frame being encoded,
    /// so whatever is sent next (why the picture is going, say) comes after the last frame.
    private func setSending(_ on: Bool) {
        let channel = on && hello != nil ? self.channel : nil
        encodeQueue.sync { sendChannel = channel }
    }

    /// Tells the iMac why there's no picture; it shows this on its splash screen.
    private func tellReceiver(_ text: String) {
        channel?.send(.status, Data(text.utf8))
    }

    // MARK: Settings from the menu

    func setQuality(_ quality: TileEncoder.Quality) {
        prefs.quality = quality
        encodeQueue.async { self.encoder?.quality = quality }
        onChange?()
    }

    func setFollowsBrightness(_ follows: Bool) {
        prefs.followsBrightness = follows
        if follows, let mac = MacBookPanel.brightness(), let current = receiverBrightness {
            prefs.brightnessOffset = current - mac
        }
        syncDisplay(force: true)
    }

    func setMatchesColor(_ matches: Bool) {
        prefs.matchesColor = matches
        colorMatrix = nil
        syncDisplay(force: true)
    }

    /// From the menu's slider. While following the MacBook, this sets how much brighter or
    /// dimmer than the MacBook the iMac is.
    func setReceiverBrightness(_ value: Float) {
        if prefs.followsBrightness, let mac = MacBookPanel.brightness() {
            prefs.brightnessOffset = value - mac
        }
        sendDisplay(DisplayState(brightness: value, colorMatrix: sentDisplay?.colorMatrix ?? DisplayState.identity))
    }

    /// A brightness key from the iMac's keyboard: the iMac's if the pointer is on it, as for the
    /// MacBook's keys; otherwise false, and it goes to the MacBook.
    private func receiverKeyboardBrightness(_ direction: Float, fine: Bool) -> Bool {
        guard prefs.brightnessKeysFollowPointer, receiverBrightness != nil, let screen,
              let location = CGEvent(source: nil)?.location, CGDisplayBounds(screen.displayID).contains(location)
        else { return false }
        stepReceiverBrightness(direction, fine: fine)
        return true
    }

    /// A brightness key pressed while the pointer is on the iMac: one of macOS's 16 steps, or a
    /// quarter step with Option-Shift, like the built-in display.
    func stepReceiverBrightness(_ direction: Float, fine: Bool) {
        guard let current = receiverBrightness, let screen else { return }
        let step: Float = fine ? 1 / 64 : 1 / 16
        let value = min(max((current / step).rounded() * step + direction * step, 0), 1)
        log("brightness key: display to \(value)")
        setReceiverBrightness(value)
        BrightnessOverlay.shared.onChange = { [weak self] in self?.setReceiverBrightness($0) }
        BrightnessOverlay.shared.show(value, on: screen.displayID)
    }

    // MARK: Connection

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.browseResults = Array(results)
                self?.connect()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connect() {
        guard channel == nil, !paused, !asleep else { return }
        let params = Wire.tcpParameters(allowWiFi: options.allowWiFi)
        let connection: NWConnection
        if let host = options.host {
            connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: options.port)!, using: params)
        } else if let (result, interface) = preferredResult() {
            // The receiver is advertised on every link it has; pin the connection to the
            // Thunderbolt one, otherwise Bonjour may resolve it over Wi-Fi.
            if let interface { params.requiredInterface = interface }
            connection = NWConnection(to: result.endpoint, using: params)
        } else {
            return
        }

        let channel = MessageChannel(connection, queue: netQueue)
        channel.onMessage = { [weak self, weak channel] kind, body in
            guard let self, let channel else { return }
            switch kind {
            case .hello:
                guard let hello = Hello(body) else { return }
                DispatchQueue.main.async { self.receiverSaidHello(hello, on: channel) }
            case .ack:
                let acked = body.count >= 4 ? body.readLE(UInt32.self, at: 0) : nil
                self.encodeQueue.async {
                    self.inFlight = max(0, self.inFlight - 1)
                    self.frameAcked(acked)
                    self.pump()
                }
            case .probeAck:
                self.probeAcked(on: channel)
            case .input:
                guard let input = InputEvent(body), InputPlayer.state == .ready else { return }
                self.inputPlayer.play(input)
            case .power:
                let power = body.first.flatMap(Wire.Power.init)
                DispatchQueue.main.async {
                    guard self.channel === channel else { return }
                    if power == .sleep {
                        log("\(self.peerKind) going to sleep")
                        self.receiverAsleep = true
                    } else if power == .wake {
                        // Someone touched the iMac while this Mac's screens were off.
                        log("\(self.peerKind) woken by hand, waking this Mac")
                        var id: IOPMAssertionID = 0
                        IOPMAssertionDeclareUserActivity("Tandem: the other Mac's keyboard or mouse was used" as CFString, kIOPMUserActiveLocal, &id)
                    }
                }
            case .swap:
                guard body.first == Wire.Swap.now.rawValue else { return }
                DispatchQueue.main.async {
                    guard self.channel === channel else { return }
                    log("\(self.peerKind) asked to swap roles, becoming a display")
                    Role.switchTo(.display)
                }
            case .file:
                self.fileReceiver.receive(body)
            case .settings:
                let settings = try? JSONDecoder().decode(RemoteMenu.self, from: body)
                DispatchQueue.main.async {
                    guard self.channel === channel else { return }
                    self.receiverSettings = settings
                }
            case .peek:
                guard let command = body.first.flatMap(Wire.Peek.init) else { return }
                let drives = body.count > 1 && body[body.startIndex + 1] == 1
                let at = body.count >= 9 ? (Float(bitPattern: body.readLE(UInt32.self, at: 1)), Float(bitPattern: body.readLE(UInt32.self, at: 5))) : nil
                DispatchQueue.main.async {
                    guard self.channel === channel else { return }
                    switch command {
                    case .opened: self.remotePeek.opened(drives: drives)
                    case .at: if let at { self.remotePeek.pointer(at: at.0, at.1) }
                    case .steppedOut: self.remotePeek.steppedOut(drives: drives)
                    case .back: self.remotePeek.otherMacCameBack()
                    case .closed: self.remotePeek.otherMacClosed()
                    case .open, .close, .stepThrough, .comeBack: break
                    }
                }
            case .frame, .status, .ping, .display, .probe, .inputState, .cameraFrame, .about, .cursor, .cursorShape, .settingsChoice, .features:
                break
            }
        }
        channel.onClose = { [weak self, weak channel] error in
            DispatchQueue.main.async {
                guard let self, let channel, self.channel === channel else { return }
                self.disconnected(error)
            }
        }
        self.channel = channel
        heardHello = false
        connectedBeforeSleep = false
        log("connecting to \(connection.endpoint) via \(params.requiredInterface?.name ?? "any interface")")
        channel.start()

        // A connection with no usable path waits forever; give up and try again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak channel] in
            // Not once it has answered, even with a version this one can't use: hanging up then
            // would only connect again to hear the same, every few seconds.
            guard let self, let channel, self.channel === channel, !self.heardHello else { return }
            log("no answer from \(connection.endpoint), retrying")
            channel.cancel()
        }
    }

    /// The first receiver across the Thunderbolt cable, with that interface: never one on a
    /// network. Other links only with the testing switch for Wi-Fi.
    private func preferredResult() -> (NWBrowser.Result, NWInterface?)? {
        for result in browseResults {
            if let thunderbolt = result.interfaces.first(where: Wire.isThunderbolt) {
                return (result, thunderbolt)
            }
        }
        return options.allowWiFi ? browseResults.first.map { ($0, nil) } : nil
    }

    /// The other Mac's settings, to show in this Mac's Tandem menu.
    private(set) var receiverSettings: RemoteMenu?

    /// Asks for the other Mac's settings again, in case they changed there.
    func refreshReceiverSettings() {
        guard hello?.capabilities.contains(.settings) == true else { return }
        channel?.send(.settings, Data())
    }

    func chooseReceiverSetting(_ choice: RemoteMenu.Choice) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        channel?.send(.settingsChoice, data)
    }

    /// Something let go on the desktop goes where it was let go, as a drag in the Finder would.
    /// Asking the Finder needs permission, which macOS asks for the first time. Its desktop sorts
    /// or snaps icons if it's set to, as usual. Called on the files queue: osascript rather than
    /// NSAppleScript, which belongs on the main thread.
    private static func placeOnDesktop(_ url: URL, at point: CGPoint) {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
              url.deletingLastPathComponent().standardizedFileURL == desktop.standardizedFileURL else { return }
        let name = url.lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to set desktop position of item \"\(name)\" of desktop to {\(Int(point.x)), \(Int(point.y))}"
        // A moment for the Finder to notice the new item.
        Thread.sleep(forTimeInterval: 0.5)
        ScreenProbe.osascript(script)
    }

    /// The folder under a point: a folder icon, a Finder window, or the desktop. Not on the main
    /// thread: it asks the Finder, which can be slow.
    private static func folder(at point: CGPoint) -> URL? {
        guard AXIsProcessTrusted(), let window = ScreenProbe.window(at: point), window.isFinder else { return nil }
        if let item = ScreenProbe.finderItem(at: point, in: window),
           let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           values.isDirectory == true, values.isPackage != true {
            return item
        }
        if window.isDesktop { return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first }
        let folder = ScreenProbe.finderFolder(at: point)
        if folder == nil { log("files: no folder found for the Finder window under the drop") }
        return folder
    }

    /// The other Mac can take over extending, so the two can swap roles in one go.
    var peerCanSwap: Bool { channel != nil && hello?.capabilities.contains(.swap) == true }

    /// Asks the other Mac to start extending, then calls `done` once the message is on its way
    /// (or after a second, if the link has gone quiet).
    func requestSwap(then done: @escaping () -> Void) {
        guard let channel else { return done() }
        log("asking \(peerKind) to swap roles")
        channel.sendSoon(.swap, Data([Wire.Swap.now.rawValue]), then: done)
    }

    private func receiverSaidHello(_ hello: Hello, on channel: MessageChannel) {
        guard self.channel === channel else { return }
        heardHello = true
        guard hello.version == Wire.version else {
            log("receiver speaks version \(hello.version), we speak \(Wire.version)")
            setStatus("Update Tandem on your \(hello.kind)")
            tellReceiver("This Tandem doesn't match Tandem on your \(Machine.kind). Install the same version on both Macs.")
            return
        }
        log("receiver \(hello.name): \(hello.width)x\(hello.height), \(Int(hello.mmWide))x\(Int(hello.mmHigh)) mm, capabilities \(hello.capabilities.rawValue)")
        self.hello = hello
        receiverAsleep = false
        receiverName = hello.name
        peer = Peer(name: hello.name, kind: hello.kind)
        Peer.last = peer
        channel.send(.about, Peer.this.encoded())
        // This Mac can always be a display, which only needs macOS 11.
        var features = Data()
        features.appendLE(Wire.Capabilities([.files, .swap]).rawValue)
        channel.send(.features, features)
        remotePeek.available = hello.capabilities.contains(.peek)
        if !hello.capabilities.contains(.brightness) {
            receiverBrightness = nil
        } else if hello.brightness >= 0 {
            receiverBrightness = hello.brightness
        } else {
            // The iMac's screen is asleep, so it couldn't say; it'll take what's sent.
            let mac = MacBookPanel.brightness().map { min(max($0 + prefs.brightnessOffset, 0), 1) }
            receiverBrightness = mac ?? 0.5
        }
        sentDisplay = DisplayState(brightness: hello.brightness)
        if wakePending {
            wakePending = false
            channel.send(.power, Data([Wire.Power.wake.rawValue]))
        }
        var knownRate: Double?
        if let last = lastLink, last.peer == hello.name, Date().timeIntervalSince(last.at) < linkTestLifetime {
            knownRate = last.rate
            linkName = last.name
            linkRate = last.rate
        } else {
            measureLink(on: channel)
        }

        if !options.synthetic {
            // Without permission the display would stay blank, and new windows (including the
            // permission prompt) could open on it out of sight. Wait until access is granted.
            guard CGPreflightScreenCaptureAccess() else {
                needsPermission = true
                log("no Screen Recording permission; not creating the display")
                // Asking puts Tandem in the Screen Recording list (and shows macOS's prompt, once).
                if !askedForScreenRecording {
                    askedForScreenRecording = true
                    CGRequestScreenCaptureAccess()
                }
                setStatus("Needs Screen Recording permission")
                tellReceiver("Your \(Machine.kind) needs to allow Screen Recording for Tandem: System Settings → Privacy & Security → Screen & System Audio Recording.")
                return
            }
            if let screen, screen.matches(hello) {
                log("keeping virtual display \(screen.displayID)")
            } else {
                self.screen = nil
                guard let screen = VirtualScreen(hello: hello) else {
                    log("couldn't create the virtual display for \(hello.name)")
                    setStatus("Couldn't create the virtual display")
                    return
                }
                self.screen = screen
            }
        }
        holdScreen = false
        dropScreenWork?.cancel()

        let quality = prefs.quality
        encodeQueue.sync {
            encoder = TileEncoder(width: hello.width, height: hello.height, bc7: hello.capabilities.contains(.bc7))
            encoder?.quality = quality
            if let knownRate { encoder?.linkBytesPerSecond = knownRate }
            sendChannel = channel
            latest = nil
            lastBuffer = nil
            inFlight = 0
            unacked = [:]
            lastAck = nil
            lastFrameSent = nil
        }
        startDisplaySync()
        startCursor(hello, on: channel)

        if options.synthetic {
            startSynthetic(hello)
            isStreaming = true
            setStatus("Streaming test pattern")
        } else {
            setStatus("Connecting…")
            startCapture()
        }
    }

    private func disconnected(_ error: Error?) {
        log("disconnected\(error.map { ": \($0)" } ?? "")")
        remotePeek.available = false
        receiverSettings = nil
        cursorTracker?.stop()
        cursorTracker = nil
        channel = nil
        hello = nil
        heardHello = false
        netQueue.async {
            self.probe = nil
            self.inputPlayer.releaseAll()
        }
        sentInputState = nil
        receiverName = nil
        linkName = nil
        linkRate = nil
        receiverBrightness = nil
        isStreaming = false
        displayTimer?.invalidate()
        displayTimer = nil
        sentDisplay = nil
        restartWork?.cancel()
        let capture = self.capture
        Task { await capture.stop() }
        if !holdScreen { screen = nil }
        encodeQueue.sync {
            syntheticTimer?.cancel()
            syntheticTimer = nil
            synthetic = nil
            encoder = nil
            sendChannel = nil
            latest = nil
            lastBuffer = nil
            inFlight = 0
            unacked = [:]
            lastAck = nil
            lastFrameSent = nil
        }
        if paused { return setStatus(status) }
        if receiverAsleep {
            setStatus("\(peerKind) is asleep. Press its power button to wake it.")
        } else {
            setStatus(options.host == nil ? "Looking for your \(peerKind)…" : "Reconnecting…")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    // MARK: Link speed

    /// Sends a burst of filler and times the replies, to know how much can go lossless.
    private func measureLink(on channel: MessageChannel) {
        let count = probeCount
        let chunk = probeChunk
        netQueue.async {
            self.probe = (nil, count)
            for _ in 0..<count { channel.send(.probe, chunk) }
        }
    }

    /// On netQueue. Timed from the first reply to the last, so connection set-up doesn't count.
    private func probeAcked(on channel: MessageChannel) {
        guard var probe else { return }
        probe.remaining -= 1
        if probe.first == nil { probe.first = .now() }
        self.probe = probe
        guard probe.remaining == 0, let first = probe.first else { return }
        self.probe = nil
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - first.uptimeNanoseconds) / 1e9
        // The first reply starts the clock, so it's the rest that were timed.
        let bytes = (probeCount - 1) * probeChunk.count
        var rate = Double(bytes) / max(seconds, 0.001)
        // TANDEM_LINK_GBIT: pretend the link is this fast, for testing.
        if let forced = ProcessInfo.processInfo.environment["TANDEM_LINK_GBIT"].flatMap(Double.init) { rate = forced * 1e9 / 8 }
        log(String(format: "link: %.0f MB in %.0f ms = %.2f Gbit/s", Double(bytes) / 1e6, seconds * 1000, rate * 8 / 1e9))
        encodeQueue.async { self.encoder?.linkBytesPerSecond = rate }
        DispatchQueue.main.async { self.linkMeasured(rate, on: channel) }
    }

    private func linkMeasured(_ rate: Double, on channel: MessageChannel) {
        guard self.channel === channel else { return }
        let name = channel.connection.currentPath?.availableInterfaces.first.map { interface -> String in
            if interface.name.hasPrefix("bridge") { return "Thunderbolt" }
            switch interface.type {
            case .wifi: return "Wi-Fi"
            case .wiredEthernet: return "Ethernet"
            default: return interface.name
            }
        } ?? "Network"
        linkName = name
        linkRate = rate
        if let peer = hello?.name { lastLink = (rate, name, peer, Date()) }
        onChange?()
    }

    // MARK: Brightness and colour

    private func startDisplaySync() {
        displayTimer?.invalidate()
        displayTicks = 0
        colorMatrix = nil
        syncDisplay(force: true)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.syncDisplay(force: false) }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    /// Keeps the iMac's brightness and colour following the MacBook's panel.
    private func syncDisplay(force: Bool) {
        guard hello != nil else { return }
        displayTicks += 1
        if force || displayTicks % 5 == 0 { syncInputState() }
        if prefs.matchesColor && (colorMatrix == nil || displayTicks % 5 == 0) {
            colorMatrix = MacBookPanel.colorMatrix()
        }
        var state = DisplayState()
        state.colorMatrix = prefs.matchesColor ? colorMatrix ?? DisplayState.identity : DisplayState.identity
        if prefs.followsBrightness, receiverBrightness != nil, let mac = MacBookPanel.brightness() {
            state.brightness = min(max(mac + prefs.brightnessOffset, 0), 1)
        }
        if let last = sentDisplay, !force {
            let brightnessChanged = state.brightness >= 0 && abs(state.brightness - last.brightness) > 0.002
            let colorChanged = zip(state.colorMatrix, last.colorMatrix).contains { abs($0 - $1) > 0.0005 }
            guard brightnessChanged || colorChanged else { return }
        }
        if state.brightness < 0, let current = receiverBrightness { state.brightness = current }
        sendDisplay(state)
    }

    /// Tells the iMac whether its keyboard and mouse can be used here, which changes when
    /// Accessibility is granted or the menu setting is switched.
    func syncInputState() {
        let state = InputPlayer.state
        guard let channel, hello != nil, state != sentInputState else { return }
        sentInputState = state
        log("other Mac's keyboard and mouse: \(state)")
        channel.send(.inputState, Data([state.rawValue]))
    }

    /// Pointer and scrolling adjustments from the menu.
    func updateInputTuning() {
        let tuning = InputPlayer.Tuning(pointerSpeed: prefs.pointerSpeed, scrollSpeed: prefs.scrollSpeed,
                                        reversesScrolling: prefs.reversesScrolling)
        netQueue.async { self.inputPlayer.tuning = tuning }
    }

    func setUsesReceiverInput(_ uses: Bool) {
        prefs.usesReceiverInput = uses
        syncInputState()
    }

    private func sendDisplay(_ state: DisplayState) {
        guard let channel, hello != nil else { return }
        sentDisplay = state
        if state.brightness >= 0 && receiverBrightness != nil && receiverBrightness != state.brightness {
            receiverBrightness = state.brightness
            onChange?()
        }
        channel.send(.display, state.encoded())
    }

    // MARK: Sleep and wake

    /// The MacBook is going to sleep, or its screens turned off: turn the iMac's screen off too.
    private func macWillSleep(system: Bool) {
        log(system ? "going to sleep" : "screens turned off")
        screensOff = true
        // Keep the virtual display through sleep, so windows are still on it afterwards.
        if system && screen != nil { holdScreen = true }
        if system {
            asleep = true
            connectedBeforeSleep = channel != nil
        }
        guard prefs.sleepsReceiver, let channel, hello != nil else { return }
        // No more frames: one after this would bring the picture back on the display Mac.
        setSending(false)
        let sent = DispatchSemaphore(value: 0)
        channel.send(.power, Data([Wire.Power.sleep.rawValue])) { sent.signal() }
        // macOS sleeps as soon as observers return, so get the message out first.
        if system { _ = sent.wait(timeout: .now() + 0.5) }
    }

    private func macDidWake(system: Bool) {
        log(system ? "woke" : "screens turned on")
        if screensOff && (!system || CGDisplayIsAsleep(CGMainDisplayID()) == 0) {
            screensOff = false
            setSending(true)
            startCapture()
        }
        if !system, asleep {
            // The screens are on, so it's awake, whichever of the two notices comes first.
            asleep = false
            connect()
        }
        if system {
            // The iMac hung up while we slept, but our heartbeat can't tell: its clock stops
            // during sleep. Start a fresh connection straight away.
            // Not one made since waking, when the screens came on first.
            asleep = false
            if channel == nil { connect() } else if connectedBeforeSleep { channel?.cancel() }
            // If the iMac doesn't come back, stop holding on to its display.
            dropScreenWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.holdScreen else { return }
                log("\(self.peerKind) didn't come back after wake, removing its display")
                self.holdScreen = false
                if self.hello == nil { self.screen = nil }
            }
            dropScreenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }
        guard prefs.wakesReceiver else { return }
        if !system, let channel, hello != nil {
            channel.send(.power, Data([Wire.Power.wake.rawValue]))
        } else {
            // Sent as soon as the iMac answers the new connection.
            wakePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.wakePending = false }
        }
    }

    // MARK: Pointer

    /// Receivers that draw the pointer themselves get it as messages, and a picture without it.
    private func startCursor(_ hello: Hello, on channel: MessageChannel) {
        cursorTracker?.stop()
        cursorTracker = nil
        receiverDrawsCursor = hello.capabilities.contains(.cursor) && !options.synthetic
        guard receiverDrawsCursor, let screen else { return }
        let tracker = CursorTracker(displayID: screen.displayID, pixelWidth: hello.width)
        tracker.onShape = { [weak channel] shape in channel?.send(.cursorShape, shape.encoded()) }
        tracker.onPosition = { [weak channel] position in channel?.send(.cursor, position.encoded()) }
        tracker.start()
        cursorTracker = tracker
        log("pointer drawn by the receiver")
    }

    // MARK: Capture

    private func startCapture() {
        // Capture fails while the screens are off; it restarts when they turn back on.
        guard let screen, let hello, !screensOff else { return }
        if !CGPreflightScreenCaptureAccess() {
            needsPermission = true
            log("no Screen Recording permission")
            setStatus("Needs Screen Recording permission")
            return
        }
        needsPermission = false
        let displayID = screen.displayID
        let showsCursor = !receiverDrawsCursor
        Task { [weak self] in
            guard let self else { return }
            do {
                // False when a later start took over while this one was starting; that one reports.
                guard try await self.capture.start(displayID: displayID, width: hello.width, height: hello.height,
                                                   showsCursor: showsCursor) else { return }
                self.encodeQueue.async { self.encoder?.invalidate() }
                DispatchQueue.main.async {
                    // The link or the display may have gone while capture was starting.
                    guard self.hello != nil, self.screen?.displayID == displayID else { return }
                    self.isStreaming = true
                    self.setStatus("Connected")
                }
            } catch {
                log("capture failed: \(error)")
                DispatchQueue.main.async {
                    guard !self.screensOff, self.hello != nil, self.screen?.displayID == displayID else { return }
                    self.setStatus("Couldn't capture the display")
                    self.tellReceiver("Your \(Machine.kind) couldn't capture the display: \(error.localizedDescription)")
                }
            }
        }
    }

    private func captureStopped(_ error: Error) {
        guard screen != nil else { return }
        if (error as? SCStreamError)?.code == .userStopped {
            // Stopped from macOS's screen recording indicator in the menu bar.
            pause(reason: "Screen sharing was stopped on your \(Machine.kind). Choose Resume Tandem in the Tandem menu to continue.")
            setStatus("Paused from the menu bar")
        } else if !screensOff {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startCapture() }
        }
    }

    /// Called when any display changes, e.g. picking a new resolution.
    fileprivate func displaysChanged(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
        guard let screen, id == screen.displayID, !flags.contains(.beginConfigurationFlag) else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            log("virtual display reconfigured, restarting capture")
            self?.cursorTracker?.resend()
            self?.startCapture()
            self?.onChange?()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Encoding pipeline (encodeQueue)

    private func frameArrived(_ buffer: CVPixelBuffer) {
        encodeQueue.async {
            self.latest = buffer
            self.pump()
        }
    }

    /// Encodes the newest frame if the receiver has room. Older frames are simply replaced,
    /// which is safe because the encoder diffs against what was last sent.
    private func pump() {
        guard let encoder, let sendChannel, inFlight < maxInFlight else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9

        if let synthetic {
            guard synthetic.changed || encoder.needsRefresh else { return }
            synthetic.changed = false
            if stressEnabled { encoder.invalidate() }
            let frame = TileEncoder.Frame(base: synthetic.pixels, stride: synthetic.stride,
                                          source: .memory(synthetic.pixels, stride: synthetic.stride))
            send(encoder.encode(frame, frameNo: frameNo &+ 1, now: now), on: sendChannel)
            return
        }

        let buffer: CVPixelBuffer
        if let latest {
            buffer = latest
            self.latest = nil
            lastBuffer = latest
        } else if encoder.needsRefresh, let lastBuffer {
            buffer = lastBuffer
        } else {
            return
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetWidth(buffer) == encoder.width,
              CVPixelBufferGetHeight(buffer) == encoder.height,
              let base = CVPixelBufferGetBaseAddress(buffer)
        else {
            log("unexpected frame size \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))")
            // Not kept for refreshing from, which would only say this again, many times a second.
            if lastBuffer === buffer { lastBuffer = nil }
            return
        }
        let frame = TileEncoder.Frame(base: base, stride: CVPixelBufferGetBytesPerRow(buffer), source: .pixelBuffer(buffer))
        send(encoder.encode(frame, frameNo: frameNo &+ 1, now: now), on: sendChannel)
    }

    private func send(_ encoded: (Data, TileEncoder.Stats)?, on channel: MessageChannel) {
        guard let (body, stats) = encoded else { return }
        frameNo &+= 1
        inFlight += 1
        unacked[frameNo] = stats.rawBytes - stats.bc7Raw
        counted.frames += 1
        counted.raw += stats.rawBytes
        counted.sent += body.count
        counted.bc7 += stats.bc7Raw
        lastFrameSent = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        channel.send(.frame, body)
    }

    /// While frames queue up (a newer one is waiting), the time between acks is how long the
    /// receiver takes per frame, so lossless bytes over that time is what it keeps up with.
    private func frameAcked(_ acked: UInt32?) {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        defer { lastAck = now }
        guard let acked, let bytes = unacked.removeValue(forKey: acked) else { return }
        // Drop entries for frames that will never be acked (e.g. lost in a reconnect).
        if unacked.count > 16 { unacked.removeAll() }
        guard let lastAck, latest != nil, bytes > 8_000_000, let encoder else { return }
        encoder.observePipeline(bytes: bytes, seconds: now - lastAck)
    }

    /// Frames wait for the receiver to acknowledge the ones before. If it stops, while its pings
    /// keep the link alive, the picture would stand still for good: start again instead.
    private func checkAcks() {
        guard inFlight > 0, let sent = lastFrameSent, let sendChannel else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        guard now - max(sent, lastAck ?? 0) > ackTimeout else { return }
        log("no frame acknowledged for \(Int(ackTimeout)) s, reconnecting")
        lastFrameSent = nil
        sendChannel.cancel()
    }

    /// Makes lossy tiles sharp again once the screen stops changing.
    private func startSettleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkAcks()
            guard self.encoder?.needsRefresh == true, self.latest == nil, self.synthetic == nil else { return }
            self.pump()
        }
        timer.resume()
        settleTimer = timer
    }
    private var settleTimer: DispatchSourceTimer?

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let c = self.counted
            self.counted = (0, 0, 0, 0)
            let gbit = Double(c.sent) * 8 / 1e9
            var text = c.frames == 0 ? "No changes on screen" : String(format: "%d fps · %.1f Gbit/s", c.frames, gbit)
            if c.frames > 0 { text += c.bc7 > 0 ? " · motion compressed" : " · lossless" }
            if debugEnabled && c.frames > 0 {
                log(text + String(format: " (%.1f× compression, %.0f%% BC7)", c.sent > 0 ? Double(c.raw) / Double(c.sent) : 0,
                                  c.raw > 0 ? Double(c.bc7) * 100 / Double(c.raw) : 0))
            }
            DispatchQueue.main.async {
                self.stats = self.isStreaming ? text : ""
                self.onChange?()
            }
        }
        timer.resume()
        statsTimer = timer
    }
    private var statsTimer: DispatchSourceTimer?

    // MARK: Test pattern (--synthetic)

    private func startSynthetic(_ hello: Hello) {
        encodeQueue.async {
            let source = SyntheticSource(width: hello.width, height: hello.height)
            self.synthetic = source
            let timer = DispatchSource.makeTimerSource(queue: self.encodeQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 60)
            timer.setEventHandler { [weak self] in
                source.step()
                self?.pump()
            }
            timer.resume()
            self.syntheticTimer = timer
        }
    }

    private func setStatus(_ text: String) {
        status = text
        onChange?()
    }
}

@available(macOS 14, *)
private func displayReconfigured(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let controller = Unmanaged<SenderController>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { controller.displaysChanged(id, flags) }
}

/// Moving box over a detailed static background, for testing without screen capture.
@available(macOS 14, *)
final class SyntheticSource {
    let width: Int
    let height: Int
    let stride: Int
    let pixels: UnsafeMutableRawPointer
    private let background: UnsafeMutableRawPointer
    private var t = 0
    private var box = (x: 0, y: 0, w: 600, h: 400)
    var changed = true
    /// TANDEM_STILL_AFTER: stop moving after this many frames, to test that everything ends up sharp.
    private let stillAfter = ProcessInfo.processInfo.environment["TANDEM_STILL_AFTER"].flatMap(Int.init) ?? .max
    /// TANDEM_NOISE: every frame is full-screen, incompressible noise (worse than any video).
    private let noise: [UnsafeMutableRawPointer]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        stride = width * 4
        pixels = .allocate(byteCount: stride * height, alignment: 64)
        background = .allocate(byteCount: stride * height, alignment: 64)
        let bg = background.assumingMemoryBound(to: UInt32.self)
        for y in 0..<height {
            for x in 0..<width {
                // Gradient with a fine "text-like" pattern so compression is realistic.
                let glyph = ((x / 3) ^ (y / 5)) % 7 == 0 && (y / 24) % 2 == 0
                let r = UInt32(x * 255 / width), g = UInt32(y * 255 / height), b: UInt32 = 200
                bg[y * width + x] = glyph ? 0xFF20_2020 : (0xFF00_0000 | r << 16 | g << 8 | b)
            }
        }
        memcpy(pixels, background, stride * height)

        if ProcessInfo.processInfo.environment["TANDEM_NOISE"] != nil {
            let bytes = stride * height
            noise = (0..<2).map { _ in
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
                arc4random_buf(buffer, bytes)
                return buffer
            }
        } else {
            noise = []
        }
    }

    deinit {
        pixels.deallocate()
        background.deallocate()
        noise.forEach { $0.deallocate() }
    }

    func step() {
        guard t < stillAfter else { return }
        if !noise.isEmpty {
            t += 1
            memcpy(pixels, noise[t % 2], stride * height)
            changed = true
            return
        }
        restore(box)
        t += 1
        box.x = Int((sin(Double(t) / 60) * 0.5 + 0.5) * Double(width - box.w))
        box.y = Int((cos(Double(t) / 47) * 0.5 + 0.5) * Double(height - box.h))
        let color: UInt32 = 0xFF00_0000 | UInt32(t * 3 % 256) << 16 | 0x0080FF
        for y in box.y..<(box.y + box.h) {
            let row = (pixels + y * stride).assumingMemoryBound(to: UInt32.self)
            for x in box.x..<(box.x + box.w) { row[x] = color }
        }
        changed = true
    }

    private func restore(_ r: (x: Int, y: Int, w: Int, h: Int)) {
        for y in r.y..<(r.y + r.h) {
            memcpy(pixels + y * stride + r.x * 4, background + y * stride + r.x * 4, r.w * 4)
        }
    }
}
