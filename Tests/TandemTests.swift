import AppKit
import XCTest

/// The parts of Tandem that can be checked on one Mac: what goes over the cable, and a picture
/// going through the encoder and out of the renderer unchanged.
final class WireTests: XCTestCase {
    func testHelloSurvivesTheTrip() throws {
        var hello = Hello(width: 5120, height: 2880, mmWide: 599, mmHigh: 340, capabilities: [.bc7, .cursor], brightness: 0.5, name: "Alex’s iMac")
        hello.kind = "iMac"
        let back = try XCTUnwrap(Hello(hello.encoded()))
        XCTAssertEqual(back.width, 5120)
        XCTAssertEqual(back.height, 2880)
        XCTAssertEqual(back.capabilities, [.bc7, .cursor])
        XCTAssertEqual(back.brightness, 0.5)
        XCTAssertEqual(back.name, "Alex’s iMac")
        XCTAssertEqual(back.kind, "iMac")
        XCTAssertEqual(back.version, Wire.version)
    }

    func testHelloWithAnImpossibleSizeIsRefused() {
        for (width, height) in [(0, 2880), (5120, 0), (Wire.maxDimension + 1, 2880), (Int(UInt32.max), Int(UInt32.max))] {
            var d = Hello(width: 1, height: 1, mmWide: 1, mmHigh: 1, name: "x").encoded()
            var w = UInt32(width).littleEndian, h = UInt32(height).littleEndian
            d.replaceSubrange(0..<4, with: Data(bytes: &w, count: 4))
            d.replaceSubrange(4..<8, with: Data(bytes: &h, count: 4))
            XCTAssertNil(Hello(d), "\(width)x\(height)")
        }
        XCTAssertNil(Hello(Data(count: 10)))
    }

    func testInputEventSurvivesTheTrip() throws {
        let event = InputEvent(type: 10, flags: 0x100, fields: [9: 36, 8: 1])
        let back = try XCTUnwrap(InputEvent(event.encoded()))
        XCTAssertEqual(back.type, 10)
        XCTAssertEqual(back.flags, 0x100)
        XCTAssertEqual(back.fields, [9: 36, 8: 1])
        XCTAssertNil(InputEvent(Data(count: 13)))
    }

    func testNumbersThatDontFitAreRefusedNotTrapped() {
        let event = InputEvent(type: 10, fields: [1: .nan, 2: .infinity, 3: 70000, 4: -1, 5: 36.9, 6: -36.9])
        XCTAssertNil(event.integer(1, as: UInt16.self))
        XCTAssertNil(event.integer(2, as: Int64.self))
        XCTAssertNil(event.integer(3, as: UInt16.self))
        XCTAssertEqual(event.integer(3, as: UInt32.self), 70000)
        XCTAssertNil(event.integer(4, as: UInt32.self))
        XCTAssertEqual(event.integer(4, as: Int64.self), -1)
        XCTAssertEqual(event.integer(5, as: UInt16.self), 36)
        XCTAssertEqual(event.integer(6, as: Int16.self), -36)
        // A field that wasn't sent reads as nought.
        XCTAssertEqual(event.integer(99, as: UInt16.self), 0)
    }

    func testPointerAndDisplayMessagesSurviveTheTrip() throws {
        let position = CursorPosition(x: -4, y: 2879, visible: true)
        XCTAssertEqual(CursorPosition(position.encoded()), position)
        let shape = CursorShape(width: 3, height: 2, hotX: 1, hotY: 1, pixels: Data((0..<24).map { UInt8($0) }))
        let back = try XCTUnwrap(CursorShape(shape.encoded()))
        XCTAssertEqual(back.pixels, shape.pixels)
        XCTAssertEqual([back.width, back.height, back.hotX, back.hotY], [3, 2, 1, 1])
        XCTAssertNil(CursorShape(shape.encoded().dropLast()))
        let display = DisplayState(brightness: 0.25, colorMatrix: [1, 0, 0, 0, 0.9, 0, 0, 0, 0.8])
        XCTAssertEqual(DisplayState(display.encoded()), display)
        let peer = Peer(name: "Alex’s MacBook Pro", kind: "MacBook Pro")
        XCTAssertEqual(Peer(peer.encoded()), peer)
    }

