import AppKit
import SwiftUI

/// First-run window: what Tandem needs from macOS and the other Mac, with live progress.
@available(macOS 14, *)
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model = Model()
    private let permissions = PermissionsWindow.Model(role: .extend)
    private let onClose: () -> Void
    private var timer: Timer?

    final class Model: ObservableObject {
        @Published var hasPermission = false
        @Published var receiverName: String?
    }

    init(controller: SenderController, onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let view = WelcomeView(model: model, permissions: permissions,
                               allow: { $0.request() },
                               reopen: relaunch, // macOS only applies a new Screen Recording permission after a restart.
                               done: { [weak self] in self?.window.close() })
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        update(from: controller)
        // Screen Recording is granted in System Settings, so check back now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.hasPermission = CGPreflightScreenCaptureAccess()
            self?.permissions.refresh()
        }
    }

    func update(from controller: SenderController) {
        model.hasPermission = !controller.needsPermission && CGPreflightScreenCaptureAccess()
        model.receiverName = controller.receiverName
    }

    func show() {
        // Always on the MacBook's own screen, never on the iMac.
        let screen = NSScreen.screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return id.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        } ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2 + 60))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        onClose()
    }

}

@available(macOS 14, *)
private struct WelcomeView: View {
    @ObservedObject var model: WelcomeWindow.Model
    let permissions: PermissionsWindow.Model
    let allow: (Permission) -> Void
    let reopen: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
            VStack(spacing: 6) {
                Text("Welcome to Tandem")
                    .font(.system(size: 26, weight: .bold))
                Text("Another Mac's screen becomes a sharp extra display for this one.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 20) {
                Step(number: 1, done: model.hasPermission, title: "Allow what Tandem uses",
                     detail: "Screen Recording is needed; the rest are for the features that use them.") {
                    VStack(alignment: .leading, spacing: 10) {
                        PermissionsList(model: permissions, allow: allow)
                        if !model.hasPermission {
                            Button("Allowed Screen Recording already? Reopen Tandem", action: reopen)
                                .buttonStyle(.link)
                        }
                    }
                }
                Step(number: 2, done: model.receiverName != nil, title: "Connect your other Mac",
                     detail: model.receiverName.map { "Connected to \($0)." }
                        ?? "Join the Macs with a Thunderbolt cable, then open Tandem on the other Mac and choose Be a Display.") {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(model.hasPermission && model.receiverName != nil ? "Done" : "Later", action: done)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 560)
    }
}

@available(macOS 14, *)
private struct Step<Accessory: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                accessory().padding(.top, 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: done)
    }
}
