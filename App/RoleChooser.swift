import AppKit
import SwiftUI

/// First launch: asks which role this Mac plays, with a suggestion already picked.
final class RoleChooser: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let detector = RoleDetector()
    private let model = Model()

    final class Model: ObservableObject {
        @Published var choice = Role.extend
        @Published var suggestion: RoleDetector.Suggestion?
        /// Until the person picks one themselves, the choice follows the suggestion.
        var picked = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.suggestion = detector.suggestion
        model.choice = detector.suggestion.role
        detector.onChange = { [weak self] suggestion in
            guard let self else { return }
            self.model.suggestion = suggestion
            if !self.model.picked { self.model.choice = suggestion.role }
        }
        detector.start()

        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = self
        let hosting = NSHostingView(rootView: RoleChooserView(model: model) { [weak self] role in self?.choose(role) })
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func choose(_ role: Role) {
        log("role chosen: \(role)")
        detector.stop()
        Role.switchTo(role)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

private struct RoleChooserView: View {
    @ObservedObject var model: RoleChooser.Model
    let choose: (Role) -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Welcome to Tandem")
                    .font(.system(size: 26, weight: .bold))
                Text("Two Macs, working as one. What should this \(Machine.kind) do?")
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 14) {
                card(.extend, symbol: "laptopcomputer.and.arrow.down", title: "Extend This Mac",
                     detail: Role.canExtend ? "Use another Mac's screen as an extra display, with its keyboard, mouse and camera."
                                            : "Needs macOS Sonoma or later.")
                    .disabled(!Role.canExtend)
                    .opacity(Role.canExtend ? 1 : 0.5)
                card(.display, symbol: "display", title: "Be a Display",
                     detail: "Show another Mac's screen here, full screen and pixel for pixel.")
            }
            if let suggestion = model.suggestion {
                Label(suggestion.reason, systemImage: "sparkles")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Button("Continue") { choose(model.choice) }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            Text("You can change this later from Tandem's menu.")
                .font(.footnote)
                .foregroundColor(Color.secondary.opacity(0.7))
        }
        .padding(.horizontal, 36)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 560)
        .animation(.easeInOut(duration: 0.2), value: model.choice)
    }

    private func card(_ role: Role, symbol: String, title: String, detail: String) -> some View {
        let selected = model.choice == role
        return Button {
            model.picked = true
            model.choice = role
        } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .frame(height: 44)
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if model.suggestion?.role == role {
                    Text("Suggested")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(selected ? 0.07 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                                                     lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}
