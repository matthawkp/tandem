import Compression
import Foundation
import Metal
import QuartzCore

/// Applies frame messages to a canvas texture and presents it 1:1 on the panel.
///
/// Lossless rects are decoded on the CPU into `mirror`, a buffer shared with the GPU, then
/// copied into the canvas. BC7 rects are uploaded into a compressed texture and expanded into
/// the canvas by the GPU. The final pass applies the MacBook's colour adaptation (True Tone
/// and Night Shift), so the iMac's picture matches the MacBook's panel.
private let hashEveryFrame = ProcessInfo.processInfo.environment["TANDEM_HASH_ALL"] != nil

final class Renderer {
    let width: Int
    let height: Int
    let layer = CAMetalLayer()
    let supportsBC7: Bool
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let canvas: MTLTexture
    private let bc7Texture: MTLTexture?
    private let mirror: MTLBuffer
    private let staging: MTLBuffer?
    private let expandPipeline: MTLComputePipelineState?
    private let presentPipeline: MTLRenderPipelineState
    private var stride: Int { width * 4 }
    private let queue = DispatchQueue(label: "render", qos: .userInteractive)
    private var lastCommands: MTLCommandBuffer?
    /// Row-major 3×3, linear light. Accessed on `queue`.
    private var colorMatrix = DisplayState.identity

    private struct Rect {
        var x, y, w, h: Int
        var encoding: Wire.Encoding
        var offset: Int
        var count: Int
        var stagingOffset = 0
    }

    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else { return nil }
        self.width = width
        self.height = height
        self.device = device
        self.commandQueue = commandQueue

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        guard let canvas = device.makeTexture(descriptor: desc),
              let mirror = device.makeBuffer(length: width * height * 4, options: .storageModeShared)
        else { return nil }
        self.canvas = canvas
        self.mirror = mirror

