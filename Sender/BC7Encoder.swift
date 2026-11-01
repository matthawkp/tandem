import CoreVideo
import Foundation
import Metal

/// GPU BC7 encoder for tiles that are changing too fast to send losslessly.
///
/// Uses BC7 mode 6 only: one pair of endpoints per 4×4 block with 16 steps between them. That
/// suits screen content well: text and UI edges are mostly two colours per block, and photos
/// and video vary smoothly. The receiver's GPU decodes it natively, at a quarter of the size
/// of BGRA.
@available(macOS 14, *)
final class BC7Encoder {
    let width: Int
    let height: Int
    var blocksPerRow: Int { (width + 3) / 4 }
    static let blockBytes = 16

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let output: MTLBuffer
    private var tileBuffer: MTLBuffer
    private var textureCache: CVMetalTextureCache?
    private var uploadTexture: MTLTexture?

    enum Source {
        case pixelBuffer(CVPixelBuffer)
        case memory(UnsafeRawPointer, stride: Int)
    }

    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        do {
            let library = try device.makeLibrary(source: BC7Encoder.shader, options: nil)
            pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "encodeBC7")!)
        } catch {
            log("BC7 encoder unavailable: \(error)")
            return nil
        }
        self.width = width
        self.height = height
        self.device = device
        self.queue = queue
        let blocks = ((width + 3) / 4) * ((height + 3) / 4)
        guard let output = device.makeBuffer(length: blocks * BC7Encoder.blockBytes, options: .storageModeShared),
              let tileBuffer = device.makeBuffer(length: 4096 * 8, options: .storageModeShared)
        else { return nil }
        self.output = output
        self.tileBuffer = tileBuffer
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Encodes the given tiles (pixel origins) into a frame-sized block buffer laid out row by
    /// row, `blocksPerRow` blocks per row. Returns the buffer, valid until the next call.
    func encode(tiles: [(x: Int, y: Int)], tileWidth: Int, tileHeight: Int, from source: Source) -> UnsafeRawPointer? {
        guard !tiles.isEmpty else { return UnsafeRawPointer(output.contents()) }
        var cvTexture: CVMetalTexture?
        let texture: MTLTexture
        switch source {
        case .pixelBuffer(let buffer):
            guard let cache = textureCache,
                  CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                                                            0, &cvTexture) == kCVReturnSuccess,
                  let t = cvTexture.flatMap(CVMetalTextureGetTexture)
            else { return nil }
            texture = t
        case .memory(let base, let stride):
            if uploadTexture == nil {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                desc.usage = .shaderRead
                desc.storageMode = .shared
                uploadTexture = device.makeTexture(descriptor: desc)
            }
            guard let t = uploadTexture else { return nil }
            for tile in tiles {
                let w = min(tileWidth, width - tile.x), h = min(tileHeight, height - tile.y)
                t.replace(region: MTLRegionMake2D(tile.x, tile.y, w, h), mipmapLevel: 0,
                          withBytes: base + tile.y * stride + tile.x * 4, bytesPerRow: stride)
            }
            texture = t
        }

        if tileBuffer.length < tiles.count * 8 {
            guard let bigger = device.makeBuffer(length: tiles.count * 8, options: .storageModeShared) else { return nil }
            tileBuffer = bigger
        }
        let origins = tileBuffer.contents().bindMemory(to: UInt32.self, capacity: tiles.count * 2)
        for (i, tile) in tiles.enumerated() {
            origins[i * 2] = UInt32(tile.x)
            origins[i * 2 + 1] = UInt32(tile.y)
        }

        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return nil }
        var blocksPerRow = UInt32(self.blocksPerRow)
        var tileBlocks = SIMD2<UInt32>(UInt32(tileWidth / 4), UInt32(tileHeight / 4))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(tileBuffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&blocksPerRow, length: 4, index: 2)
        encoder.setBytes(&tileBlocks, length: 8, index: 3)
        let group = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (tileWidth / 4 + 7) / 8, height: (tileHeight / 4 + 7) / 8, depth: tiles.count),
                                     threadsPerThreadgroup: group)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(cvTexture) {}
        guard commands.status == .completed else {
            log("BC7 encode failed: \(commands.error.map { "\($0)" } ?? "unknown error")")
            return nil
        }
        return UnsafeRawPointer(output.contents())
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    constant float kWeights[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};

    static void put(thread uint *words, thread uint &pos, uint value, uint bits) {
        uint word = pos >> 5, shift = pos & 31;
        words[word] |= value << shift;
        if (shift + bits > 32) words[word + 1] |= value >> (32 - shift);
        pos += bits;
    }

    // Nearest 7-bit endpoint plus p-bit (the shared lowest bit) to an 8-bit colour.
    static float3 quantize(float3 e, thread uint3 &q, thread uint &p) {
        float best = INFINITY;
        float3 result = 0;
        for (uint pb = 0; pb < 2; pb++) {
            float3 qq = clamp(rint((e - float(pb)) * 0.5), 0.0, 127.0);
            float3 r = qq * 2.0 + float(pb);
            float d = distance_squared(r, e);
            if (d < best) { best = d; q = uint3(qq); p = pb; result = r; }
        }
        return result;
    }

    static float evaluate(thread const float3 *px, float3 e0, float3 e1,
                          thread uint3 &q0, thread uint3 &q1, thread uint &p0, thread uint &p1, thread uint *idx) {
        float3 r0 = quantize(clamp(e0, 0.0, 255.0), q0, p0);
        float3 r1 = quantize(clamp(e1, 0.0, 255.0), q1, p1);
        float3 palette[16];
        for (uint i = 0; i < 16; i++) {
            float w = kWeights[i];
            palette[i] = floor(((64.0 - w) * r0 + w * r1 + 32.0) / 64.0);
        }
        float err = 0;
        for (uint i = 0; i < 16; i++) {
            float best = INFINITY;
            uint bi = 0;
            for (uint j = 0; j < 16; j++) {
                float d = distance_squared(px[i], palette[j]);
                if (d < best) { best = d; bi = j; }
            }
            idx[i] = bi;
            err += best;
        }
        return err;
    }

    kernel void encodeBC7(texture2d<float, access::read> src [[texture(0)]],
                          device const uint2 *tiles [[buffer(0)]],
                          device uint4 *out [[buffer(1)]],
                          constant uint &blocksPerRow [[buffer(2)]],
                          constant uint2 &tileBlocks [[buffer(3)]],
                          uint3 gid [[thread_position_in_grid]]) {
        if (gid.x >= tileBlocks.x || gid.y >= tileBlocks.y) return;
        uint2 origin = tiles[gid.z] + gid.xy * 4;
        uint2 size = uint2(src.get_width(), src.get_height());
        if (origin.x >= size.x || origin.y >= size.y) return;

        float3 px[16];
        float3 mean = 0;
        for (uint i = 0; i < 16; i++) {
            uint2 c = min(origin + uint2(i & 3, i >> 2), size - 1);
            px[i] = rint(src.read(c).rgb * 255.0);
            mean += px[i];
        }
        mean /= 16.0;

        // Principal axis of the block's colours, by power iteration on the covariance.
        float3 c0 = 0, c1 = 0, c2 = 0;
        for (uint i = 0; i < 16; i++) {
            float3 d = px[i] - mean;
            c0 += d.x * d; c1 += d.y * d; c2 += d.z * d;
        }
        float3 axis = (c0.x >= c1.y && c0.x >= c2.z) ? c0 : (c1.y >= c2.z ? c1 : c2);
        for (uint k = 0; k < 8; k++) {
            float3 next = float3(dot(c0, axis), dot(c1, axis), dot(c2, axis));
            float len = length(next);
            if (len < 1e-6) break;
            axis = next / len;
        }
        float3 e0 = mean, e1 = mean;
        float len = length(axis);
        if (len > 1e-6) {
            axis /= len;
            float lo = INFINITY, hi = -INFINITY;
            for (uint i = 0; i < 16; i++) {
                float t = dot(px[i] - mean, axis);
                lo = min(lo, t); hi = max(hi, t);
            }
            e0 = mean + axis * lo;
            e1 = mean + axis * hi;
        }

        uint3 q0, q1; uint p0, p1; uint idx[16];
        float err = evaluate(px, e0, e1, q0, q1, p0, p1, idx);

        // Refine the endpoints by least squares for the chosen indices.
        for (uint iter = 0; iter < 2 && err > 0; iter++) {
            float a = 0, b = 0, c = 0;
            float3 x0 = 0, x1 = 0;
            for (uint i = 0; i < 16; i++) {
                float t = kWeights[idx[i]] / 64.0;
                a += (1 - t) * (1 - t); b += (1 - t) * t; c += t * t;
                x0 += (1 - t) * px[i]; x1 += t * px[i];
            }
            float det = a * c - b * b;
            if (fabs(det) < 1e-4) break;
            float3 n0 = (c * x0 - b * x1) / det, n1 = (a * x1 - b * x0) / det;
            uint3 r0, r1; uint s0, s1; uint ridx[16];
            float rerr = evaluate(px, n0, n1, r0, r1, s0, s1, ridx);
            if (rerr >= err) break;
            err = rerr; q0 = r0; q1 = r1; p0 = s0; p1 = s1;
            for (uint i = 0; i < 16; i++) idx[i] = ridx[i];
        }

        // The first index's top bit is implied zero: swap the endpoints if needed.
        if (idx[0] >= 8) {
            uint3 tq = q0; q0 = q1; q1 = tq;
            uint tp = p0; p0 = p1; p1 = tp;
            for (uint i = 0; i < 16; i++) idx[i] = 15 - idx[i];
        }

        uint words[4] = {0, 0, 0, 0};
        uint pos = 0;
        put(words, pos, 1u << 6, 7);
        put(words, pos, q0.x, 7); put(words, pos, q1.x, 7);
        put(words, pos, q0.y, 7); put(words, pos, q1.y, 7);
        put(words, pos, q0.z, 7); put(words, pos, q1.z, 7);
        put(words, pos, 127, 7); put(words, pos, 127, 7);
        put(words, pos, p0, 1); put(words, pos, p1, 1);
        put(words, pos, idx[0], 3);
        for (uint i = 1; i < 16; i++) put(words, pos, idx[i], 4);
        out[(origin.y / 4) * blocksPerRow + origin.x / 4] = uint4(words[0], words[1], words[2], words[3]);
    }
    """
}
