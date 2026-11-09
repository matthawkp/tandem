import Compression
import Foundation

/// Dirty-tile encoder. Keeps a copy of the last frame sent, compares each new frame against it
/// in 128×32 tiles (on the GPU, see TileDiffer), and sends only the changed runs of tiles. Because it diffs against what was
/// actually sent, frames can be dropped freely.
///
/// Tiles go lossless (LZ4) whenever the link can carry them at 60 fps. When it can't, tiles that
/// keep changing (video, scrolling, animation) go as BC7 instead, and are sent again losslessly
/// as soon as they stop changing, so still content is always pixel-perfect.
private let checkDiff = ProcessInfo.processInfo.environment["TANDEM_CHECK_DIFF"] != nil

@available(macOS 14, *)
final class TileEncoder {
    enum Quality: String {
        case automatic, lossless
    }

    struct Frame {
        var base: UnsafeRawPointer
        var stride: Int
        var source: BC7Encoder.Source
    }

    struct Stats {
        var rects = 0
        var rawBytes = 0
        var sentBytes = 0
        var bc7Raw = 0
        var bc7Sent = 0
    }

    let width: Int
    let height: Int
    var quality = Quality.automatic
    /// Measured link speed, which sets how much can go lossless per frame.
    var linkBytesPerSecond = 500e6
    /// How many bytes of picture a second the whole pipeline gets through losslessly: compressing
    /// here, the link, and decompressing and drawing on the receiver. Measured from acks while
    /// frames queue up; nil until then. A fast cable can carry more than an older receiver can
    /// decompress, so the link speed alone would keep full-screen video lossless and stuttering.
    private(set) var pipelineBytesPerSecond: Double?

    /// One measurement of the pipeline: `bytes` of lossless picture acked `seconds` after the
    /// frame before, while the next frame was already waiting.
    func observePipeline(bytes: Int, seconds: Double) {
        guard seconds > 0 else { return }
        let rate = Double(bytes) / seconds
        pipelineBytesPerSecond = pipelineBytesPerSecond.map { $0 * 0.7 + rate * 0.3 } ?? rate
    }

    private let tileWidth = 128
    private let tileHeight = 32
    private let columns: Int
    private let bands: Int
    private let previous: UnsafeMutableRawPointer
    private var previousStride: Int { width * 4 }
    private var needsFullFrame = true
    /// `previous` is the CPU's copy of what was last sent, for comparing frames on the CPU. While
    /// the GPU does the comparing (it keeps a copy of its own) nothing reads it, and keeping it
    /// up would copy every changed tile, 59 MB a frame for full-screen video. So it's left to
    /// go stale then, and if the CPU ever has to take over, it starts with a whole frame.
    /// The debugging switches that read it keep it up regardless.
    private var previousIsStale = false
    private let alwaysKeepsPrevious = debugEnabled || checkDiff
    private let bc7: BC7Encoder?
    private let differ: TileDiffer?

    // Per tile.
    private var lastChanged: [Double]
    private var lossy: [Bool]
    private var lossyCount = 0
    /// Recent lossless compression ratio, to predict what a frame will cost.
    private var ratio = 2.0

    /// A tile counts as moving if it changed again within this long.
    private let motionWindow = 0.15
    /// Lossy tiles are made sharp again once they've been still for this long.
    private let settleTime = 0.2

    /// Whether some tiles are still waiting for their lossless refresh.
    var needsRefresh: Bool { lossyCount > 0 }

    private enum Kind: UInt8 { case none, lossless, bc7 }

    init(width: Int, height: Int, bc7: Bool) {
        self.width = width
        self.height = height
        columns = (width + tileWidth - 1) / tileWidth
        bands = (height + tileHeight - 1) / tileHeight
        previous = .allocate(byteCount: width * height * 4, alignment: 64)
        lastChanged = Array(repeating: -1, count: columns * bands)
        lossy = Array(repeating: false, count: columns * bands)
        self.bc7 = bc7 ? BC7Encoder(width: width, height: height) : nil
        // TANDEM_CPU_DIFF: compare on the CPU, as before, to measure the difference.
        differ = ProcessInfo.processInfo.environment["TANDEM_CPU_DIFF"] != nil
            ? nil : TileDiffer(width: width, height: height, tileWidth: tileWidth, tileHeight: tileHeight)
        if bc7 && self.bc7 == nil { log("BC7 unavailable; sending everything losslessly") }
    }