    func testCameraFrameWithAnImpossibleSizeIsRefused() throws {
        let pool = try XCTUnwrap(makeBGRAPool(width: 4, height: 2))
        var good = Data()
        good.appendLE(UInt32(4)); good.appendLE(UInt32(2)); good.append(Data(count: 32))
        XCTAssertNotNil(pixelBuffer(fromCameraFrame: good, pool: pool))
        var huge = Data()
        huge.appendLE(UInt32.max); huge.appendLE(UInt32.max); huge.append(Data(count: 32))
        XCTAssertNil(pixelBuffer(fromCameraFrame: huge, pool: pool))
        var wrong = Data()
        wrong.appendLE(UInt32(8)); wrong.appendLE(UInt32(1)); wrong.append(Data(count: 32))
        XCTAssertNil(pixelBuffer(fromCameraFrame: wrong, pool: pool))
    }
}

final class RemoteMenuTests: XCTestCase {
    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: ""))
        let local = NSMenuItem(title: "Permissions…", action: nil, keyEquivalent: "")
        local.identifier = RemoteMenu.local
        menu.addItem(local)
        let sleep = NSMenuItem(title: "Sleep", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(NSMenuItem(title: "After 1 Minute", action: nil, keyEquivalent: ""))
        sub.addItem(NSMenuItem(title: "Never", action: nil, keyEquivalent: ""))
        sleep.submenu = sub
        menu.addItem(sleep)
        return menu
    }

    func testLocalItemsStayHome() {
        let remote = RemoteMenu(menu())
        XCTAssertEqual(remote.items.map(\.title), ["Open at Login", "Sleep"])
        XCTAssertEqual(remote.items[1].items?.map(\.title), ["After 1 Minute", "Never"])
    }

    func testAChoiceFindsItsItemPastLocalOnes() throws {
        let menu = menu()
        let (found, index) = try XCTUnwrap(RemoteMenu.item(for: .init(path: [1, 1], title: "Never"), in: menu))
        XCTAssertEqual(found.items[index].title, "Never")
        // The menu changed since it was sent: not some other item in the same place.
        XCTAssertNil(RemoteMenu.item(for: .init(path: [1, 1], title: "After 5 Minutes"), in: menu))
        XCTAssertNil(RemoteMenu.item(for: .init(path: [7], title: "Never"), in: menu))
        XCTAssertNil(RemoteMenu.item(for: .init(path: [], title: "Never"), in: menu))
    }
}

@available(macOS 14, *)
final class VirtualScreenTests: XCTestCase {
    func testA5KiMacIsRetinaWithItsUsualSizes() {
        let hello = Hello(width: 5120, height: 2880, mmWide: 599, mmHigh: 340, name: "iMac")
        XCTAssertTrue(VirtualScreen.isRetina(hello))
        let modes = VirtualScreen.modes(nativeWidth: 5120, nativeHeight: 2880, retina: true)
        XCTAssertEqual(modes.first?.0, 2560)
        XCTAssertEqual(modes.first?.1, 1440)
        XCTAssertEqual(Set(modes.map(\.0)).count, modes.count)
        for (w, h) in modes { XCTAssertEqual(Double(w) / Double(h), 16.0 / 9, accuracy: 0.01) }
    }

    func testAnOrdinaryMonitorIsnt() {
        XCTAssertFalse(VirtualScreen.isRetina(Hello(width: 1920, height: 1080, mmWide: 527, mmHigh: 296, name: "Monitor")))
        XCTAssertEqual(VirtualScreen.modes(nativeWidth: 1920, nativeHeight: 1080, retina: false).first?.0, 1920)
    }
}

/// A picture through the encoder and the renderer, as it goes from one Mac to the other.
@available(macOS 14, *)
final class PictureTests: XCTestCase {
    private let width = 512, height = 256
    private var pixels: UnsafeMutableRawPointer!

    override func setUp() {
        pixels = .allocate(byteCount: width * height * 4, alignment: 64)
        let p = pixels.assumingMemoryBound(to: UInt32.self)
        for i in 0..<(width * height) { p[i] = 0xFF00_0000 | UInt32(truncatingIfNeeded: i &* 2_654_435_761) >> 8 }
    }

    override func tearDown() {
        pixels.deallocate()
    }

