import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SystemExtensions

@MainActor final class Permissions: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let driverID = "org.viewflow.trackpad-probe"
    @Published var screen = false
    @Published var accessibility = false
    @Published var workerScreen: Bool?
    @Published var workerInput: Bool?
    @Published var driverAttached = false
    @Published var driverEnabled = false
    @Published var driverPending = false
    @Published var driverMessage = "尚未检查"
    @Published var inputMessage = ""
    @Published var screenMessage = ""
    @Published var loginMessage = ""
    @Published var loginEnabled = false
    @Published var refreshing = false
    private var requests: [OSSystemExtensionRequest] = []
    private let permissionGuide = PermissionGuide()

    var canCapture: Bool { workerScreen ?? screen }
    var canPostInput: Bool { workerInput ?? accessibility }

    func refresh() {
        screen = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        loginEnabled = SMAppService.mainApp.status == .enabled
        guard !refreshing else { return }
        refreshing = true
        let executable: URL? = BundleTools.appURL.appendingPathComponent("Contents/MacOS/Viewflow")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let windows = Result { try NativeProbe.json(BundleTools.executable("viewflow-macos-windows"), ["--permissions"]) }
            let input = Result { try NativeProbe.json(BundleTools.executable("viewflowd"), ["--macos-input-status"]) }
            let driver: Result<[String: Any], Error> = Result {
                guard let executable else { throw ViewflowError.invalid("应用路径不可用") }
                return try NativeProbe.json(executable, ["--driver-status"])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                switch windows {
                case .success(let report): self.workerScreen = report["screen_recording_authorized"] as? Bool; self.screenMessage = ""
                case .failure(let error): self.workerScreen = nil; self.screenMessage = error.localizedDescription
                }
                switch input {
                case .success(let report): self.workerInput = report["event_post_authorized"] as? Bool; self.inputMessage = ""
                case .failure(let error): self.workerInput = nil; self.inputMessage = error.localizedDescription
                }
                switch driver {
                case .success(let report):
                    self.driverAttached = report["native_multitouch_attached"] as? Bool == true
                    self.driverMessage = self.driverAttached ? "原生触控板已就绪" : "驱动可读取，等待原生触控板注册"
                case .failure(let error):
                    self.driverAttached = false
                    if !self.driverPending { self.driverMessage = error.localizedDescription }
                }
            }
        }
    }
    func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }
    func openSettings(_ pane: String) {
        if pane == "Privacy_ScreenCapture" || pane == "Privacy_Accessibility" {
            permissionGuide.show(title: pane == "Privacy_ScreenCapture" ? "屏幕与系统音频录制" : "辅助功能",
                                 appURL: BundleTools.appURL) { [weak self] in self?.refresh() }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
           NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置的登录项中允许 Viewflow" : ""
        } catch { loginMessage = error.localizedDescription }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    func installDriver() {
        guard !driverPending else { return }
        guard FileManager.default.fileExists(atPath: BundleTools.driverURL.path) else {
            driverMessage = "此构建没有包含 HID 驱动，请使用完整安装包"; return
        }
        guard BundleTools.appURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/") else {
            driverMessage = "请将 Viewflow.app 移到 /Applications，再安装 HID 驱动"; return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.driverID, queue: .main)
        request.delegate = self; requests.append(request); driverPending = true
        driverMessage = "正在向 macOS 申请安装驱动"
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        driverMessage = "请在系统设置中允许 Viewflow 的驱动扩展"
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        existing.bundleIdentifier == Self.driverID && replacement.bundleIdentifier == Self.driverID ? .replace : .cancel
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        requests.removeAll { $0 === request }; driverPending = false
        driverEnabled = result == .completed
        driverMessage = result == .completed ? "驱动已激活，正在检查触控板" : "macOS 需要重新启动以完成驱动安装"
        refresh()
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        requests.removeAll { $0 === request }; driverPending = false; driverMessage = error.localizedDescription
    }
}
