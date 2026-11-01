import AppKit

/// Files pulled back through the bubble, from the display Mac to the extending Mac. Each item is
/// zipped with ditto (so folders, permissions and metadata come too), sent in chunks a megabyte at
/// a time, one after the other so the picture keeps flowing, and unzipped into Downloads.
///
/// Messages are `file`: a phase byte, then for `start` a UInt64 size, where it was let go (two
/// Float32s, fractions of the picture from the top left) and the item's name.
enum FileTransfer {
    enum Phase: UInt8 {
        case start = 0
        case data = 1
        case end = 2
        case failed = 3
    }

    static let chunkSize = 1 << 20

    static func ditto(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// The display Mac's end: queues dropped items and sends them one by one.
final class FileSender {

    /// An item has gone, or couldn't be sent: its name and whether it went. On the main queue.
    var onSent: (String, Bool) -> Void = { _, _ in }

    private let queue = DispatchQueue(label: "files", qos: .utility)
    private struct Item {
        var url: URL
        var point: CGPoint
        /// The link it was dropped for: if that goes, so does the item.
        weak var channel: MessageChannel?
    }
    private var pending: [Item] = []
    private var channel: MessageChannel?
    private var busy = false

    func send(_ urls: [URL], at point: CGPoint, over channel: MessageChannel) {
        queue.async {
            self.pending += urls.map { Item(url: $0, point: point, channel: channel) }
            self.next()
        }
    }

    /// One `file` message, reporting whether it went.
    private func send(_ body: Data, done: @escaping (Bool) -> Void) {
        guard let channel else { return done(false) }
        channel.send(.file, body, sent: done)
    }

    private func next() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let item = pending.removeFirst()
        let url = item.url, point = item.point
        channel = item.channel
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Tandem-\(UUID().uuidString)")
        let copy = work.appendingPathComponent(url.lastPathComponent)
        let zip = work.appendingPathComponent("item.zip")
        let finish = { (sent: Bool) in
            try? FileManager.default.removeItem(at: work)
            DispatchQueue.main.async { self.onSent(url.lastPathComponent, sent) }
            self.busy = false
            self.next()
        }
        // Copied first by this app, which the drop lets read the item; ditto then works on the copy.
        // On the same APFS volume the copy is a clone, so it's instant whatever the size.
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            log("files: couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
            return finish(false)
        }
        guard FileTransfer.ditto(["-c", "-k", "--keepParent", "--zlibCompressionLevel", "0", copy.path, zip.path]),
              let handle = try? FileHandle(forReadingFrom: zip),
              let size = (try? FileManager.default.attributesOfItem(atPath: zip.path))?[.size] as? UInt64
        else {
            log("files: couldn't pack \(url.lastPathComponent)")
            return finish(false)
        }
        log("files: sending \(url.lastPathComponent), \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        var start = Data([FileTransfer.Phase.start.rawValue])
        start.appendLE(size)
        start.appendLE(Float(point.x).bitPattern)
        start.appendLE(Float(point.y).bitPattern)
        start.append(Data(url.lastPathComponent.utf8))
        send(start) { _ in }
        sendChunks(from: handle) { ok in
            try? handle.close()
            self.send(Data([(ok ? FileTransfer.Phase.end : .failed).rawValue])) { _ in }
            if !ok { log("files: \(url.lastPathComponent) couldn't be sent") }
            finish(ok)
        }
    }

    /// The next chunk goes once the last has been handed to the network, so frames fit in between.
    private func sendChunks(from handle: FileHandle, done: @escaping (Bool) -> Void) {
        queue.async {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: FileTransfer.chunkSize)
            } catch {
                return done(false)
            }
            // Nil, or nothing, at the end of the file.
            guard let chunk, !chunk.isEmpty else { return done(true) }
            self.send(Data([FileTransfer.Phase.data.rawValue]) + chunk) { sent in
                guard sent else { return done(false) }
                self.sendChunks(from: handle, done: done)
            }
        }
    }
}

/// The extending Mac's end: writes what arrives, then unzips it into the folder it was let go
/// over, or else into Downloads, and shows it there.
final class FileReceiver {
    /// The folder at a point on this Mac's screens, if there's one. On the files queue, as finding
    /// out can be slow.
    var folder: (CGPoint) -> URL? = { _ in nil }
    /// An item has been saved, with where it was let go on this Mac's screens. On the files queue.
    var onSaved: (URL, CGPoint) -> Void = { _, _ in }
    private let queue = DispatchQueue(label: "files", qos: .utility)
    /// The display the picture shows, which the drop point is a fraction of.
    private var display: CGDirectDisplayID?
    private var destination: URL?
    private var droppedAt: CGPoint?
    private var name = ""
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var work: URL?
    private var handle: FileHandle?

    func setDisplay(_ display: CGDirectDisplayID?) {
        queue.async { self.display = display }
    }

    func receive(_ body: Data) {
        guard let phase = body.first.flatMap(FileTransfer.Phase.init) else { return }
        let rest = body.dropFirst()
        queue.async {
            switch phase {
            case .start:
                self.reset()
                guard rest.count >= 16 else { return }
                self.expected = rest.readLE(UInt64.self, at: 0)
                self.received = 0
                let x = CGFloat(Float(bitPattern: rest.readLE(UInt32.self, at: 8)))
                let y = CGFloat(Float(bitPattern: rest.readLE(UInt32.self, at: 12)))
                self.name = String(decoding: rest.dropFirst(16), as: UTF8.self)
                if let display = self.display {
                    let bounds = CGDisplayBounds(display)
                    self.droppedAt = CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
                }
                // Where it's going is decided now, while the windows are where they were.
                self.destination = self.droppedAt.flatMap(self.folder)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("Tandem-\(UUID().uuidString)")
                let zip = work.appendingPathComponent("item.zip")
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: zip.path, contents: nil)
                self.work = work
                self.handle = try? FileHandle(forWritingTo: zip)
            case .data:
                try? self.handle?.write(contentsOf: rest)
                self.received += UInt64(rest.count)
            case .end:
                self.unpack()
            case .failed:
                log("files: \(self.name) didn't arrive")
                self.reset()
            }
        }
    }

    private func unpack() {
        defer { reset() }
        guard let work, let handle else { return }
        try? handle.close()
        self.handle = nil
        guard received == expected else {
            log("files: \(name) arrived incomplete, \(received) of \(expected) bytes")
            return
        }
        let out = work.appendingPathComponent("out")
        guard FileTransfer.ditto(["-x", "-k", work.appendingPathComponent("item.zip").path, out.path]),
              let item = try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else {
            log("files: couldn't unpack \(name)")
            return
        }
        // Where it was let go, or Downloads if that wasn't a folder or can't be written to.
        for folder in [destination, downloads].compactMap({ $0 }) {
            let saved = Self.unused(folder.appendingPathComponent(item.lastPathComponent))
            do {
                try FileManager.default.moveItem(at: item, to: saved)
            } catch {
                log("files: couldn't save \(name) to \(folder.path): \(error.localizedDescription)")
                continue
            }
            log("files: \(saved.lastPathComponent) saved to \(folder.path)")
            if let droppedAt { onSaved(saved, droppedAt) }
            // Let go over a folder, it's already in view; otherwise show where it went.
            if folder == downloads { DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([saved]) } }
            return
        }
    }

    private func reset() {
        destination = nil
        droppedAt = nil
        try? handle?.close()
        handle = nil
        if let work { try? FileManager.default.removeItem(at: work) }
        work = nil
    }

    /// "Name.ext", or "Name 2.ext" and so on if that's taken, as the Finder would.
    private static func unused(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for n in 2... {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
