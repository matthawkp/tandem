import Foundation
import Network
import os

// Wire protocol between the two roles of Tandem: the sender is the Mac being extended (say a
// MacBook), the receiver is the Mac acting as its display (say an iMac).
//
// Every message is: u32 body length | u8 kind | body   (little-endian)
//
//   hello (receiver -> sender)  u32 width, u32 height (native pixels), f64 mmWide, f64 mmHigh,
//                               u16 version, u16 Capabilities, f32 brightness (-1 if unknown), Peer
//   about (sender -> receiver)  Peer: the sender's name and kind of Mac, for the receiver's wording
//   frame (sender -> receiver)  u32 frameNo, u32 rectCount, then per rect:
//                               u16 x, u16 y, u16 w, u16 h, u8 encoding, u32 byteCount, bytes
//                               (raw: BGRA rows packed tightly; bc7: rows of 16-byte 4×4 blocks)
//   ack   (receiver -> sender)  u32 frameNo   (sent once the frame is on screen)
//   status (sender -> receiver) utf8 text explaining why there is no picture
//   ping  (both ways)           empty; sent every 0.5 s so a pulled cable is noticed in seconds
//   power (both ways)           u8 Power: the MacBook is going to sleep or has woken; or the iMac is
//                               going to sleep (its power button), just before it drops off the link
//   display (sender -> receiver) f32 brightness (-1: leave alone), 9 × f32 colour matrix (row-major,
//                               linear light; identity when not matching True Tone / Night Shift)
//   probe (sender -> receiver)  filler bytes for measuring the link; answered by probeAck (u32 size)
//   input (receiver -> sender)  InputEvent: a key, click, move or scroll from the iMac's keyboard and mouse
//   inputState (sender -> receiver) u8 InputState: whether the MacBook can take that input
//   cursor (sender -> receiver) CursorPosition: where the pointer is, in the receiver's pixels, and
//                               whether it shows. Only to receivers with the `cursor` capability,
//                               whose picture then comes without the pointer: they draw it
//                               themselves, so it moves at once instead of with the next frame.
//   cursorShape (sender -> receiver) CursorShape: the pointer's image, when it changes
//
// The camera has its own service (cameraServiceType, cameraPort), used by the sender's camera
// switcher, which serves the result to its camera extension on switcherPort:
//   cameraFrame  u32 width, u32 height, then BGRA rows packed tightly
//
// Senders also advertise extenderServiceType (nothing listens), so a new install can tell
// which role the other Mac already has.

enum Wire {
    static let serviceType = "_tandem._tcp"
    static let extenderServiceType = "_tandemext._tcp"
    static let port: UInt16 = 51515
    static let cameraServiceType = "_tandemcam._tcp"
    static let cameraPort: UInt16 = 51516
    /// Tandem on the sender serves its switched camera to its camera extension, on this Mac only.
    static let switcherPort: UInt16 = 51517

    enum Kind: UInt8 {
        case hello = 1
        case frame = 2
        case ack = 3
        case status = 4
        case ping = 5
        case power = 6
        case display = 7
        case probe = 8
        case probeAck = 9
        case input = 10
        case inputState = 11
        case cameraFrame = 12
        case about = 13
        case cursor = 14
        case cursorShape = 15
        /// One byte, a `Swap`. Older versions ignore it.
        case swap = 16
        /// One byte, a `Peek`. For `opened` and `steppedOut`, a second: 1 if the extending Mac's
        /// keyboard and trackpad drive the display Mac. For `at`, two Float32s. Older versions
        /// ignore it.
        case peek = 17
        /// From the display Mac: its settings menu, as JSON (a `RemoteMenu`). From the extending
        /// Mac: empty, asking for it.
        case settings = 18
        /// From the extending Mac: a `RemoteMenu.Choice` as JSON, to choose in that menu.
        case settingsChoice = 19
        /// A piece of a file pulled through the bubble, from the display Mac; see `FileTransfer`.
        case file = 20
        /// From the extending Mac: a UInt16 of its own `Capabilities`, sent after the hello.
        case features = 21
    }

    /// Bumped whenever the two apps stop understanding each other.
    static let version: UInt16 = 4

    struct Capabilities: OptionSet {
        let rawValue: UInt16
        static let bc7 = Capabilities(rawValue: 1)
        static let brightness = Capabilities(rawValue: 2)
        /// Draws the pointer itself, from cursor and cursorShape messages.
        static let cursor = Capabilities(rawValue: 4)
        /// Takes part in swapping roles, and can take the other's: from the display Mac, it can
        /// extend (macOS 14 or later); the extending Mac can always be a display.
        static let swap = Capabilities(rawValue: 8)
        /// Peeks and steps through to its own desktop when the extending Mac asks, and plays that
        /// Mac's keyboard and trackpad while stepped through.
        static let peek = Capabilities(rawValue: 16)
        /// Sends its settings menu for the extending Mac to show.
        static let settings = Capabilities(rawValue: 32)
        /// From the extending Mac: takes files pulled through the bubble.
        static let files = Capabilities(rawValue: 64)
    }

