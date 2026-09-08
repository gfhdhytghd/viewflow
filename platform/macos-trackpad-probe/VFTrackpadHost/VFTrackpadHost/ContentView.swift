import SwiftUI
import Combine
import SystemExtensions

final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Ready. Installation requires your explicit request and macOS approval."
    @Published var pending = false
    private var activeRequest: OSSystemExtensionRequest?

    func activate() {
        guard !pending else { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            status = "Move this app to /Applications and reopen it before requesting installation."
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "org.viewflow.trackpad-probe", queue: .main)
        request.delegate = self
        activeRequest = request
        pending = true
        status = "Installation requested. Follow macOS approval prompts; keep SIP enabled."
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Awaiting your approval in System Settings. Installation submits no touch input."
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        guard existing.bundleIdentifier == "org.viewflow.trackpad-probe",
              ext.bundleIdentifier == existing.bundleIdentifier else { return .cancel }
        status = "Updating the existing Viewflow driver after your installation request."
        return .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = result == .completed
            ? "Activation completed. Device enumeration and gestures have NOT been verified."
            : "macOS requires a restart to finish. Device enumeration is not yet verified."
        pending = false
        activeRequest = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let detail = error as NSError
        status = "Installation failed: \(detail.domain) (\(detail.code)): \(detail.localizedDescription)"
        pending = false
        activeRequest = nil
    }
}

struct ContentView: View {
    @StateObject private var installer = ExtensionInstaller()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Viewflow Trackpad Probe").font(.title)
            Text("Development driver · five-contact input prototype")
            Text("The SSH receiver accepts real touch frames only when you start it. Native gesture recognition remains unverified.")
            Button("Request Driver Installation") { installer.activate() }
                .disabled(installer.pending)
            Text(installer.status).textSelection(.enabled)
        }
        .padding(28)
        .frame(width: 560, height: 280)
    }
}

#Preview {
    ContentView()
}
