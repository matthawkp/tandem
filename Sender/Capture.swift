import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit, always delivering frames at the receiver's
/// native pixel size. Scaled ("More Space") modes are resampled here, the same way macOS
/// drives a real Retina panel.
@available(macOS 14, *)
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    private let onFrame: (CVPixelBuffer) -> Void
    private let onStop: (Error) -> Void

    /// Starts and stops come from several places (a new connection, a change of resolution, the
    /// screens waking) and each takes a while, so they overlap. Each one takes the next number;
    /// only the latest keeps its stream, and an earlier one that finishes starting late stops
    /// its own again, rather than being left running with nothing to stop it.
    private let lock = NSLock()
    private var stream: SCStream?
    private var generation = 0

    init(onFrame: @escaping (CVPixelBuffer) -> Void, onStop: @escaping (Error) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// Supersedes any start or stream before it: the stream to stop, and this call's number.
    private func supersede() -> (SCStream?, Int) {
        lock.withLock {
            generation += 1
            defer { stream = nil }
            return (stream, generation)
        }
    }

    private func isLatest(_ number: Int) -> Bool {
        lock.withLock { generation == number }
    }

    /// Keeps `started` as the stream, unless a later start or stop has come along since.
    private func adopt(_ started: SCStream, _ number: Int) -> Bool {
        lock.withLock {
            guard generation == number else { return false }
            stream = started
            return true
        }
    }

    /// `showsCursor` false leaves the pointer out of the picture, for receivers that draw it.
    /// False if a later start or stop took over while this one was starting.
    @discardableResult
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, showsCursor: Bool = true) async throws -> Bool {
        let (old, number) = supersede()
        try? await old?.stopCapture()
        let display = try await Capture.findDisplay(displayID)
        guard isLatest(number) else { return false }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.displayP3
        config.showsCursor = showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.captureResolution = .best
        config.scalesToFit = true

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        guard adopt(stream, number) else {
            try? await stream.stopCapture()
            return false
        }
        log("capture started for display \(displayID) at \(width)x\(height)")
        return true
    }

    func stop() async {
        let (old, _) = supersede()
        try? await old?.stopCapture()
    }

    /// A freshly created virtual display can take a moment to show up in shareable content.
    private static func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let display = content.displays.first(where: { $0.displayID == id }) { return display }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "Tandem", code: 1, userInfo: [NSLocalizedDescriptionKey: "display \(id) not available for capture"])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Only the stream in use: one that was replaced has nothing to restart.
        let wasCurrent = lock.withLock { () -> Bool in
            guard self.stream === stream else { return false }
            self.stream = nil
            return true
        }
        guard wasCurrent else { return }
        log("capture stopped: \(error.localizedDescription)")
        onStop(error)
    }
}
