import AppKit

/// Menu bar app. The virtual display is a normal monitor as far as macOS is concerned, so it's
/// arranged in System Settings → Displays; the menu offers the common settings directly.
@available(macOS 14, *)
final class SenderApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = SenderController(options: SenderOptions(arguments: CommandLine.arguments))
    private var statusItem: NSStatusItem!
    private var welcome: WelcomeWindow?
    private lazy var permissionsWindow = PermissionsWindow(role: .extend)
    private let brightnessKeys = BrightnessKeys()
    private let camera = CameraExtension()
    private let switcher = CameraSwitcher()
    private lazy var cameraPreview = CameraPreview(switcher: switcher)

    // While the menu is open it's updated in place rather than rebuilt, so the slider keeps working.
    private var menuIsOpen = false
    private var titleItem: NSMenuItem?
    private var detailItem: NSMenuItem?
    private var statsItem: NSMenuItem?
    private var brightnessSlider: NSSlider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Tandem")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        controller.onChange = { [weak self] in self?.refresh() }
        controller.updateInputTuning()
        controller.start()
        refresh()
        brightnessKeys.targetDisplay = { [weak self] in self?.controller.screen?.displayID }
        brightnessKeys.onPress = { [weak self] direction, fine in self?.controller.stepReceiverBrightness(direction, fine: fine) }
        setUpBrightnessKeys()
        camera.onChange = { [weak self] in self?.refresh() }
        if controller.prefs.offersCamera { camera.install() }
        switcher.start(mode: controller.prefs.cameraMode, pace: controller.prefs.cameraPace,
                       matchesColour: controller.prefs.cameraMatchesColour)

        let prefs = controller.prefs
        if !prefs.hasLaunchedBefore {
            prefs.hasLaunchedBefore = true
            LoginItem.setEnabled(true)
            showWelcome()
        } else if controller.needsPermission {
            showWelcome()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.recheckPermission()
    }

    private func refresh() {
        statusItem.button?.appearsDisabled = !controller.isStreaming
        welcome?.update(from: controller)
        if menuIsOpen {
            titleItem?.attributedTitle = title()
            detailItem?.attributedTitle = detail()
            statsItem?.attributedTitle = stats()
            if let slider = brightnessSlider, let value = controller.receiverBrightness, !slider.isHighlighted {
                slider.floatValue = value
            }
        }
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        controller.recheckPermission()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = controller.prefs
        let peer = controller.peerKind, this = Machine.kind

        // Status: the iMac's name, how it's connected (⌥ for the numbers), and pausing.
        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = title()
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        self.titleItem = titleItem
        let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailItem.attributedTitle = detail()
        detailItem.isEnabled = false
        menu.addItem(detailItem)
        self.detailItem = detailItem
        if controller.isStreaming {
            let statsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            statsItem.attributedTitle = stats()
            statsItem.isEnabled = false
            statsItem.isAlternate = true
            statsItem.keyEquivalentModifierMask = .option
            menu.addItem(statsItem)
            self.statsItem = statsItem
        } else {
            statsItem = nil
        }
        if controller.paused {
            menu.addItem(item("Resume Tandem", #selector(resume)))
        } else {
            menu.addItem(item("Pause Tandem", #selector(pause)))
            let reconnect = item("Reconnect", #selector(reconnect))
            reconnect.isAlternate = true
            reconnect.keyEquivalentModifierMask = .option
            menu.addItem(reconnect)
        }
        let wantsAccessibility = prefs.usesReceiverInput || (prefs.brightnessKeysFollowPointer && controller.receiverBrightness != nil)
        if controller.needsPermission {
            menu.addItem(item("Allow Screen Recording…", #selector(openPermissions)))
        }
        if wantsAccessibility && !Accessibility.isAllowed {
            let allow = item("Allow Accessibility…", #selector(allowAccessibility))
            allow.toolTip = "Lets the \(peer)'s keyboard and mouse control this Mac, and the brightness keys reach the \(peer)."
            menu.addItem(allow)
        }

        // The display. Live controls only while there is one; settings always.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Display"))
        if let brightness = controller.receiverBrightness {
            let row = NSMenuItem()
            let slider = sliderView(value: brightness, range: 0...1, low: "sun.min", high: "sun.max",
                                    label: "\(peer) Brightness", action: #selector(brightnessChanged(_:)))
            brightnessSlider = slider
            row.view = slider.superview
            menu.addItem(row)
        } else {
            brightnessSlider = nil
        }
        // Only Macs with their own screen have a brightness to match, and brightness keys.
        if MacBookPanel.brightness() != nil {
            menu.addItem(toggle("Match \(this) Brightness", prefs.followsBrightness, #selector(toggleFollowBrightness)))
        }
        if MacBookPanel.colorMatrix() != nil {
            menu.addItem(toggle("Match True Tone and Night Shift", prefs.matchesColor, #selector(toggleMatchColor)))
        }
        if MacBookPanel.brightness() != nil {
            let keys = toggle("Brightness Keys Follow Pointer", prefs.brightnessKeysFollowPointer, #selector(toggleBrightnessKeys))
            keys.toolTip = "With the pointer on the \(peer), the brightness keys change the \(peer) instead of this Mac."
            menu.addItem(keys)
        }
        if let screen = controller.screen {
            let resolutions = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for resolution in screen.resolutions() {
                var title = "\(resolution.width) × \(resolution.height)"
                if resolution.isDefault { title += "  (Default)" }
                let option = item(title, #selector(chooseResolution(_:)))
                option.state = resolution.isCurrent ? .on : .off
                option.tag = resolution.width
                sub.addItem(option)
            }
            resolutions.submenu = sub
            menu.addItem(resolutions)
        }
        let quality = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        let qualityMenu = NSMenu()
        let adaptive = item("Adaptive", #selector(choosePicture(_:)))
        adaptive.toolTip = "Pixel-perfect whenever the cable can keep up. Moving areas are lightly compressed when it can't, then sharpened as soon as they stop."
        adaptive.representedObject = TileEncoder.Quality.automatic.rawValue
        adaptive.state = prefs.quality == .automatic ? .on : .off
        let full = item("Full Quality", #selector(choosePicture(_:)))
        full.toolTip = "Every pixel exactly, always. Fast motion may be less smooth."
        full.representedObject = TileEncoder.Quality.lossless.rawValue
        full.state = prefs.quality == .lossless ? .on : .off
        qualityMenu.addItem(adaptive)
        qualityMenu.addItem(full)
        quality.submenu = qualityMenu
        menu.addItem(quality)
        menu.addItem(item("Displays Settings…", #selector(openDisplays)))

        // The iMac's keyboard, mouse and camera.
        menu.addItem(.separator())
        let use = toggle("Use \(peer) Keyboard and Mouse", prefs.usesReceiverInput, #selector(toggleReceiverInput))
        let hint = "Click the \(peer) to start · press and release ⌃⌥ to stop"
        if #available(macOS 14.4, *) { use.subtitle = hint }
        use.toolTip = "Click on the \(peer) to control this Mac with its keyboard and mouse. Press and release Control-Option to give them back."
        menu.addItem(use)
        menu.addItem(pointerMenuItem())
        menu.addItem(cameraMenuItem())

        menu.addItem(.separator())
        menu.addItem(toggle("Sleep \(peer) with \(this)", prefs.sleepsReceiver, #selector(toggleSleep)))
        menu.addItem(toggle("Wake \(peer) with \(this)", prefs.wakesReceiver, #selector(toggleWake)))

        menu.addItem(.separator())
        menu.addItem(toggle("Open at Login", LoginItem.isEnabled, #selector(toggleLoginItem)))
        menu.addItem(item("Permissions…", #selector(showPermissions)))
        menu.addItem(item(controller.peerCanSwap ? "Swap Roles with \(peer)…" : "Use This Mac as a Display Instead…", #selector(switchRole)))
        if let settings = controller.receiverSettings {
            let remote = NSMenuItem(title: "\(peer) Settings", action: nil, keyEquivalent: "")
            remote.submenu = remoteMenu(settings.items, path: [])
            menu.addItem(remote)
        }
        controller.refreshReceiverSettings()

        menu.addItem(.separator())
        menu.addItem(item("About Tandem", #selector(about)))
        menu.addItem(item("Quit Tandem", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func title() -> NSAttributedString {
        let name = controller.receiverName ?? "Tandem"
        return NSAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
    }

    /// In plain words: connected, looking, paused, asleep…
    private func detail() -> NSAttributedString {
        var text = controller.status
        if controller.isStreaming { text = "Connected over \(controller.linkName ?? "the cable")" }
        return small(text)
    }

    /// The numbers, shown with ⌥: the link's measured speed, then what's being sent.
    private func stats() -> NSAttributedString {
        var parts: [String] = []
        if let name = controller.linkName, let rate = controller.linkRate {
            parts.append(String(format: "%@ %.1f Gbit/s", name, rate * 8 / 1e9))
        }
        if !controller.stats.isEmpty { parts.append("Sending " + controller.stats) }
        return small(parts.isEmpty ? "Measuring…" : parts.joined(separator: "\n"))
    }

    private func small(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func cameraMenuItem() -> NSMenuItem {
        let prefs = controller.prefs
        let item = NSMenuItem(title: "Tandem Camera", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let peer = controller.peerKind, this = Machine.kind
        let modes: [(String, CameraSwitcher.Mode, String)] = [
            ("Automatic", .automatic, "Shows whichever camera you're facing: the \(peer)'s or the \(this)'s."),
            ("\(peer) Camera", .remote, "Always the \(peer)'s camera."),
            ("\(this) Camera", .local, "Always the \(this)'s camera."),
        ]
        for (title, mode, tip) in modes {
            let option = self.item(title, #selector(chooseCameraMode(_:)))
            option.representedObject = mode.rawValue
            option.state = prefs.cameraMode == mode ? .on : .off
            option.toolTip = tip
            sub.addItem(option)
        }
        if prefs.cameraMode == .automatic {
            sub.addItem(.sectionHeader(title: "Switching"))
            for pace in CameraSwitcher.Pace.allCases {
                let option = self.item(pace.title, #selector(chooseCameraPace(_:)))
                option.representedObject = pace.rawValue
                option.state = prefs.cameraPace == pace ? .on : .off
                option.toolTip = String(format: "Switches after you've faced the other camera for %g s, at most every %g s.",
                                        pace.dwell, pace.cooldown)
                sub.addItem(option)
            }
        }
        sub.addItem(.separator())
        let match = toggle("Match Colours", prefs.cameraMatchesColour, #selector(toggleCameraColour))
        match.toolTip = "Tints the \(peer)'s camera to match the \(this)'s, learnt from your face while both cameras see you."
        sub.addItem(match)
        sub.addItem(self.item("Show Camera Preview…", #selector(showCameraPreview)))
        sub.addItem(.separator())
        let offer = toggle("Offer Tandem Camera to Apps", prefs.offersCamera, #selector(toggleCamera))
        offer.toolTip = "Adds Tandem Camera to the cameras FaceTime, Zoom, Teams and others can use."
        sub.addItem(offer)
        switch camera.state {
        case .needsApproval:
            let allow = self.item("Allow Tandem Camera in System Settings…", #selector(approveCamera))
            allow.toolTip = "General → Login Items & Extensions → Camera Extensions"
            sub.addItem(allow)
        case .failed(let reason):
            let failed = NSMenuItem(title: "Tandem Camera Isn't Allowed on This Mac", action: nil, keyEquivalent: "")
            failed.toolTip = reason
            failed.isEnabled = false
            sub.addItem(failed)
        default:
            break
        }
        item.submenu = sub
        return item
    }

    @objc private func chooseCameraMode(_ item: NSMenuItem) {
        guard let mode = (item.representedObject as? String).flatMap(CameraSwitcher.Mode.init) else { return }
        controller.prefs.cameraMode = mode
        switcher.setMode(mode)
    }

    @objc private func chooseCameraPace(_ item: NSMenuItem) {
        guard let pace = (item.representedObject as? String).flatMap(CameraSwitcher.Pace.init) else { return }
        controller.prefs.cameraPace = pace
        switcher.setPace(pace)
    }

    @objc private func toggleCameraColour() {
        controller.prefs.cameraMatchesColour.toggle()
        switcher.setMatchesColour(controller.prefs.cameraMatchesColour)
    }

    @objc private func showCameraPreview() {
        cameraPreview.show()
    }

    /// Speeds and scrolling for the iMac's mouse; only with its keyboard and mouse in use.
    private func pointerMenuItem() -> NSMenuItem {
        let prefs = controller.prefs
        let peer = controller.peerKind
        let item = NSMenuItem(title: "Pointer and Scrolling", action: nil, keyEquivalent: "")
        item.isEnabled = prefs.usesReceiverInput
        let sub = NSMenu()
        sub.autoenablesItems = false
        // Speeds go from a quarter to four times the other Mac's own, evenly on a log scale.
        sub.addItem(.sectionHeader(title: "Tracking Speed"))
        sub.addItem(sliderItem(log2(prefs.pointerSpeed), low: "tortoise", high: "hare", label: "Tracking Speed",
                               action: #selector(pointerSpeedChanged(_:))))
        sub.addItem(.sectionHeader(title: "Scrolling Speed"))
        sub.addItem(sliderItem(log2(prefs.scrollSpeed), low: "tortoise", high: "hare", label: "Scrolling Speed",
                               action: #selector(scrollSpeedChanged(_:))))
        sub.addItem(toggle("Reverse Scrolling Direction", prefs.reversesScrolling, #selector(toggleReverseScrolling)))
        sub.addItem(.separator())
        sub.addItem(self.item("Reset to \(peer) Settings", #selector(resetInputTuning)))
        item.submenu = sub
        return item
    }

    private func sliderItem(_ value: Double, low: String, high: String, label: String, action: Selector) -> NSMenuItem {
        let slider = sliderView(value: Float(value), range: -2...2, low: low, high: high, label: label, action: action)
        slider.numberOfTickMarks = 5
        let item = NSMenuItem()
        item.view = slider.superview
        return item
    }

    /// A menu row with a slider between two symbols. Returns the slider, inside its row view.
    private func sliderView(value: Float, range: ClosedRange<Double>, low: String, high: String, label: String,
                            action: Selector) -> NSSlider {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        let low = NSImageView(image: NSImage(systemSymbolName: low, accessibilityDescription: nil)!)
        let high = NSImageView(image: NSImage(systemSymbolName: high, accessibilityDescription: nil)!)
        let slider = NSSlider()
        slider.cell = MenuSliderCell()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = Double(value)
        slider.target = self
        slider.action = action
        slider.isContinuous = true
        slider.setAccessibilityLabel(label)
        slider.controlSize = .small
        for v in [low, high, slider] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        low.contentTintColor = .secondaryLabelColor
        high.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            low.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            low.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            high.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            high.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            high.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return slider
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    // MARK: Actions

    @objc private func brightnessChanged(_ slider: NSSlider) {
        controller.setReceiverBrightness(slider.floatValue)
    }

    @objc private func toggleFollowBrightness() {
        controller.setFollowsBrightness(!controller.prefs.followsBrightness)
    }

    @objc private func toggleBrightnessKeys() {
        controller.prefs.brightnessKeysFollowPointer.toggle()
        if controller.prefs.brightnessKeysFollowPointer { ask(for: .accessibility) }
        setUpBrightnessKeys()
    }

    @objc private func pointerSpeedChanged(_ slider: NSSlider) {
        controller.prefs.pointerSpeed = pow(2, snapped(slider.doubleValue))
        controller.updateInputTuning()
    }

    @objc private func scrollSpeedChanged(_ slider: NSSlider) {
        controller.prefs.scrollSpeed = pow(2, snapped(slider.doubleValue))
        controller.updateInputTuning()
    }

    /// Settles on the other Mac's own speed when the slider is close to the middle.
    private func snapped(_ value: Double) -> Double {
        abs(value) < 0.08 ? 0 : value
    }

    @objc private func toggleReverseScrolling() {
        controller.prefs.reversesScrolling.toggle()
        controller.updateInputTuning()
    }

    @objc private func resetInputTuning() {
        controller.prefs.pointerSpeed = 1
        controller.prefs.scrollSpeed = 1
        controller.prefs.reversesScrolling = false
        controller.updateInputTuning()
    }

    @objc private func toggleCamera() {
        controller.prefs.offersCamera.toggle()
        if controller.prefs.offersCamera { ask(for: .camera) }
        if controller.prefs.offersCamera { camera.install() } else { camera.uninstall() }
    }

    @objc private func approveCamera() {
        CameraExtension.openApprovalSettings()
    }

    @objc private func toggleReceiverInput() {
        controller.setUsesReceiverInput(!controller.prefs.usesReceiverInput)
        if controller.prefs.usesReceiverInput { ask(for: .accessibility) }
        setUpBrightnessKeys()
    }

    @objc private func allowAccessibility() {
        Accessibility.prompt()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func setUpBrightnessKeys() {
        let prefs = controller.prefs
        let wantsAccessibility = prefs.brightnessKeysFollowPointer || prefs.usesReceiverInput
        if wantsAccessibility && !Accessibility.isAllowed && !prefs.askedForAccessibility {
            prefs.askedForAccessibility = true
            Accessibility.prompt()
        }
        brightnessKeys.setEnabled(prefs.brightnessKeysFollowPointer)
    }

    @objc private func toggleMatchColor() {
        controller.setMatchesColor(!controller.prefs.matchesColor)
    }

    @objc private func chooseResolution(_ item: NSMenuItem) {
        guard let screen = controller.screen,
              let resolution = screen.resolutions().first(where: { $0.width == item.tag })
        else { return }
        screen.use(resolution)
    }

    @objc private func choosePicture(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let quality = TileEncoder.Quality(rawValue: raw) else { return }
        controller.setQuality(quality)
    }

    @objc private func toggleSleep() {
        controller.prefs.sleepsReceiver.toggle()
    }

    @objc private func toggleWake() {
        controller.prefs.wakesReceiver.toggle()
    }

    /// The other Mac's settings menu, as it sent it.
    private func remoteMenu(_ items: [RemoteMenu.Item], path: [Int]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (position, remote) in items.enumerated() {
            if remote.separator { menu.addItem(.separator()); continue }
            if remote.header { menu.addItem(.sectionHeader(title: remote.title)); continue }
            let item = NSMenuItem(title: remote.title, action: nil, keyEquivalent: "")
            if let children = remote.items {
                item.submenu = remoteMenu(children, path: path + [position])
            } else {
                item.action = #selector(chooseRemoteSetting(_:))
                item.target = self
                item.representedObject = RemoteMenu.Choice(path: path + [position], title: remote.title)
            }
            item.state = remote.on ? .on : .off
            item.isEnabled = remote.enabled
            item.toolTip = remote.toolTip
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseRemoteSetting(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? RemoteMenu.Choice else { return }
        controller.chooseReceiverSetting(choice)
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func openDisplays() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    @objc private func openPermissions() {
        showWelcome()
    }

    @objc private func showPermissions() {
        permissionsWindow.show()
    }

    /// Asks for a permission as a feature that needs it is turned on, if it's missing.
    private func ask(for permission: Permission) {
        if permission.isGranted == false { permission.request() }
    }

    @objc private func pause() {
        controller.pause()
    }

    @objc private func resume() {
        controller.resume()
    }

    @objc private func reconnect() {
        controller.reconnect()
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Another Mac's screen, keyboard, mouse and camera, as if they were this Mac's own.",
                                         attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func switchRole() {
        let alert = NSAlert()
        let swap = controller.peerCanSwap
        if swap {
            alert.messageText = "Swap roles with the \(controller.peerKind)?"
            alert.informativeText = "This \(Machine.kind) will become the display, and the \(controller.peerKind) will extend onto it. Both Macs restart Tandem to swap."
            alert.addButton(withTitle: "Swap Roles")
        } else {
            alert.messageText = "Use this \(Machine.kind) as a display?"
            alert.informativeText = "It will stop extending onto the \(controller.peerKind), and show another Mac's screen full screen instead."
            alert.addButton(withTitle: "Use as Display")
        }
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The other Mac may have gone while the alert was up.
        if swap && controller.peerCanSwap {
            controller.requestSwap { Role.switchTo(.display) }
        } else {
            Role.switchTo(.display)
        }
    }

    private func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindow(controller: controller) { [weak self] in self?.welcome = nil }
        }
        welcome?.show()
    }
}

@available(macOS 14, *)
private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
