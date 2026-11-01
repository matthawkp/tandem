import CoreVideo
import Foundation
import Metal

/// Finds the tiles of a captured frame that differ from the previous one, on the GPU. Comparing
/// two 5K frames reads 118 MB; the CPU spent most of its time on Tandem doing that, and the GPU
/// reads memory many times faster. The result is exact, pixel for pixel.
///
/// Keeps its own copy of the previous frame in GPU memory, so every frame passed in must be the
/// one that's then sent (the encoder sends every changed tile).
@available(macOS 14, *)
final class TileDiffer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let previous: MTLTexture
    private let flags: MTLBuffer
    private var textureCache: CVMetalTextureCache?
    private var hasPrevious = false
    private let width: Int, height: Int, tileWidth: Int, tileHeight: Int, columns: Int, bands: Int

    init?(width: Int, height: Int, tileWidth: Int, tileHeight: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: TileDiffer.shader, options: nil)
            pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "diffTiles")!)
        } catch {
            log("GPU tile comparison unavailable: \(error)")
            return nil
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .private
        columns = (width + tileWidth - 1) / tileWidth
        bands = (height + tileHeight - 1) / tileHeight
        guard let previous = device.makeTexture(descriptor: desc),
              let flags = device.makeBuffer(length: columns * bands * 4, options: .storageModeShared)
        else { return nil }
        self.device = device
        self.queue = queue
        self.previous = previous
        self.flags = flags
        self.width = width
        self.height = height
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Forget the previous frame: the next comparison reports every tile.
    func reset() { hasPrevious = false }

    /// The tiles of `buffer` that changed since the last call (all of them the first time), or
    /// nil if the GPU failed, in which case the next call reports every tile.
    func changedTiles(_ buffer: CVPixelBuffer) -> [Bool]? {
        var cvTexture: CVMetalTexture?
        guard let cache = textureCache,
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let current = cvTexture.flatMap(CVMetalTextureGetTexture),
              let commands = queue.makeCommandBuffer()
        else { hasPrevious = false; return nil }
        let compared = hasPrevious
        memset(flags.contents(), 0, flags.length)

        if compared, let encoder = commands.makeComputeCommandEncoder() {
            var columns = UInt32(self.columns)
            var tile = SIMD2<UInt32>(UInt32(tileWidth), UInt32(tileHeight))
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(previous, index: 1)
            encoder.setBuffer(flags, offset: 0, index: 0)
            encoder.setBytes(&columns, length: 4, index: 1)
            encoder.setBytes(&tile, length: 8, index: 2)
            // One thread per 4 pixels in a row.
            encoder.dispatchThreads(MTLSize(width: (width + 3) / 4, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            encoder.endEncoding()
        }
        // Then remember this frame for next time.
        if let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: current, to: previous)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(cvTexture) {}
        guard commands.status == .completed else {
            log("GPU tile comparison failed: \(commands.error.map { "\($0)" } ?? "unknown error")")
            hasPrevious = false
            return nil
        }
        hasPrevious = true
        guard compared else { return [Bool](repeating: true, count: columns * bands) }
        let marks = flags.contents().bindMemory(to: UInt32.self, capacity: columns * bands)
        return (0..<(columns * bands)).map { marks[$0] != 0 }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    // Each thread compares 4 pixels of one row and marks their tile if any differ. Many threads
    // may mark the same tile; they all write the same value, so no atomics are needed.
    kernel void diffTiles(texture2d<float, access::read> current [[texture(0)]],
                          texture2d<float, access::read> previous [[texture(1)]],
                          device uint *flags [[buffer(0)]],
                          constant uint &columns [[buffer(1)]],
                          constant uint2 &tile [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint width = current.get_width(), y = gid.y;
        uint x0 = gid.x * 4;
        bool differs = false;
        for (uint x = x0; x < min(x0 + 4, width); x++) {
            differs |= any(current.read(uint2(x, y)) != previous.read(uint2(x, y)));
        }
        if (differs) { flags[(y / tile.y) * columns + x0 / tile.x] = 1; }
    }
    """
}
