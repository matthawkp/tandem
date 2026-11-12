// A stand-in for the Mac that extends, for testing Tandem Display without a second machine or
// a screen: Tandem's own encoder (its Swift files are compiled in, see test/run.sh) driving a
// moving test pattern at a receiver, then checking the receiver ends up with the same pixels.
//
//   tandem-test-sender <host> <port> <frames> <lossless|bc7>
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
guard arguments.count >= 5, let port = UInt16(arguments[2]), let frameCount = Int(arguments[3]) else {
    print("usage: tandem-test-sender <host> <port> <frames> <lossless|bc7>")
    exit(2)
}
let forceBC7 = arguments[4] == "bc7"

/// Tandem's SyntheticSource: a moving box over a detailed still background.
final class Pattern {
    let width: Int, height: Int, stride: Int
    let pixels: UnsafeMutableRawPointer
    private let background: UnsafeMutableRawPointer
    private var t = 0
    private var box = (x: 0, y: 0, w: 600, h: 400)

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        stride = width * 4
        pixels = .allocate(byteCount: stride * height, alignment: 64)
        background = .allocate(byteCount: stride * height, alignment: 64)
        let bg = background.assumingMemoryBound(to: UInt32.self)
        for y in 0..<height {
            for x in 0..<width {
                let glyph = ((x / 3) ^ (y / 5)) % 7 == 0 && (y / 24) % 2 == 0
                let r = UInt32(x * 255 / width), g = UInt32(y * 255 / height), b: UInt32 = 200
                bg[y * width + x] = glyph ? 0xFF20_2020 : (0xFF00_0000 | r << 16 | g << 8 | b)
            }
        }
        memcpy(pixels, background, stride * height)
        box.w = min(600, width / 2)
        box.h = min(400, height / 2)
    }

    func step() {
        for y in box.y..<(box.y + box.h) {
            memcpy(pixels + y * stride + box.x * 4, background + y * stride + box.x * 4, box.w * 4)
        }
        t += 1
        box.x = Int((sin(Double(t) / 60) * 0.5 + 0.5) * Double(width - box.w))
        box.y = Int((cos(Double(t) / 47) * 0.5 + 0.5) * Double(height - box.h))
        let color: UInt32 = 0xFF00_0000 | UInt32(t * 3 % 256) << 16 | 0x0080FF
        for y in box.y..<(box.y + box.h) {
            let row = (pixels + y * stride).assumingMemoryBound(to: UInt32.self)
            for x in box.x..<(box.x + box.w) { row[x] = color }
        }
    }
}

let netQueue = DispatchQueue(label: "net")
let connection = NWConnection(host: NWEndpoint.Host(arguments[1]), port: NWEndpoint.Port(rawValue: port)!, using: Wire.tcpParameters())
let channel = MessageChannel(connection, queue: netQueue)
let gotHello = DispatchSemaphore(value: 0)
let acked = DispatchSemaphore(value: 0)
let probed = DispatchSemaphore(value: 0)
var hello: Hello?
var ackCount = 0
var lastAcked: UInt32 = 0
var pings = 0
var closed = false

channel.onMessage = { kind, body in
    switch kind {
    case .hello:
        hello = Hello(body)
        gotHello.signal()
    case .ack:
        ackCount += 1
        if body.count >= 4 { lastAcked = body.readLE(UInt32.self, at: 0) }
        acked.signal()
    case .probeAck:
        probed.signal()
    case .ping:
        pings += 1
    default:
        print("unexpected message \(kind) of \(body.count) bytes")
    }
}
channel.onClose = { error in
    closed = true
    print("connection closed\(error.map { ": \($0)" } ?? "")")
    gotHello.signal(); acked.signal(); probed.signal()
}
channel.start()

guard gotHello.wait(timeout: .now() + 10) == .success, let hello else {
    print("FAIL: no hello")
    exit(1)
}
let capabilities = hello.capabilities
print("hello: \(hello.width)x\(hello.height), \(Int(hello.mmWide))x\(Int(hello.mmHigh)) mm, version \(hello.version), capabilities \(capabilities.rawValue) (bc7 \(capabilities.contains(.bc7)), cursor \(capabilities.contains(.cursor)), brightness \(capabilities.contains(.brightness))), name \"\(hello.name)\", kind \"\(hello.kind)\"")
guard hello.version == Wire.version else {
    print("FAIL: version \(hello.version)")
    exit(1)
}