    deinit { previous.deallocate() }

    func invalidate() { needsFullFrame = true }

    /// Tiles that differ from what was last sent, compared on the CPU.
    private func changedTilesOnCPU(_ frame: Frame) -> [Bool] {
        let base = frame.base, stride = frame.stride
        var dirty = [Bool](repeating: false, count: columns * bands)
        dirty.withUnsafeMutableBufferPointer { dirty in
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let y0 = band * tileHeight, h = min(tileHeight, height - y0)
                for column in 0..<columns {
                    let x0 = column * tileWidth, rowBytes = min(tileWidth, width - x0) * 4
                    for row in 0..<h where memcmp(base + (y0 + row) * stride + x0 * 4,
                                                  previous + (y0 + row) * previousStride + x0 * 4, rowBytes) != 0 {
                        dirty[band * columns + column] = true
                        break
                    }
                }
            }
        }
        return dirty
    }

    /// Which tiles changed, and whether the GPU worked that out: it does for captured frames,
    /// the CPU otherwise.
    private func changedTiles(_ frame: Frame, full: Bool) -> (dirty: [Bool], onGPU: Bool) {
        let everything = [Bool](repeating: true, count: columns * bands)
        // The CPU compares against its own copy, which is no use once it's stale.
        func onCPU() -> [Bool] { full || previousIsStale ? everything : changedTilesOnCPU(frame) }
        guard case .pixelBuffer(let buffer) = frame.source, let differ else {
            differ?.reset()
            return (onCPU(), false)
        }
        // The GPU keeps its own copy of the last frame, so it sees every frame, even full ones.
        guard let gpu = differ.changedTiles(buffer) else { return (onCPU(), false) }
        if checkDiff && !full && !previousIsStale {
            // TANDEM_CHECK_DIFF: the CPU's answer, which must match.
            let cpu = changedTilesOnCPU(frame)
            if cpu != gpu { log("GPU comparison differs from the CPU's in \(zip(cpu, gpu).filter { $0 != $1 }.count) tiles") }
        }
        return (full ? everything : gpu, true)
    }

    /// Returns a frame message body, or nil if nothing needs sending.
    func encode(_ frame: Frame, frameNo: UInt32, now: Double) -> (Data, Stats)? {
        let full = needsFullFrame
        needsFullFrame = false
        let base = frame.base, stride = frame.stride

        // 1. Which tiles changed.
        let (dirty, comparedOnGPU) = changedTiles(frame, full: full)

        // 2. Lossless or BC7 for each changed tile, and which lossy tiles to make sharp again.
        var kinds = [Kind](repeating: .none, count: columns * bands)
        var moving = [Bool](repeating: false, count: columns * bands)
        var dirtyBytes = 0
        for t in 0..<dirty.count where dirty[t] {
            moving[t] = now - lastChanged[t] < motionWindow
            lastChanged[t] = now
            dirtyBytes += tileBytes(t)
            kinds[t] = .lossless
        }
        let budget = linkBytesPerSecond / 60 * 0.8
        // Too much for the link at 60 fps, or more than the receiver has been keeping up with.
        let overLink = Double(dirtyBytes) / ratio > budget
        let overPipeline = pipelineBytesPerSecond.map { Double(dirtyBytes) > $0 / 60 * 0.9 } ?? false
        let useBC7 = bc7 != nil && quality == .automatic && (overLink || overPipeline)
        var losslessBytes = 0
        for t in 0..<dirty.count where dirty[t] {
            if useBC7 && moving[t] && bc7Compatible(t) {
                kinds[t] = .bc7
            } else {
                losslessBytes += tileBytes(t)
            }
        }
        if lossyCount > 0 {
            var room = max(budget * ratio - Double(losslessBytes), budget * ratio * 0.25)
            for t in 0..<dirty.count where lossy[t] && kinds[t] == .none && now - lastChanged[t] >= settleTime {
                guard room > 0 else { break }
                kinds[t] = .lossless
                room -= Double(tileBytes(t))
            }
        }
        let wasLossy = lossyCount
        for t in 0..<kinds.count where kinds[t] != .none {
            let nowLossy = kinds[t] == .bc7
            if nowLossy != lossy[t] { lossyCount += nowLossy ? 1 : -1 }
            lossy[t] = nowLossy
        }

        // 3. Remember what's being sent, unless the GPU is doing the remembering.
        if comparedOnGPU && !alwaysKeepsPrevious {
            previousIsStale = true
        } else {
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let y0 = band * tileHeight, h = min(tileHeight, height - y0)
                for column in 0..<columns where dirty[band * columns + column] {
                    let x0 = column * tileWidth, rowBytes = min(tileWidth, width - x0) * 4
                    for row in 0..<h {
                        memcpy(previous + (y0 + row) * previousStride + x0 * 4, base + (y0 + row) * stride + x0 * 4, rowBytes)
                    }
                }
            }
            // Stale until now, every tile was counted as changed, so every tile was just copied.
            previousIsStale = false
        }

        // 4. Encode: BC7 tiles on the GPU while the CPU compresses the lossless ones.
        var bc7Tiles: [(x: Int, y: Int)] = []
        for t in 0..<kinds.count where kinds[t] == .bc7 {
            bc7Tiles.append(((t % columns) * tileWidth, (t / columns) * tileHeight))
        }
        var blocks: UnsafeRawPointer?
        let gpu = DispatchGroup()
        if let bc7, !bc7Tiles.isEmpty {
            DispatchQueue.global(qos: .userInteractive).async(group: gpu) {
                blocks = bc7.encode(tiles: bc7Tiles, tileWidth: self.tileWidth, tileHeight: self.tileHeight, from: frame.source)
            }
        }

        var results = [[Data]](repeating: [], count: bands)
        var stats = [Stats](repeating: Stats(), count: bands)
        results.withUnsafeMutableBufferPointer { results in
            stats.withUnsafeMutableBufferPointer { stats in
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    forEachRun(in: band, kinds: kinds, of: .lossless) { x0, w, y0, h in
                        let rect = encodeLossless(base, stride: stride, x: x0, y: y0, w: w, h: h)
                        stats[band].rects += 1
                        stats[band].rawBytes += w * h * 4
                        stats[band].sentBytes += rect.count
                        results[band].append(rect)
                    }
                }
                gpu.wait()
                guard let blocks else { return }
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    forEachRun(in: band, kinds: kinds, of: .bc7) { x0, w, y0, h in
                        let rect = encodeBC7(blocks, x: x0, y: y0, w: w, h: h)
                        stats[band].rects += 1
                        stats[band].rawBytes += w * h * 4
                        stats[band].sentBytes += rect.count
                        stats[band].bc7Raw += w * h * 4
                        stats[band].bc7Sent += rect.count
                        results[band].append(rect)
                    }
                }
            }
        }
        if !bc7Tiles.isEmpty && blocks == nil {
            // The GPU failed; send those tiles losslessly next time.
            for t in 0..<kinds.count where kinds[t] == .bc7 { lossy[t] = false; lossyCount -= 1 }
            needsFullFrame = true
        }

        let total = stats.reduce(into: Stats()) {
            $0.rects += $1.rects
            $0.rawBytes += $1.rawBytes
            $0.sentBytes += $1.sentBytes
            $0.bc7Raw += $1.bc7Raw
            $0.bc7Sent += $1.bc7Sent
        }
        guard total.rects > 0 else { return nil }
        let losslessSent = total.sentBytes - total.bc7Sent
        let losslessRaw = total.rawBytes - total.bc7Raw
        if losslessRaw > 1_000_000 && losslessSent > 0 {
            ratio = ratio * 0.7 + Double(losslessRaw) / Double(losslessSent) * 0.3
        }

        var body = Data(capacity: total.sentBytes + 8)
        body.appendLE(frameNo)
        body.appendLE(UInt32(total.rects))
        for band in results { for rect in band { body.append(rect) } }

        if debugEnabled && wasLossy > 0 && lossyCount == 0 {
            log("frame \(frameNo): all sharp again, hash \(String(imageHash(previous, width: width, height: height, stride: previousStride), radix: 16))")
        }
        if debugEnabled && frameNo % 120 == 0 {
            log("frame \(frameNo) hash \(String(imageHash(previous, width: width, height: height, stride: previousStride), radix: 16))\(lossyCount > 0 ? " (\(lossyCount) tiles not yet sharp)" : "")")
        }
        return (body, total)
    }

    private func tileBytes(_ t: Int) -> Int {
        let x0 = (t % columns) * tileWidth, y0 = (t / columns) * tileHeight
        return min(tileWidth, width - x0) * min(tileHeight, height - y0) * 4
    }

    private func bc7Compatible(_ t: Int) -> Bool {
        let x0 = (t % columns) * tileWidth, y0 = (t / columns) * tileHeight
        return min(tileWidth, width - x0) % 4 == 0 && min(tileHeight, height - y0) % 4 == 0
    }

    /// Calls `body` for each run of adjacent tiles of one kind in a band, as a pixel rect.
    private func forEachRun(in band: Int, kinds: [Kind], of kind: Kind, _ body: (Int, Int, Int, Int) -> Void) {
        let y0 = band * tileHeight, h = min(tileHeight, height - y0)
        var column = 0
        while column < columns {
            guard kinds[band * columns + column] == kind else { column += 1; continue }
            var end = column
            while end + 1 < columns && kinds[band * columns + end + 1] == kind { end += 1 }
            let x0 = column * tileWidth
            body(x0, min((end + 1) * tileWidth, width) - x0, y0, h)
            column = end + 1
        }
    }

    private func encodeLossless(_ base: UnsafeRawPointer, stride: Int, x: Int, y: Int, w: Int, h: Int) -> Data {
        let rowBytes = w * 4
        let packed = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * h, alignment: 64)
        defer { packed.deallocate() }
        for row in 0..<h {
            memcpy(packed + row * rowBytes, base + (y + row) * stride + x * 4, rowBytes)
        }
        return rect(x: x, y: y, w: w, h: h, packed, count: rowBytes * h, plain: .raw, compressed: .lz4)
    }

    private func encodeBC7(_ blocks: UnsafeRawPointer, x: Int, y: Int, w: Int, h: Int) -> Data {
        let rowBytes = w / 4 * BC7Encoder.blockBytes
        let blockRows = h / 4
        let packed = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * blockRows, alignment: 64)
        defer { packed.deallocate() }
        let blocksPerRow = (width + 3) / 4
        for row in 0..<blockRows {
            memcpy(packed + row * rowBytes, blocks + ((y / 4 + row) * blocksPerRow + x / 4) * BC7Encoder.blockBytes, rowBytes)
        }
        return rect(x: x, y: y, w: w, h: h, packed, count: rowBytes * blockRows, plain: .bc7, compressed: .bc7lz4)
    }

    /// Rect header plus payload, LZ4-compressed when that's smaller.
    private func rect(x: Int, y: Int, w: Int, h: Int, _ packed: UnsafeRawPointer, count: Int,
                      plain: Wire.Encoding, compressed: Wire.Encoding) -> Data {
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { out.deallocate() }
        let n = compression_encode_buffer(out, count, packed.assumingMemoryBound(to: UInt8.self), count, nil, COMPRESSION_LZ4)
        let useLZ4 = n > 0 && n < count

        var data = Data(capacity: 13 + (useLZ4 ? n : count))
        data.appendLE(UInt16(x))
        data.appendLE(UInt16(y))
        data.appendLE(UInt16(w))
        data.appendLE(UInt16(h))
        data.append(useLZ4 ? compressed.rawValue : plain.rawValue)
        data.appendLE(UInt32(useLZ4 ? n : count))
        if useLZ4 {
            data.append(out, count: n)
        } else {
            data.append(packed.assumingMemoryBound(to: UInt8.self), count: count)
        }
        return data
    }
}
