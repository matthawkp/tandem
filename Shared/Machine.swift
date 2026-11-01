import CoreGraphics
import Foundation
import IOKit

/// This Mac, as people would describe it: "MacBook Pro", "iMac", "Mac mini". Tandem's wording
/// uses it, as in "Sleep iMac with MacBook Pro".
enum Machine {
    static let kind: String = {
        // Apple silicon Macs name themselves, e.g. "MacBook Pro (14-inch, M5 Pro)".
        let product = IORegistryEntryFromPath(mach_port_t(MACH_PORT_NULL), "IODeviceTree:/product")
        defer { if product != 0 { IOObjectRelease(product) } }
        if product != 0,
           let data = IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?
               .takeRetainedValue() as? Data {
            let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            let family = name.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !family.isEmpty { return family }
        }
        // Intel Macs only have a model identifier, e.g. "iMac19,1".
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let identifier = String(cString: model)
        let families = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
                        ("iMacPro", "iMac Pro"), ("iMac", "iMac"), ("Macmini", "Mac mini"), ("MacPro", "Mac Pro")]
        return families.first { identifier.hasPrefix($0.0) }?.1 ?? "Mac"
    }()

    /// The name from Sharing settings, e.g. "Alex's iMac".
    static var name: String { Host.current().localizedName ?? kind }

    static var isLaptop: Bool { kind.hasPrefix("MacBook") }

    static var hasBuiltInDisplay: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// The other Mac on the cable, as it describes itself.
struct Peer: Equatable {
    var name: String
    var kind: String

    /// u16 name byte count, name, kind (both UTF-8).
    func encoded() -> Data {
        let nameBytes = Data(name.utf8)
        var d = Data()
        d.appendLE(UInt16(nameBytes.count))
        d.append(nameBytes)
        d.append(Data(kind.utf8))
        return d
    }

    init(name: String, kind: String) {
        self.name = name
        self.kind = kind
    }

    init?(_ d: Data) {
        guard d.count >= 2 else { return nil }
        let length = Int(d.readLE(UInt16.self, at: 0))
        guard d.count >= 2 + length else { return nil }
        let bytes = Data(d)
        name = String(decoding: bytes[2..<(2 + length)], as: UTF8.self)
        kind = String(decoding: bytes[(2 + length)...], as: UTF8.self)
    }

    static let this = Peer(name: Machine.name, kind: Machine.kind)

    /// The last Mac seen on the other end, so wording is right before it connects again.
    static var last: Peer? {
        get {
            guard let name = UserDefaults.standard.string(forKey: "lastPeerName"),
                  let kind = UserDefaults.standard.string(forKey: "lastPeerKind") else { return nil }
            return Peer(name: name, kind: kind)
        }
        set {
            UserDefaults.standard.set(newValue?.name, forKey: "lastPeerName")
            UserDefaults.standard.set(newValue?.kind, forKey: "lastPeerKind")
        }
    }
}