    /// Peeking from the extending Mac's own keyboard and trackpad.
    enum Peek: UInt8 {
        // From the extending Mac.
        case open = 0
        case close = 1
        case stepThrough = 2
        case comeBack = 3
        // From the display Mac.
        case steppedOut = 4
        case back = 5
        /// The bubble is open; a second byte is 1 if the extending Mac's trackpad works this Mac's
        /// own pointer inside it.
        case opened = 6
        /// Followed by two Float32s: where this Mac's pointer is, as fractions of its screen from
        /// the top left, for the extending Mac's pointer to carry on from.
        case at = 7
        /// The bubble closed by itself, e.g. the extending Mac's pointer left the screen.
        case closed = 8
    }

    /// Swapping roles from either Mac: each says whether it can take the other's role (the
    /// `swap` capability, in the hello or `features`), then one asks the other to swap and both
    /// start again in their new roles.
    enum Swap: UInt8 {
        case now = 1
    }

    enum Power: UInt8 {
        case sleep = 0
        case wake = 1
    }

    /// Whether the MacBook will act on the iMac's keyboard and mouse.
    enum InputState: UInt8 {
        case off = 0
        case needsPermission = 1
        case ready = 2
    }

    enum Encoding: UInt8 {
        case raw = 0
        case lz4 = 1
        case bc7 = 2
        case bc7lz4 = 3
    }

    /// The Thunderbolt Bridge, the only link Tandem trusts: the cable between the two Macs, which
    /// nothing else can be on. macOS calls it bridge0 (in theory a low-numbered bridge); Internet
    /// Sharing and virtual machines make bridges from bridge100 up, which could reach other machines.
    static func isThunderbolt(_ interface: NWInterface) -> Bool {
        guard interface.name.hasPrefix("bridge"), let number = Int(interface.name.dropFirst("bridge".count)) else { return false }
        return number < 100
    }

    /// Whether a connection that's arrived came over the Thunderbolt cable. Anything else, from an
    /// Ethernet network, say, or another app on this Mac, is turned away.
    static func cameOverThunderbolt(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv6(let address): return address.interface.map(isThunderbolt) ?? false
        case .ipv4(let address): return address.interface.map(isThunderbolt) ?? false
        default: return false
        }
    }

    static func tcpParameters(allowWiFi: Bool = true) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        if !allowWiFi {
            params.prohibitedInterfaceTypes = [.wifi, .cellular]
        }
        return params
    }
}

struct Hello {
    var width: Int
    var height: Int
    var mmWide: Double
    var mmHigh: Double
    var version = Wire.version
    var capabilities: Wire.Capabilities = []
    var brightness: Float = -1
    var name: String
    var kind = Machine.kind

    func encoded() -> Data {
        var d = Data()
        d.appendLE(UInt32(width))
        d.appendLE(UInt32(height))
        d.appendLE(mmWide.bitPattern)
        d.appendLE(mmHigh.bitPattern)
        d.appendLE(version)
        d.appendLE(capabilities.rawValue)
        d.appendLE(brightness.bitPattern)
        d.append(Peer(name: name, kind: kind).encoded())
        return d
    }

    init(width: Int, height: Int, mmWide: Double, mmHigh: Double, capabilities: Wire.Capabilities = [],
         brightness: Float = -1, name: String) {
        self.width = width
        self.height = height
        self.mmWide = mmWide
        self.mmHigh = mmHigh
        self.capabilities = capabilities
        self.brightness = brightness
        self.name = name
    }

    /// Nil if malformed. A receiver from another version parses, but with a different `version`.
    init?(_ d: Data) {
        guard d.count >= 32 else { return nil }
        width = Int(d.readLE(UInt32.self, at: 0))
        height = Int(d.readLE(UInt32.self, at: 4))
        mmWide = Double(bitPattern: d.readLE(UInt64.self, at: 8))
        mmHigh = Double(bitPattern: d.readLE(UInt64.self, at: 16))
        version = d.readLE(UInt16.self, at: 24)
        capabilities = Wire.Capabilities(rawValue: d.readLE(UInt16.self, at: 26))
        brightness = Float(bitPattern: d.readLE(UInt32.self, at: 28))
        let peer = Peer(Data(d.dropFirst(32)))
        name = peer?.name ?? "Mac"
        kind = peer?.kind ?? "Mac"
    }
}

