import AVFoundation
import CoreImage
import Network
import Vision

/// Makes one camera out of two: the other Mac's and this one's. In Automatic it shows whichever
/// you're facing, judged by how head-on each camera sees your face, with rules so it settles
/// rather than flickers. The result goes to the Tandem Camera extension, and to the preview.
///
/// Cameras only run while something is watching, and in a fixed mode only that camera runs.
@available(macOS 14, *)
final class CameraSwitcher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Source: String, CaseIterable {
        /// The other Mac's camera, and this Mac's.
        case remote, local
        var other: Source { self == .remote ? .local : .remote }
        var name: String { self == .remote ? Peer.last?.kind ?? "Other Mac" : Machine.kind }
    }

    enum Mode: String {
        case automatic, remote, local
        var fixed: Source? { self == .remote ? .remote : self == .local ? .local : nil }
    }

    /// How readily Automatic switches.
    enum Pace: String, CaseIterable {
        case calm, balanced, quick
        /// Seconds the other camera must be clearly better before switching.
        var dwell: Double { [Pace.calm: 2.5, .balanced: 1.2, .quick: 0.5][self]! }
        /// Seconds after a switch before another is allowed.
        var cooldown: Double { [Pace.calm: 8, .balanced: 4, .quick: 1.5][self]! }
        var title: String { rawValue.capitalized }
    }

    struct Status {
        var showing: Source
        /// How directly each camera sees your face, 0–1; nil when it sees no face or isn't running.
        var facing: [Source: Double?]
        var waiting: Bool
    }

    static let width = 1280, height = 720
    /// How much more head-on the other camera must see you, so near-ties don't switch.
    private static let margin = 0.15
    /// Below this, the other camera barely sees you, so it isn't worth switching to.
    private static let minimumFacing = 0.35
    private static let fadeDuration = 0.35
    private static let analysisInterval = 0.15
    /// How often each camera's view of your skin is measured, for matching colour.
    private static let skinInterval = 0.5
    private static let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!

    /// On the main thread.
    var onStatus: (Status) -> Void = { _ in }
    var onFrame: (CVPixelBuffer) -> Void = { _ in }

    private let queue = DispatchQueue(label: "switcher", qos: .userInteractive)
    private let ciContext = CIContext()
    /// Separate pools, so a frame being shown is never refilled with the other camera's picture.
    private let pool = makeBGRAPool(width: CameraSwitcher.width, height: CameraSwitcher.height)
    private let remotePool = makeBGRAPool(width: CameraSwitcher.width, height: CameraSwitcher.height)
    private var listener: NWListener?

    // On `queue`.
    private var mode = Mode.automatic
    private var pace = Pace.balanced
    private var viewers: [ObjectIdentifier: (channel: MessageChannel, busy: Bool)] = [:]
    private var previewing = false
    private var running = false
    private var macSession: AVCaptureSession?
    private var remoteLink: CameraLink?
    private var latest: [Source: (buffer: CVPixelBuffer, at: DispatchTime)] = [:]
    private var lastAnalysis: [Source: DispatchTime] = [:]
    private var facing: [Source: Double] = [:]
    private var sawFace: [Source: Bool] = [:]
    private var showing = Source.remote
    private var betterSince: DispatchTime?
    private var lastSwitch = DispatchTime(uptimeNanoseconds: 0)
    private var fadeFrom: (source: Source, at: DispatchTime)?
    private var outputTimer: DispatchSourceTimer?
    private var lastStatus = DispatchTime(uptimeNanoseconds: 0)
    private var frameCount = 0
    /// Red, green and blue gains that make the other Mac's camera match this one's colour,
    /// learnt from your face whenever both cameras see it.
    private var matchesColour = true
    private var remoteGains = Preferences.shared.cameraColourGains
    private var skin: [Source: (colour: SIMD3<Double>, at: DispatchTime)] = [:]
    private var lastSkin: [Source: DispatchTime] = [:]
    private var lastGainsSaved = DispatchTime.now()

    func start(mode: Mode, pace: Pace, matchesColour: Bool) {
        queue.async {
            self.mode = mode
            self.pace = pace
            self.matchesColour = matchesColour
            self.showing = mode.fixed ?? .remote
        }
        do {
            // This Mac only: it's for Tandem's own camera extension.
            let params = Wire.tcpParameters()
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Wire.switcherPort)!)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log("camera switcher: couldn't listen: \(error)")
        }
    }

    func setMode(_ mode: Mode) {
        queue.async {
            guard mode != self.mode else { return }
            self.mode = mode
            if let fixed = mode.fixed { self.switchTo(fixed, reason: "chosen") }
            // Only run the cameras this mode needs.
            if self.running { self.stopSources(); self.startSources() }
        }
    }

    func setPace(_ pace: Pace) {
        queue.async { self.pace = pace }
    }

    func setMatchesColour(_ matches: Bool) {
        queue.async { self.matchesColour = matches }
    }

    func setPreviewing(_ previewing: Bool) {
        queue.async {
            self.previewing = previewing
            self.updateRunning()
        }
    }

    // MARK: Viewers

    private func accept(_ connection: NWConnection) {
        let channel = MessageChannel(connection, queue: queue)
        let id = ObjectIdentifier(channel)
        channel.onClose = { [weak self] _ in
            self?.viewers[id] = nil
            self?.updateRunning()
        }
        viewers[id] = (channel, false)
        channel.start()
        log("camera switcher: Tandem Camera in use")
        updateRunning()
    }

    private func updateRunning() {
        let needed = previewing || !viewers.isEmpty
        guard needed != running else { return }
        running = needed
        if needed {
            startSources()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in self?.outputFrame() }
            timer.resume()
            outputTimer = timer
        } else {
            outputTimer?.cancel()
            outputTimer = nil
            stopSources()
        }
        log("camera switcher: \(needed ? "on" : "off")")
    }

    // MARK: Cameras

    private func uses(_ source: Source) -> Bool {
        mode.fixed == nil || mode.fixed == source
    }

    private func startSources() {
        if uses(.remote) {
            let link = CameraLink(.display, queue: queue)
            link.onFrame = { [weak self] body in
                guard let self, let pool = self.remotePool, let buffer = pixelBuffer(fromCameraFrame: body, pool: pool) else { return }
                self.arrived(buffer, from: .remote)
            }
            link.start()
            remoteLink = link
        }
        if uses(.local) { startLocalCamera() }
    }

    private func stopSources() {
        remoteLink?.stop()
        remoteLink = nil
        macSession?.stopRunning()
        macSession = nil
        latest = [:]
        facing = [:]
        sawFace = [:]
        betterSince = nil
    }

    private func startLocalCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.queue.async { if granted && self.running && self.macSession == nil { self.startLocalCamera() } }
            }
            return
        default:
            return log("camera switcher: no permission for this Mac's camera")
        }
        // The built-in camera only, never Tandem Camera itself or an iPhone.
        guard let camera = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                            position: .unspecified).devices.first,
              let input = try? AVCaptureDeviceInput(device: camera) else { return log("camera switcher: no built-in camera") }
        let session = AVCaptureSession()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        macSession = session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        arrived(buffer, from: .local)
    }

    private func arrived(_ buffer: CVPixelBuffer, from source: Source) {
        let now = DispatchTime.now()
        latest[source] = (buffer, now)
        guard mode == .automatic, seconds(since: lastAnalysis[source]) >= CameraSwitcher.analysisInterval else { return }
        lastAnalysis[source] = now
        analyse(buffer, from: source)
        decide()
    }

    // MARK: Deciding

    /// How directly the camera sees the largest face: 1 straight on, 0 at 40° or more, or no face.
    private func analyse(_ buffer: CVPixelBuffer, from source: Source) {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        let face = request.results?.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        var raw = 0.0
        if let face {
            let yaw = face.yaw?.doubleValue ?? 0, pitch = face.pitch?.doubleValue ?? 0
            raw = max(0, 1 - (yaw * yaw + pitch * pitch).squareRoot() / 0.7)
        }
        sawFace[source] = face != nil
        if let face, seconds(since: lastSkin[source]) >= CameraSwitcher.skinInterval {
            lastSkin[source] = .now()
            if let colour = skinColour(in: buffer, face: face.boundingBox) {
                skin[source] = (colour, .now())
                learnColour()
            }
        }
        // Smoothed, so one odd frame doesn't count for much.
        facing[source] = (facing[source] ?? raw) * 0.6 + raw * 0.4
    }

    // MARK: Matching colour

    /// The average colour of the middle of the face (cheeks, nose, forehead; not hair or
    /// background), in linear light. Nil if it's too dark or too blown out to tell.
    private func skinColour(in buffer: CVPixelBuffer, face: CGRect) -> SIMD3<Double>? {
        let width = CGFloat(CVPixelBufferGetWidth(buffer)), height = CGFloat(CVPixelBufferGetHeight(buffer))
        let box = CGRect(x: face.minX * width, y: face.minY * height, width: face.width * width, height: face.height * height)
        let middle = box.insetBy(dx: box.width * 0.25, dy: box.height * 0.2)
        guard middle.width >= 8, middle.height >= 8 else { return nil }
        let average = CIImage(cvPixelBuffer: buffer).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: middle)])
        var pixel = [Float](repeating: 0, count: 4)
        ciContext.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBAf, colorSpace: CameraSwitcher.linear)
        let colour = SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
        guard colour.min() > 0.01, colour.max() < 0.9 else { return nil }
        return colour
    }

    /// When both cameras have just seen your face, nudges the other Mac's gains towards making
    /// your skin the same colour as this Mac's camera sees it. Colour only: each camera keeps its
    /// own brightness. Slowly, so a passing shadow or a turn of the head doesn't show.
    private func learnColour() {
        guard let here = skin[.local], let there = skin[.remote],
              seconds(since: here.at) < 2, seconds(since: there.at) < 2 else { return }
        let luma = SIMD3(0.2126, 0.7152, 0.0722)
        var gains = here.colour / there.colour
        gains /= (gains * there.colour * luma).sum() / (there.colour * luma).sum()
        gains = gains.clamped(lowerBound: SIMD3(repeating: 0.7), upperBound: SIMD3(repeating: 1.4))
        remoteGains += (gains - remoteGains) * 0.08
        if seconds(since: lastGainsSaved) > 10 {
            lastGainsSaved = .now()
            let saved = remoteGains
            DispatchQueue.main.async { Preferences.shared.cameraColourGains = saved }
        }
    }

    /// The gains to apply to the other Mac's pictures, if any.
    private var colourGains: SIMD3<Double>? {
        guard matchesColour, (remoteGains - 1).max() > 0.005 || (1 - remoteGains).max() > 0.005 else { return nil }
        return remoteGains
    }

    /// A camera's picture, fitted to 1280×720 and, for the other Mac's, matched in colour.
    private func picture(_ buffer: CVPixelBuffer, from source: Source) -> CIImage {
        let image = fitted(CIImage(cvPixelBuffer: buffer))
        guard source == .remote, let gains = colourGains else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gains.x, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gains.y, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gains.z, w: 0),
        ])
    }

    // MARK: Switching

    private func decide() {
        let now = DispatchTime.now()
        let current = showing, other = showing.other
        let currentLive = seconds(since: latest[current]?.at) < 1
        let otherLive = seconds(since: latest[other]?.at) < 1
        if !currentLive && otherLive {
            return switchTo(other, reason: "\(current.name) camera stopped")
        }
        let here = facing[current] ?? 0, there = facing[other] ?? 0
        // You're facing the other camera clearly more, and it sees you well.
        guard otherLive, sawFace[other] == true, there >= CameraSwitcher.minimumFacing,
              there > here + CameraSwitcher.margin else {
            betterSince = nil
            return
        }
        if betterSince == nil { betterSince = now }
        guard seconds(since: betterSince) >= pace.dwell, seconds(since: lastSwitch) >= pace.cooldown else { return }
        switchTo(other, reason: String(format: "facing %.2f vs %.2f", there, here))
    }

    private func switchTo(_ source: Source, reason: String) {
        guard source != showing else { return }
        log("camera switcher: \(source.name) camera (\(reason))")
        if latest[showing] != nil { fadeFrom = (showing, .now()) }
        showing = source
        lastSwitch = .now()
        betterSince = nil
    }

    private func seconds(since time: DispatchTime?) -> Double {
        guard let time else { return .infinity }
        return Double(DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds) / 1e9
    }

    // MARK: Output

    private func outputFrame() {
        publishStatus()
        guard let (source, frame) = [showing, showing.other].lazy.compactMap({ source in self.latest[source].map { (source, $0.buffer) } }).first
        else { return }
        var image = picture(frame, from: source)
        if let fade = fadeFrom, let from = latest[fade.source]?.buffer {
            let t = seconds(since: fade.at) / CameraSwitcher.fadeDuration
            if t < 1 {
                image = picture(from, from: fade.source).applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: image, kCIInputTimeKey: t * t * (3 - 2 * t),
                ])
            } else {
                fadeFrom = nil
            }
        }
        var out: CVPixelBuffer?
        if fadeFrom == nil, source == .local || colourGains == nil, CVPixelBufferGetWidth(frame) == CameraSwitcher.width, CVPixelBufferGetHeight(frame) == CameraSwitcher.height {
            out = frame
        } else if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
            if let out { ciContext.render(image, to: out) }
        }
        guard let out else { return }

        if viewers.values.contains(where: { !$0.busy }), let body = cameraFrameBody(out) {
            for (id, viewer) in viewers where !viewer.busy {
                viewers[id]?.busy = true
                viewer.channel.send(.cameraFrame, body) { [weak self] in
                    self?.queue.async { self?.viewers[id]?.busy = false }
                }
            }
        }
        frameCount += 1
        if previewing && frameCount % 2 == 0 {
            DispatchQueue.main.async { self.onFrame(out) }
        }
    }

    /// Scaled to fill 1280×720, cropping if the shape differs.
    private func fitted(_ image: CIImage) -> CIImage {
        let w = CGFloat(CameraSwitcher.width), h = CGFloat(CameraSwitcher.height)
        guard image.extent.width != w || image.extent.height != h else { return image }
        let scale = max(w / image.extent.width, h / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(translationX: (w - scaled.extent.width) / 2 - scaled.extent.minX,
                                                         y: (h - scaled.extent.height) / 2 - scaled.extent.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func publishStatus() {
        guard previewing, seconds(since: lastStatus) >= 0.25 else { return }
        lastStatus = .now()
        var facingNow: [Source: Double?] = [:]
        for source in Source.allCases {
            let live = seconds(since: latest[source]?.at) < 1
            facingNow[source] = live && sawFace[source] == true ? facing[source] : nil
        }
        let status = Status(showing: showing, facing: facingNow, waiting: latest.isEmpty)
        DispatchQueue.main.async { self.onStatus(status) }
    }
}
