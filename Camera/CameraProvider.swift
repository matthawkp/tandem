import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import Network

/// "Tandem Camera": a camera that shows whichever of the two Macs' cameras you're
/// looking towards.
///
/// This runs as a camera extension, which can't use real cameras itself. While any app is using
/// it, it connects to Tandem on this Mac, which does the switching, and passes its frames on.
private let width = 1280
private let height = 720
private let frameRate: Int32 = 30

final class CameraProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var device: CameraDevice!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        device = CameraDevice()
        do {
            try provider.addDevice(device.device)
        } catch {
            fatalError("couldn't add the camera: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Tandem" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var stream: CameraStream!
    private let queue = DispatchQueue(label: "camera", qos: .userInteractive)
    private var pool: CVPixelBufferPool?
    private var format: CMFormatDescription?
    private var link: CameraLink?
    private var placeholderTimer: DispatchSourceTimer?
    private var lastFrame = DispatchTime(uptimeNanoseconds: 0)
    /// On `queue`.
    private var viewers = 0

    override init() {
        super.init()
        device = CMIOExtensionDevice(localizedName: "Tandem Camera",
                                     deviceID: UUID(uuidString: "5F1E0C3A-6B2D-4E8A-9C47-1D3B5A7E9F21")!,
                                     legacyDeviceID: nil, source: self)
        pool = makeBGRAPool(width: width, height: height)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &format)
        let duration = CMTime(value: 1, timescale: frameRate)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format!, maxFrameDuration: duration,
                                                     minFrameDuration: duration, validFrameDurations: nil)
        stream = CameraStream(format: streamFormat, device: self)
        do {
            try device.addStream(stream.stream)
        } catch {
            fatalError("couldn't add the stream: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = 0x7669_7274 } // 'virt'
        if properties.contains(.deviceModel) { result.model = "Tandem Camera" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Streaming

    func startStreaming() {
        queue.async {
            self.viewers += 1
            guard self.viewers == 1 else { return }
            log("camera: started")
            let link = CameraLink(.local(Wire.switcherPort), queue: self.queue)
            link.onFrame = { [weak self] body in self?.deliver(body) }
            link.start()
            self.link = link
            // Until the pictures arrive (or if it isn't there), show what's going on.
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 0.2)
            timer.setEventHandler { [weak self] in self?.showPlaceholderIfQuiet() }
            timer.resume()
            self.placeholderTimer = timer
        }
    }

    func stopStreaming() {
        queue.async {
            self.viewers = max(0, self.viewers - 1)
            guard self.viewers == 0 else { return }
            log("camera: stopped")
            self.link?.stop()
            self.link = nil
            self.placeholderTimer?.cancel()
            self.placeholderTimer = nil
        }
    }

    /// One frame from Tandem.
    private func deliver(_ body: Data) {
        guard let pool, let buffer = pixelBuffer(fromCameraFrame: body, pool: pool) else { return }
        lastFrame = .now()
        send(buffer)
    }

    private func showPlaceholderIfQuiet() {
        guard DispatchTime.now().uptimeNanoseconds - lastFrame.uptimeNanoseconds > 500_000_000, let buffer = makeBuffer() else { return }
        drawPlaceholder(into: buffer, text: link?.isConnected == true ? "Starting the camera…" : "Open Tandem to use this camera")
        send(buffer)
    }

    private func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func send(_ buffer: CVPixelBuffer) {
        guard let format else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: frameRate), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        stream.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
    }

    private func drawPlaceholder(into buffer: CVPixelBuffer, text: String) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateUIFontForLanguage(.system, 40, nil)!
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.8),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}

final class CameraStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private weak var device: CameraDevice?

    init(format: CMIOExtensionStreamFormat, device: CameraDevice) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: "Tandem Camera", streamID: UUID(uuidString: "8A4C2E61-3F7B-4D19-B5E8-6C0A2F9D4B37")!,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: frameRate) }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { device?.startStreaming() }
    func stopStream() throws { device?.stopStreaming() }
}