/// How the iMac's panel should look: brightness and the MacBook's current colour adaptation.
struct DisplayState: Equatable {
    static let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    var brightness: Float = -1
    var colorMatrix = DisplayState.identity

    func encoded() -> Data {
        var d = Data()
        d.appendLE(brightness.bitPattern)
        for v in colorMatrix { d.appendLE(v.bitPattern) }
        return d
    }

    init(brightness: Float = -1, colorMatrix: [Float] = DisplayState.identity) {
        self.brightness = brightness
        self.colorMatrix = colorMatrix
    }

    init?(_ d: Data) {
        guard d.count >= 40 else { return nil }
        brightness = Float(bitPattern: d.readLE(UInt32.self, at: 0))
        colorMatrix = (0..<9).map { Float(bitPattern: d.readLE(UInt32.self, at: 4 + $0 * 4)) }
    }
}

/// Where the pointer's hotspot is, in the receiver's native pixels, and whether it shows (it
/// doesn't when it's on another screen, or hidden, e.g. while typing).
///
/// i32 x | i32 y | u8 visible
struct CursorPosition: Equatable {
    var x: Int32
    var y: Int32
    var visible: Bool

    func encoded() -> Data {
        var d = Data(capacity: 9)
        d.appendLE(x)
        d.appendLE(y)
        d.append(visible ? 1 : 0)
        return d
    }

    init(x: Int32, y: Int32, visible: Bool) {
        self.x = x
        self.y = y
        self.visible = visible
    }

    init?(_ d: Data) {
        guard d.count >= 9 else { return nil }
        x = d.readLE(Int32.self, at: 0)
        y = d.readLE(Int32.self, at: 4)
        visible = d[d.startIndex + 8] != 0
    }
}

/// The pointer's image at the receiver's pixel scale, with its hotspot.
///
/// u16 width | u16 height | u16 hotX | u16 hotY | premultiplied BGRA rows packed tightly
struct CursorShape {
    var width: Int
    var height: Int
    var hotX: Int
    var hotY: Int
    var pixels: Data

    func encoded() -> Data {
        var d = Data(capacity: 8 + pixels.count)
        d.appendLE(UInt16(width))
        d.appendLE(UInt16(height))
        d.appendLE(UInt16(hotX))
        d.appendLE(UInt16(hotY))
        d.append(pixels)
        return d
    }

    init(width: Int, height: Int, hotX: Int, hotY: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.hotX = hotX
        self.hotY = hotY
        self.pixels = pixels
    }

    init?(_ d: Data) {
        guard d.count >= 8 else { return nil }
        width = Int(d.readLE(UInt16.self, at: 0))
        height = Int(d.readLE(UInt16.self, at: 2))
        hotX = Int(d.readLE(UInt16.self, at: 4))
        hotY = Int(d.readLE(UInt16.self, at: 6))
        guard width > 0, height > 0, d.count == 8 + width * height * 4 else { return nil }
        pixels = Data(d.dropFirst(8))
    }
}

/// One event from the iMac's keyboard or mouse, replayed on the MacBook: a CGEventType, its
/// modifier flags, and the CGEvent fields that matter for that type. Pointer movement travels as
/// deltas; the MacBook works out where its own pointer goes.
///
/// u32 type | u64 flags | then pairs of u32 field, f64 value
struct InputEvent {
    /// Not a real event: let go of every key and button.
    static let releaseAll: UInt32 = 0
    /// Fields of system-defined events (media keys), which aren't CGEvent fields.
    static let subtypeField: UInt32 = 0x1000
    static let data1Field: UInt32 = 0x1001
    static let data2Field: UInt32 = 0x1002

    var type: UInt32
    var flags: UInt64 = 0
    var fields: [UInt32: Double] = [:]

    func encoded() -> Data {
        var d = Data(capacity: 12 + fields.count * 12)
        d.appendLE(type)
        d.appendLE(flags)
        for (field, value) in fields {
            d.appendLE(field)
            d.appendLE(value.bitPattern)
        }
        return d
    }

    init(type: UInt32, flags: UInt64 = 0, fields: [UInt32: Double] = [:]) {
        self.type = type
        self.flags = flags
        self.fields = fields
    }

    init?(_ d: Data) {
        guard d.count >= 12, (d.count - 12) % 12 == 0 else { return nil }
        type = d.readLE(UInt32.self, at: 0)
        flags = d.readLE(UInt64.self, at: 4)
        for offset in stride(from: 12, to: d.count, by: 12) {
            fields[d.readLE(UInt32.self, at: offset)] = Double(bitPattern: d.readLE(UInt64.self, at: offset + 4))
        }
    }

    subscript(field: UInt32) -> Double { fields[field] ?? 0 }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}