        do {
            let library = try device.makeLibrary(source: Renderer.shaders, options: nil)
            let pipeline = MTLRenderPipelineDescriptor()
            pipeline.vertexFunction = library.makeFunction(name: "fullScreen")
            pipeline.fragmentFunction = library.makeFunction(name: "present")
            pipeline.colorAttachments[0].pixelFormat = .bgra8Unorm
            presentPipeline = try device.makeRenderPipelineState(descriptor: pipeline)

            var bc7: MTLTexture?, staging: MTLBuffer?, expand: MTLComputePipelineState?
            if device.supportsBCTextureCompression {
                let bcDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bc7_rgbaUnorm,
                                                                      width: (width + 3) / 4 * 4, height: (height + 3) / 4 * 4, mipmapped: false)
                bcDesc.usage = .shaderRead
                bcDesc.storageMode = .private
                bc7 = device.makeTexture(descriptor: bcDesc)
                staging = device.makeBuffer(length: ((width + 3) / 4) * ((height + 3) / 4) * 16, options: .storageModeShared)
                expand = try device.makeComputePipelineState(function: library.makeFunction(name: "expandBC7")!)
            }
            bc7Texture = bc7
            self.staging = staging
            expandPipeline = expand
        } catch {
            log("shader error: \(error)")
            return nil
        }
        supportsBC7 = bc7Texture != nil && staging != nil && expandPipeline != nil

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: width, height: height)
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.backgroundColor = CGColor.black
        log("renderer \(width)x\(height) on \(device.name), BC7 \(supportsBC7 ? "supported" : "unsupported")")
        clear()
    }

    /// Decodes and presents a frame, then calls `presented` with its number. A frame that makes
    /// no sense is left out whole and `rejected` called instead: the sender's idea of what's on
    /// screen is then wrong, and it waits for an answer to every frame, so the caller should
    /// start the connection again rather than say nothing.
    func apply(_ body: Data, presented: @escaping (UInt32) -> Void, rejected: @escaping () -> Void = {}) {
        queue.async {
            if let problem = self.applyNow(body, presented: presented) {
                log(problem)
                rejected()
            }
        }
    }

    /// The MacBook's True Tone / Night Shift adaptation, applied to everything shown.
    func setColorMatrix(_ matrix: [Float]) {
        queue.async {
            guard matrix.count == 9, matrix.allSatisfy(\.isFinite), matrix != self.colorMatrix else { return }
            self.colorMatrix = matrix
            self.present(nil, {})
        }
    }

    /// Nil, or what was wrong with the frame, in which case none of it was used.
    private func applyNow(_ body: Data, presented: @escaping (UInt32) -> Void) -> String? {
        guard body.count >= 8 else { return "frame of \(body.count) bytes is too short" }
        let frameNo = body.readLE(UInt32.self, at: 0)
        let count = Int(body.readLE(UInt32.self, at: 4))
        // Each rect has a 13-byte header, so there can't be more than fit.
        guard count <= (body.count - 8) / 13 else { return "frame \(frameNo) claims \(count) rects in \(body.count) bytes" }
        var rects: [Rect] = []
        rects.reserveCapacity(count)
        var offset = 8
        var stagingOffset = 0
        for _ in 0..<count {
            guard offset + 13 <= body.count,
                  let encoding = Wire.Encoding(rawValue: body[body.startIndex + offset + 8])
            else { return "bad rect header in frame \(frameNo)" }
            var r = Rect(x: Int(body.readLE(UInt16.self, at: offset)),
                         y: Int(body.readLE(UInt16.self, at: offset + 2)),
                         w: Int(body.readLE(UInt16.self, at: offset + 4)),
                         h: Int(body.readLE(UInt16.self, at: offset + 6)),
                         encoding: encoding,
                         offset: offset + 13,
                         count: Int(body.readLE(UInt32.self, at: offset + 9)))
            guard r.x + r.w <= width, r.y + r.h <= height, r.offset + r.count <= body.count else {
                return "bad rect in frame \(frameNo)"
            }
            if r.encoding == .bc7 || r.encoding == .bc7lz4 {
                guard supportsBC7, let staging, r.x % 4 == 0, r.y % 4 == 0, r.w % 4 == 0, r.h % 4 == 0 else {
                    return "unexpected BC7 rect in frame \(frameNo)"
                }
                // The staging buffer holds one screenful of blocks: rects that overlap, or repeat,
                // mustn't run past its end.
                guard stagingOffset + r.w * r.h <= staging.length else {
                    return "BC7 rects in frame \(frameNo) cover more than the screen"
                }
                r.stagingOffset = stagingOffset
                stagingOffset += r.w * r.h
            }
            rects.append(r)
            offset = r.offset + r.count
        }

        // The GPU may still be reading the shared buffers for the previous frame.
        lastCommands?.waitUntilCompleted()

        body.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            DispatchQueue.concurrentPerform(iterations: rects.count) { i in
                decode(rects[i], from: base + rects[i].offset)
            }
        }
        if debugEnabled && (frameNo % 120 == 0 || hashEveryFrame) {
            log("frame \(frameNo) hash \(String(imageHash(mirror.contents(), width: width, height: height, stride: stride), radix: 16)) (lossless parts only)")
        }
        present(rects) { presented(frameNo) }
        return nil
    }

    private func decode(_ r: Rect, from src: UnsafeRawPointer) {
        switch r.encoding {
        case .raw, .lz4:
            let rowBytes = r.w * 4
            let rawCount = rowBytes * r.h
            let target = mirror.contents()
            func copyRows(_ packed: UnsafeRawPointer) {
                for row in 0..<r.h {
                    memcpy(target + (r.y + row) * stride + r.x * 4, packed + row * rowBytes, rowBytes)
                }
            }
            if r.encoding == .raw {
                guard r.count == rawCount else { return log("raw rect has \(r.count) of \(rawCount) bytes") }
                copyRows(src)
            } else {
                let packed = UnsafeMutablePointer<UInt8>.allocate(capacity: rawCount)
                defer { packed.deallocate() }
                let n = compression_decode_buffer(packed, rawCount, src.assumingMemoryBound(to: UInt8.self), r.count, nil, COMPRESSION_LZ4)
                guard n == rawCount else { return log("lz4 decode failed (\(n) of \(rawCount) bytes)") }
                copyRows(packed)
            }
        case .bc7, .bc7lz4:
            // r.w * r.h pixels at one byte each is exactly the size of their blocks.
            guard let staging else { return }
            let size = r.w * r.h
            let target = (staging.contents() + r.stagingOffset).assumingMemoryBound(to: UInt8.self)
            if r.encoding == .bc7 {
                guard r.count == size else { return log("bc7 rect has \(r.count) of \(size) bytes") }
                memcpy(target, src, size)
            } else {
                let n = compression_decode_buffer(target, size, src.assumingMemoryBound(to: UInt8.self), r.count, nil, COMPRESSION_LZ4)
                guard n == size else { return log("bc7 lz4 decode failed (\(n) of \(size) bytes)") }
            }
        }
    }

    /// A hash of the lossless picture as decoded so far, once everything queued has been applied.
    /// For the tests and TANDEM_DEBUG, to check both ends hold identical pixels.
    func losslessHash() -> UInt64 {
        queue.sync {
            lastCommands?.waitUntilCompleted()
            return imageHash(mirror.contents(), width: width, height: height, stride: stride)
        }
    }

    /// Blanks the screen, e.g. when the sender disconnects.
    func clear() {
        queue.async {
            self.lastCommands?.waitUntilCompleted()
            memset(self.mirror.contents(), 0, self.mirror.length)
            guard let commands = self.commandQueue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = self.canvas
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            commands.commit()
            self.lastCommands = commands
            self.present(nil, {})
        }
    }

    /// Redraws the current contents, e.g. after the window appears.
    func redraw() {
        queue.async { self.present(nil, {}) }
    }

    /// Uploads the given rects (if any) and draws the canvas to the screen.
    private func present(_ rects: [Rect]?, _ done: @escaping () -> Void) {
        guard let commands = commandQueue.makeCommandBuffer() else { return done() }

        if let rects, !rects.isEmpty, let blit = commands.makeBlitCommandEncoder() {
            for r in rects {
                switch r.encoding {
                case .raw, .lz4:
                    blit.copy(from: mirror, sourceOffset: r.y * stride + r.x * 4, sourceBytesPerRow: stride,
                              sourceBytesPerImage: 0, sourceSize: MTLSize(width: r.w, height: r.h, depth: 1),
                              to: canvas, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: r.x, y: r.y, z: 0))
                case .bc7, .bc7lz4:
                    guard let staging, let bc7Texture else { continue }
                    blit.copy(from: staging, sourceOffset: r.stagingOffset, sourceBytesPerRow: r.w / 4 * 16,
                              sourceBytesPerImage: 0, sourceSize: MTLSize(width: r.w, height: r.h, depth: 1),
                              to: bc7Texture, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: r.x, y: r.y, z: 0))
                }
            }
            blit.endEncoding()

            let compressed = rects.filter { $0.encoding == .bc7 || $0.encoding == .bc7lz4 }
            if !compressed.isEmpty, let expandPipeline, let bc7Texture, let compute = commands.makeComputeCommandEncoder() {
                compute.setComputePipelineState(expandPipeline)
                compute.setTexture(bc7Texture, index: 0)
                compute.setTexture(canvas, index: 1)
                let group = MTLSize(width: 16, height: 16, depth: 1)
                for r in compressed {
                    var rect = SIMD4<UInt32>(UInt32(r.x), UInt32(r.y), UInt32(r.w), UInt32(r.h))
                    compute.setBytes(&rect, length: 16, index: 0)
                    compute.dispatchThreadgroups(MTLSize(width: (r.w + 15) / 16, height: (r.h + 15) / 16, depth: 1),
                                                 threadsPerThreadgroup: group)
                }
                compute.endEncoding()
            }
        }

        if let drawable = layer.nextDrawable() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let render = commands.makeRenderCommandEncoder(descriptor: pass) {
                let m = colorMatrix
                var useMatrix: UInt32 = m == DisplayState.identity ? 0 : 1
                // Rows padded to float4.
                var rows = [Float](repeating: 0, count: 12)
                for row in 0..<3 { for col in 0..<3 { rows[row * 4 + col] = m[row * 3 + col] } }
                render.setRenderPipelineState(presentPipeline)
                render.setFragmentTexture(canvas, index: 0)
                render.setFragmentBytes(&rows, length: rows.count * 4, index: 0)
                render.setFragmentBytes(&useMatrix, length: 4, index: 1)
                render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                render.endEncoding()
            }
            commands.present(drawable)
        }
        commands.addCompletedHandler { _ in done() }
        commands.commit()
        lastCommands = commands
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void expandBC7(texture2d<float> bc7 [[texture(0)]],
                          texture2d<float, access::write> canvas [[texture(1)]],
                          constant uint4 &rect [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= rect.z || gid.y >= rect.w) return;
        uint2 p = rect.xy + gid;
        constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
        canvas.write(float4(bc7.sample(s, float2(p) + 0.5).rgb, 1), p);
    }

    struct Vertex { float4 position [[position]]; };

    vertex Vertex fullScreen(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return { float4(uv * 2.0 - 1.0, 0, 1) };
    }

    static float3 toLinear(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    static float3 toGamma(float3 c) {
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    fragment float4 present(Vertex in [[stage_in]],
                            texture2d<float, access::read> canvas [[texture(0)]],
                            constant float4 *rows [[buffer(0)]],
                            constant uint &useMatrix [[buffer(1)]]) {
        uint2 p = uint2(in.position.xy);
        float3 c = canvas.read(p).rgb;
        if (useMatrix) {
            float3 l = toLinear(c);
            l = max(float3(dot(rows[0].xyz, l), dot(rows[1].xyz, l), dot(rows[2].xyz, l)), 0.0);
            c = toGamma(min(l, 1.0));
        }
        return float4(c, 1);
    }
    """
}