    private func frame() -> TileEncoder.Frame {
        TileEncoder.Frame(base: pixels, stride: width * 4, source: .memory(pixels, stride: width * 4))
    }

    private var sourceHash: UInt64 { imageHash(pixels, width: width, height: height, stride: width * 4) }

    /// Applies a frame and waits for the renderer's answer: true if it was shown.
    private func apply(_ body: Data, to renderer: Renderer) -> Bool {
        let done = expectation(description: "frame answered")
        var shown = false
        renderer.apply(body, presented: { _ in shown = true; done.fulfill() }, rejected: { done.fulfill() })
        wait(for: [done], timeout: 10)
        return shown
    }

    func testStillAndChangedFramesArrivePixelForPixel() throws {
        let encoder = TileEncoder(width: width, height: height, bc7: false)
        let renderer = try XCTUnwrap(Renderer(width: width, height: height))
        let (first, stats) = try XCTUnwrap(encoder.encode(frame(), frameNo: 1, now: 0))
        XCTAssertEqual(stats.rawBytes, width * height * 4)
        XCTAssertTrue(apply(first, to: renderer))
        XCTAssertEqual(renderer.losslessHash(), sourceHash)

        // Nothing changed: nothing to send.
        XCTAssertNil(encoder.encode(frame(), frameNo: 2, now: 1))

        // One pixel changed: one tile goes, and both ends still agree.
        pixels.assumingMemoryBound(to: UInt32.self)[width * 100 + 300] = 0xFFFF_FFFF
        let (second, changed) = try XCTUnwrap(encoder.encode(frame(), frameNo: 2, now: 2))
        XCTAssertEqual(changed.rawBytes, 128 * 32 * 4)
        XCTAssertTrue(apply(second, to: renderer))
        XCTAssertEqual(renderer.losslessHash(), sourceHash)
    }

    func testFramesThatMakeNoSenseAreRejectedWhole() throws {
        let encoder = TileEncoder(width: width, height: height, bc7: false)
        let renderer = try XCTUnwrap(Renderer(width: width, height: height))
        let (good, _) = try XCTUnwrap(encoder.encode(frame(), frameNo: 1, now: 0))
        XCTAssertTrue(apply(good, to: renderer))
        let before = renderer.losslessHash()

        XCTAssertFalse(apply(Data(count: 4), to: renderer), "too short")
        XCTAssertFalse(apply(Data(good.prefix(good.count - 5)), to: renderer), "cut off")
        var manyRects = Data()
        manyRects.appendLE(UInt32(9)); manyRects.appendLE(UInt32.max)
        XCTAssertFalse(apply(manyRects, to: renderer), "more rects than bytes")
        var outside = Data()
        outside.appendLE(UInt32(9)); outside.appendLE(UInt32(1))
        for v in [500, 0, 128, 32] { outside.appendLE(UInt16(v)) }
        outside.append(Wire.Encoding.raw.rawValue); outside.appendLE(UInt32(128 * 32 * 4)); outside.append(Data(count: 128 * 32 * 4))
        XCTAssertFalse(apply(outside, to: renderer), "past the right edge")
        XCTAssertEqual(renderer.losslessHash(), before, "a rejected frame changes nothing")
    }

    func testCompressedRectsCantOverrunTheirBuffer() throws {
        let renderer = try XCTUnwrap(Renderer(width: width, height: height))
        try XCTSkipUnless(renderer.supportsBC7, "this Mac's GPU doesn't decode BC7")
        // The whole screen, compressed, three times over in one frame.
        var body = Data()
        body.appendLE(UInt32(1)); body.appendLE(UInt32(3))
        for _ in 0..<3 {
            for v in [0, 0, width, height] { body.appendLE(UInt16(v)) }
            body.append(Wire.Encoding.bc7.rawValue); body.appendLE(UInt32(width * height)); body.append(Data(count: width * height))
        }
        XCTAssertFalse(apply(body, to: renderer))
        // Once is fine.
        var once = Data()
        once.appendLE(UInt32(2)); once.appendLE(UInt32(1))
        for v in [0, 0, width, height] { once.appendLE(UInt16(v)) }
        once.append(Wire.Encoding.bc7.rawValue); once.appendLE(UInt32(width * height)); once.append(Data(count: width * height))
        XCTAssertTrue(apply(once, to: renderer))
    }
}
