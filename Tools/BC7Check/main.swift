// Checks the BC7 encoder on an image: decodes with the GPU's own BC7 decoder and reports
// PSNR and timing. Run with Tools/bc7check.sh <image>.
import AppKit
import Metal

func log(_ s: String) { print(s) }

let args = CommandLine.arguments
guard args.count > 1, let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: bc7check <image> [out.png]"); exit(1)
}
let width = cg.width / 128 * 128, height = cg.height / 32 * 32
let stride = width * 4
let pixels = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
let ctx = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

let encoder = BC7Encoder(width: width, height: height)!
var tiles: [(x: Int, y: Int)] = []
for y in Swift.stride(from: 0, to: height, by: 32) { for x in Swift.stride(from: 0, to: width, by: 128) { tiles.append((x, y)) } }
_ = encoder.encode(tiles: tiles, tileWidth: 128, tileHeight: 32, from: .memory(pixels, stride: stride))
let start = Date()
let runs = 10
var blocks: UnsafeRawPointer!
for _ in 0..<runs { blocks = encoder.encode(tiles: tiles, tileWidth: 128, tileHeight: 32, from: .memory(pixels, stride: stride)) }
let ms = Date().timeIntervalSince(start) * 1000 / Double(runs)
print(String(format: "%dx%d, %d tiles: %.1f ms per full frame (incl. upload)", width, height, tiles.count, ms))

// Decode with the GPU.
let device = MTLCreateSystemDefaultDevice()!
let bcDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bc7_rgbaUnorm, width: width, height: height, mipmapped: false)
let bc = device.makeTexture(descriptor: bcDesc)!
bc.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: blocks, bytesPerRow: width / 4 * 16)
let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
outDesc.usage = [.shaderWrite, .shaderRead]
let decoded = device.makeTexture(descriptor: outDesc)!
let lib = try! device.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
kernel void copy(texture2d<float> bc [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= o.get_width() || g.y >= o.get_height()) return;
    constexpr sampler s(coord::pixel, filter::nearest);
    o.write(float4(bc.sample(s, float2(g) + 0.5).rgb, 1), g);
}
""", options: nil)
let pso = try! device.makeComputePipelineState(function: lib.makeFunction(name: "copy")!)
let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, ce = cb.makeComputeCommandEncoder()!
ce.setComputePipelineState(pso); ce.setTexture(bc, index: 0); ce.setTexture(decoded, index: 1)
ce.dispatchThreadgroups(MTLSize(width: width / 16, height: height / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
ce.endEncoding(); cb.commit(); cb.waitUntilCompleted()
let out = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
decoded.getBytes(out, bytesPerRow: stride, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

var se = 0.0, maxErr = 0
let a = pixels.assumingMemoryBound(to: UInt8.self), b = out.assumingMemoryBound(to: UInt8.self)
for i in 0..<(width * height) { for c in 0..<3 { let d = Int(a[i * 4 + c]) - Int(b[i * 4 + c]); se += Double(d * d); maxErr = max(maxErr, abs(d)) } }
let mse = se / Double(width * height * 3)
print(String(format: "PSNR %.2f dB, max channel error %d", 10 * log10(255 * 255 / max(mse, 1e-9)), maxErr))

if args.count > 2 {
    let octx = CGContext(data: out, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                         space: CGColorSpace(name: CGColorSpace.displayP3)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let rep = NSBitmapImageRep(cgImage: octx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
}
