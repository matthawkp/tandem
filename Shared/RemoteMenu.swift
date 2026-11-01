import AppKit

/// A menu sent over the cable: the display Mac's settings, shown in the extending Mac's Tandem
/// menu. Choosing an item there chooses the same item here, so the two never disagree.
struct RemoteMenu: Codable, Equatable {
    struct Item: Codable, Equatable {
        var title = ""
        var on = false
        var enabled = true
        var header = false
        var separator = false
        var toolTip: String?
        var items: [Item]?
    }

    /// An item, by its position in each submenu, and its title to check it's still the same one.
    struct Choice: Codable {
        var path: [Int]
        var title: String
    }

    var items: [Item]

    /// Items marked `RemoteMenu.local` stay out: they only make sense on this Mac.
    init(_ menu: NSMenu) {
        items = Self.items(of: menu)
    }

    static let local = NSUserInterfaceItemIdentifier("local")
    /// Marks section headers, which macOS before 14 can't tell apart from disabled items.
    static let header = NSUserInterfaceItemIdentifier("header")

    private static func items(of menu: NSMenu) -> [Item] {
        menu.items.compactMap { item in
            guard item.identifier != local else { return nil }
            if item.isSeparatorItem { return Item(separator: true) }
            return Item(title: item.title, on: item.state == .on, enabled: item.isEnabled, header: item.identifier == header,
                        toolTip: item.toolTip, items: item.submenu.map { Self.items(of: $0) })
        }
    }

    /// The item a choice names in `menu`, built the same way, skipping local items as above.
    static func item(for choice: Choice, in menu: NSMenu) -> (NSMenu, Int)? {
        var menu = menu
        for (depth, position) in choice.path.enumerated() {
            let shown = menu.items.filter { $0.identifier != local }
            guard position < shown.count, let index = menu.items.firstIndex(of: shown[position]) else { return nil }
            let item = menu.items[index]
            if depth == choice.path.count - 1 { return item.title == choice.title ? (menu, index) : nil }
            guard let submenu = item.submenu else { return nil }
            menu = submenu
        }
        return nil
    }
}
