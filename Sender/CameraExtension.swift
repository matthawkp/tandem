import AppKit
import SystemExtensions

/// Installs "Tandem Camera", the camera extension inside Tandem. Once macOS has it, any app can
/// pick Tandem Camera, which shows what Tandem's camera switcher sends it.
@available(macOS 14, *)
final class CameraExtension: NSObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case off
        case installing
        /// macOS wants the person to allow it in System Settings.
        case needsApproval
        case installed
        case failed(String)
    }

    static let identifier = (Bundle.main.bundleIdentifier ?? "") + ".Camera"
    private(set) var state = State.off
    var onChange: () -> Void = {}

    /// Safe to repeat: macOS only replaces the installed copy when this one is newer.
    func install() {
        state = .installing
        submit(.activationRequest(forExtensionWithIdentifier: CameraExtension.identifier, queue: .main))
    }

    func uninstall() {
        state = .off
        submit(.deactivationRequest(forExtensionWithIdentifier: CameraExtension.identifier, queue: .main))
        onChange()
    }

    static func openApprovalSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log("camera extension: replacing \(existing.bundleVersion) with \(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log("camera extension: waiting for approval in System Settings")
        state = .needsApproval
        onChange()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard state != .off else { return }
        log("camera extension: installed\(result == .willCompleteAfterReboot ? " after a restart" : "")")
        state = .installed
        onChange()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard state != .off else { return }
        log("camera extension: failed: \(error)")
        if (error as NSError).domain == OSSystemExtensionErrorDomain,
           (error as NSError).code == OSSystemExtensionError.forbiddenBySystemPolicy.rawValue {
            state = .failed("This Mac is managed by an organisation whose settings only allow approved system extensions.")
        } else {
            state = .failed(error.localizedDescription)
        }
        onChange()
    }
}
