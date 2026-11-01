import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit, always delivering frames at the receiver's
/// native pixel size. Scaled ("More Space") modes are resampled here, the same way macOS
/// drives a real Retina panel.
@available(macOS 14, *)
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    private let onFrame: (CVPixelBuffer) -> Void
    private let onStop: (Error) -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void, onStop: @escaping (Error) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// `showsCursor` false leaves the pointer out of the picture, for receivers that draw it.
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, showsCursor: Bool = true) async throws {
        await stop()
        let display = try await Capture.findDisplay(displayID)

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
        self.stream = stream
        log("capture started for display \(displayID) at \(width)x\(height)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
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
        log("capture stopped: \(error.localizedDescription)")
        self.stream = nil
        onStop(error)
    }
}
