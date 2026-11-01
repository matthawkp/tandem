import AppKit
import QuartzCore

/// Shown over the stream whenever there is no picture: before the other Mac connects, while it
/// is connected but not yet sending, and after it disconnects.
final class SplashView: NSView {
    enum State {
        case waiting
        case connected(String?)
        case disconnected(String?)
        case asleep
    }

    private let gradient = CAGradientLayer()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "Tandem")
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let settingsButton = NSButton()
    var onSettings: ((NSView) -> Void)?
    /// The Mac whose screen this shows, e.g. "MacBook Pro", or "Mac" before one has connected.
    var peerKind = Peer.last?.kind ?? "Mac"

    init(frame: NSRect, footerText: String) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.colors = [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.17, alpha: 1).cgColor,
                           NSColor(srgbRed: 0.02, green: 0.02, blue: 0.04, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)

        let symbol = ["macbook.and.imac", "display.2", "display"].lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.first
        icon.image = symbol?.withSymbolConfiguration(.init(pointSize: 120, weight: .thin))
        icon.contentTintColor = NSColor(white: 1, alpha: 0.85)

        title.font = .systemFont(ofSize: 64, weight: .semibold)
        title.textColor = .white
        headline.font = .systemFont(ofSize: 30, weight: .medium)
        headline.textColor = NSColor(white: 1, alpha: 0.9)
        detail.font = .systemFont(ofSize: 20)
        detail.textColor = NSColor(white: 1, alpha: 0.55)
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 760
        footer.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        footer.textColor = NSColor(white: 1, alpha: 0.35)
        footer.stringValue = footerText

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 7
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.2
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        let headlineRow = NSStackView(views: [dot, headline])
        headlineRow.spacing = 14
        let stack = NSStackView(views: [icon, title, headlineRow, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.setCustomSpacing(36, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        settingsButton.isBordered = false
        settingsButton.contentTintColor = NSColor(white: 1, alpha: 0.4)
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        settingsButton.toolTip = "Settings"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(footer)
        addSubview(settingsButton)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            footer.centerXAnchor.constraint(equalTo: centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            settingsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func settingsClicked() {
        onSettings?(settingsButton)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    func show(_ state: State) {
        let hint = "Connect the Thunderbolt cable and open Tandem on your \(peerKind)."
        switch state {
        case .waiting:
            headline.stringValue = "Waiting for your \(peerKind)"
            detail.stringValue = hint
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .connected(let status):
            headline.stringValue = "Connected"
            detail.stringValue = status ?? "Starting the picture…"
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .disconnected(let status):
            headline.stringValue = "Disconnected"
            detail.stringValue = status ?? "Waiting for your \(peerKind) to reconnect. " + hint
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        case .asleep:
            headline.stringValue = "Your \(peerKind) is asleep"
            detail.stringValue = "This screen turned off with it, and comes back on when your \(peerKind) wakes."
            dot.layer?.backgroundColor = NSColor.systemIndigo.cgColor
        }
        setVisible(true)
    }

    func setVisible(_ visible: Bool) {
        if visible { isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            animator().alphaValue = visible ? 1 : 0
        }, completionHandler: {
            if !visible && self.alphaValue == 0 { self.isHidden = true }
        })
    }
}