// What the real sender says after the hello.
channel.send(.about, Peer(name: "Test Mac", kind: "MacBook Pro").encoded())
var features = Data()
features.appendLE(Wire.Capabilities([.files, .swap]).rawValue)
channel.send(.features, features)
channel.send(.inputState, Data([Wire.InputState.ready.rawValue]))
channel.send(.status, Data("A status message from the test sender".utf8))
channel.send(.display, DisplayState(brightness: -1).encoded())

// The link probe: filler, each answered with its size.
let filler = Data(count: 4 << 20)
let probeStart = DispatchTime.now()
for _ in 0..<8 { channel.send(.probe, filler) }
for _ in 0..<8 {
    guard probed.wait(timeout: .now() + 20) == .success, !closed else { print("FAIL: probe not answered"); exit(1) }
}
let probeSeconds = Double(DispatchTime.now().uptimeNanoseconds - probeStart.uptimeNanoseconds) / 1e9
print(String(format: "probe: 32 MB answered in %.0f ms", probeSeconds * 1000))

// A pointer: a white square with a black edge, premultiplied BGRA.
var shape = Data(count: 32 * 32 * 4)
for y in 0..<32 { for x in 0..<32 {
    let edge = x < 2 || y < 2 || x > 29 || y > 29
    let i = (y * 32 + x) * 4
    shape[i] = edge ? 0 : 255; shape[i + 1] = edge ? 0 : 255; shape[i + 2] = edge ? 0 : 255; shape[i + 3] = 255
} }
channel.send(.cursorShape, CursorShape(width: 32, height: 32, hotX: 4, hotY: 4, pixels: shape).encoded())

let pattern = Pattern(width: hello.width, height: hello.height)
let encoder = TileEncoder(width: hello.width, height: hello.height, bc7: capabilities.contains(.bc7))
// Slower than any cable, so that whatever keeps changing goes as BC7.
if forceBC7 { encoder.linkBytesPerSecond = 100_000 }
var frameNo: UInt32 = 0
var sent = 0, sentBytes = 0, rawBytes = 0, bc7Bytes = 0, inFlight = 0
let start = DispatchTime.now()

func pump() -> Bool {
    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    let frame = TileEncoder.Frame(base: pattern.pixels, stride: pattern.stride, source: .memory(pattern.pixels, stride: pattern.stride))
    guard let (body, stats) = encoder.encode(frame, frameNo: frameNo &+ 1, now: now) else { return false }
    frameNo &+= 1
    sent += 1
    sentBytes += body.count
    rawBytes += stats.rawBytes
    bc7Bytes += stats.bc7Raw
    inFlight += 1
    channel.send(.frame, body)
    return true
}

func waitForRoom(_ limit: Int) {
    while inFlight >= limit {
        guard acked.wait(timeout: .now() + 30) == .success, !closed else { print("FAIL: frame \(frameNo) not acknowledged"); exit(1) }
        inFlight -= 1
    }
}

for i in 0..<frameCount {
    pattern.step()
    channel.send(.cursor, CursorPosition(x: Int32(100 + i * 7), y: Int32(100 + i * 5), visible: true).encoded())
    _ = pump()
    waitForRoom(2)
    // Around 60 a second, so that what moves counts as moving.
    Thread.sleep(forTimeInterval: 1.0 / 60)
}
let moving = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
// Still now: whatever went lossy is sent again, sharp.
var settle = 0
while encoder.needsRefresh && settle < 400 {
    Thread.sleep(forTimeInterval: 0.05)
    _ = pump()
    waitForRoom(2)
    settle += 1
}
waitForRoom(1)
Thread.sleep(forTimeInterval: 0.3)

let hash = imageHash(pattern.pixels, width: pattern.width, height: pattern.height, stride: pattern.stride)
print(String(format: "sent %d frames (%d while moving, in %.1f s = %.0f a second), %.1f MB for %.1f MB of picture, %.1f MB of it as BC7; %d acknowledged, last %u; %d pings heard",
             sent, frameCount, moving, Double(frameCount) / moving, Double(sentBytes) / 1e6, Double(rawBytes) / 1e6, Double(bc7Bytes) / 1e6, ackCount, lastAcked, pings))
print("needs refresh: \(encoder.needsRefresh)")
print("final frame \(frameNo) hash \(String(hash, radix: 16))")
exit(closed ? 1 : 0)
