import CoreVideo
import Foundation
import Network

/// Receives camera frames and reconnects by itself: either from the display Mac's camera service,
/// found over Bonjour on the Thunderbolt link, or from Tandem on this Mac (for the camera extension).
final class CameraLink {
    enum Target {
        /// The camera of the Mac being used as a display.
        case display
        /// Tandem's camera switcher on this Mac.
        case local(UInt16)
    }

    var onFrame: (Data) -> Void = { _ in }
    private let target: Target
    private let queue: DispatchQueue
    private var browser: NWBrowser?
    private var results: [NWBrowser.Result] = []
    private var channel: MessageChannel?
    private var stopped = false
    private(set) var isConnected = false

    init(_ target: Target, queue: DispatchQueue) {
        self.target = target
        self.queue = queue
    }

    func start() {
        guard case .display = target else { return connect() }
        let browser = NWBrowser(for: .bonjour(type: Wire.cameraServiceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.results = Array(results)
            self?.connect()
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        stopped = true
        browser?.cancel()
        channel?.cancel()
    }

    private func connect() {
        guard channel == nil, !stopped else { return }
        let connection: NWConnection
        switch target {
        case .display:
            guard let (result, interface) = results.lazy.compactMap({ result -> (NWBrowser.Result, NWInterface)? in
                result.interfaces.first(where: Wire.isThunderbolt).map { (result, $0) }
            }).first else { return }
            let params = Wire.tcpParameters(allowWiFi: false)
            params.requiredInterface = interface
            connection = NWConnection(to: result.endpoint, using: params)
        case .local(let port):
            connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: Wire.tcpParameters())
        }
        let channel = MessageChannel(connection, queue: queue)
        channel.onReady = { [weak self] in self?.isConnected = true }
        channel.onMessage = { [weak self] kind, body in
            if kind == .cameraFrame { self?.onFrame(body) }
        }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.channel = nil
            self.isConnected = false
            self.queue.asyncAfter(deadline: .now() + 1) { self.connect() }
        }
        self.channel = channel
        channel.start()
    }
}

/// A camera frame as sent: u32 width, u32 height, then BGRA rows packed tightly.
func cameraFrameBody(_ buffer: CVPixelBuffer) -> Data? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
          let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    var body = Data(capacity: 8 + width * height * 4)
    body.appendLE(UInt32(width))
    body.appendLE(UInt32(height))
    for y in 0..<height {
        body.append((base + y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4)
    }
    return body
}

/// The reverse, into a BGRA buffer from `pool`. Nil if the sizes don't match.
func pixelBuffer(fromCameraFrame body: Data, pool: CVPixelBufferPool) -> CVPixelBuffer? {
    guard body.count >= 8 else { return nil }
    let width = Int(body.readLE(UInt32.self, at: 0)), height = Int(body.readLE(UInt32.self, at: 4))
    // Checked before they're multiplied: sizes from outside could otherwise overflow.
    guard (1...Wire.maxDimension).contains(width), (1...Wire.maxDimension).contains(height) else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    guard let buffer, body.count == 8 + width * height * 4,
          CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    body.withUnsafeBytes { raw in
        for y in 0..<height {
            memcpy(base + y * stride, raw.baseAddress! + 8 + y * width * 4, width * 4)
        }
    }
    return buffer
}

/// A pool of IOSurface-backed BGRA buffers, as cameras and Core Image like them.
func makeBGRAPool(width: Int, height: Int) -> CVPixelBufferPool? {
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    return pool
}