/// Length-prefixed message framing over an NWConnection.
final class MessageChannel {
    let connection: NWConnection
    let queue: DispatchQueue
    var onMessage: ((Wire.Kind, Data) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((Error?) -> Void)?
    private var closed = false

    // Unplugging the cable doesn't close a TCP connection; it just goes quiet. Both ends
    // send pings and give up after `silenceLimit` seconds without hearing anything.
    private let pingInterval = 0.5
    private let silenceLimit = 3.0
    private var heartbeat: DispatchSourceTimer?
    private var lastHeard = DispatchTime.now()

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.startHeartbeat()
                self.onReady?()
            case .failed(let e): self.close(e)
            case .cancelled: self.close(nil)
            case .waiting(let e): log("connection waiting: \(e)")
            default: break
            }
        }
        connection.start(queue: queue)
        readHeader()
    }

    /// Safe from any thread. Header and body are queued together, so messages sent from
    /// different threads never interleave.
    func send(_ kind: Wire.Kind, _ body: Data, completion: (() -> Void)? = nil) {
        var header = Data(capacity: 5)
        header.appendLE(UInt32(body.count))
        header.append(kind.rawValue)
        queue.async {
            self.connection.send(content: header, completion: .contentProcessed { _ in })
            self.connection.send(content: body, completion: .contentProcessed { _ in completion?() })
        }
    }

    /// Sends, then reports on the network queue whether it went: false once the link has failed.
    func send(_ kind: Wire.Kind, _ body: Data, sent: @escaping (Bool) -> Void) {
        var header = Data(capacity: 5)
        header.appendLE(UInt32(body.count))
        header.append(kind.rawValue)
        queue.async {
            self.connection.send(content: header, completion: .contentProcessed { _ in })
            self.connection.send(content: body, completion: .contentProcessed { error in sent(error == nil && !self.closed) })
        }
    }

    /// Sends, then calls `then` on the main queue once the message is on its way, or after a
    /// second if the link has gone quiet. For a last word before starting again, say.
    func sendSoon(_ kind: Wire.Kind, _ body: Data, then: @escaping () -> Void) {
        var called = false
        let finish = { DispatchQueue.main.async { if !called { called = true; then() } } }
        send(kind, body, completion: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: finish)
    }

    func cancel() {
        connection.cancel()
    }

    private func startHeartbeat() {
        lastHeard = .now()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let silent = Double(DispatchTime.now().uptimeNanoseconds - self.lastHeard.uptimeNanoseconds) / 1e9
            if silent > self.silenceLimit {
                log("nothing heard for \(String(format: "%.1f", silent)) s, closing")
                return self.close(NWError.posix(.ETIMEDOUT))
            }
            self.send(.ping, Data())
        }
        timer.resume()
        heartbeat = timer
    }

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        connection.cancel()
        onClose?(error)
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, done, error in
            guard let self else { return }
            guard let data, data.count == 5, error == nil else { return self.close(error) }
            self.lastHeard = .now()
            let length = Int(data.readLE(UInt32.self, at: 0))
            let kind = Wire.Kind(rawValue: data[data.startIndex + 4])
            if length == 0 {
                if let kind { self.onMessage?(kind, Data()) }
                return done ? self.close(nil) : self.readHeader()
            }
            self.readBody(length, kind)
        }
    }

    private func readBody(_ length: Int, _ kind: Wire.Kind?) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, done, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else { return self.close(error) }
            self.lastHeard = .now()
            if let kind { self.onMessage?(kind, data) }
            if done { self.close(nil) } else { self.readHeader() }
        }
    }
}

/// FNV-1a over a BGRA image, used by TANDEM_DEBUG to check both ends hold identical pixels.
func imageHash(_ base: UnsafeRawPointer, width: Int, height: Int, stride: Int) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    let words = width * 4 / 8
    for y in 0..<height {
        let row = (base + y * stride).assumingMemoryBound(to: UInt64.self)
        for i in 0..<words {
            h = (h ^ row[i]) &* 0x100_0000_01b3
        }
    }
    return h
}

let debugEnabled = ProcessInfo.processInfo.environment["TANDEM_DEBUG"] != nil

private let logHandle: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    let url = dir.appendingPathComponent("\(ProcessInfo.processInfo.processName).log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try? FileHandle(forWritingTo: url)
}()

private let logQueue = DispatchQueue(label: "log")

private let logTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

private let logger = Logger(subsystem: "Tandem", category: ProcessInfo.processInfo.processName)

func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    let line = "\(logTime.string(from: Date())) \(message)\n"
    logQueue.async {
        FileHandle.standardError.write(Data(line.utf8))
        logHandle?.write(Data(line.utf8))
    }
}
