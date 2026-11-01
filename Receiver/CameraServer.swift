import AVFoundation
import Network

/// Serves this Mac's camera to the Mac it's showing, for Tandem Camera there. The camera only
/// runs while that Mac is using it, so its green light means what it always does.
final class CameraServer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "camera", qos: .userInitiated)
    private var listener: NWListener?
    /// Each viewer, and whether a frame is still on its way to it. On `queue`.
    private var clients: [ObjectIdentifier: (channel: MessageChannel, busy: Bool)] = [:]
    private var session: AVCaptureSession?

    static var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    func start(name: String) {
        guard CameraServer.hasCamera else { return log("camera: none found") }
        do {
            let listener = try NWListener(using: Wire.tcpParameters(allowWiFi: false), on: NWEndpoint.Port(rawValue: Wire.cameraPort)!)
            listener.service = NWListener.Service(name: name, type: Wire.cameraServiceType)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log("camera: couldn't listen: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Wire.cameOverThunderbolt(connection) else {
            log("camera: refused a connection from \(connection.endpoint): not over Thunderbolt")
            return connection.cancel()
        }
        let channel = MessageChannel(connection, queue: queue)
        let id = ObjectIdentifier(channel)
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.clients[id] = nil
            log("camera: viewer left, \(self.clients.count) left")
            if self.clients.isEmpty { self.stopCamera() }
        }
        clients[id] = (channel, false)
        log("camera: viewer from \(connection.endpoint)")
        channel.start()
        startCamera()
    }

    private func startCamera() {
        guard session == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                log("camera: access \(granted ? "allowed" : "refused")")
                if granted { self.queue.async { if !self.clients.isEmpty { self.startCamera() } } }
            }
            return
        default:
            return log("camera: not allowed; System Settings → Privacy & Security → Camera")
        }
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        self.session = session
        log("camera: on")
    }

    private func stopCamera() {
        session?.stopRunning()
        session = nil
        log("camera: off")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer), clients.values.contains(where: { !$0.busy }),
              let body = cameraFrameBody(image) else { return }
        // A viewer that hasn't taken the last frame yet skips this one, rather than falling behind.
        for (id, client) in clients where !client.busy {
            clients[id]?.busy = true
            client.channel.send(.cameraFrame, body) { [weak self] in
                self?.queue.async { self?.clients[id]?.busy = false }
            }
        }
    }
}
