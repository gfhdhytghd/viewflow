import Foundation
import Darwin

enum BundleTools {
    static func captureExecutable(for instance: String) throws -> URL {
        guard !instance.isEmpty, instance.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw ViewflowError.invalid("无效的窗口捕获实例")
        }
        // replayd identifies unbundled clients by executable path. A shared
        // path lets inventory probes or another stream replace this client.
        // Keep each signed helper inside the app-owned private runtime store.
        let source = try executable("viewflow-macos-windows")
        let destination = ProfileStore.root.appendingPathComponent("run/capture-helpers/\(instance)/viewflow-macos-windows")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) != data {
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        }
        return destination
    }
    static var appURL: URL {
        let original = Bundle.main.bundleURL
        if FileManager.default.fileExists(atPath: original.path) { return original }
        let installed = URL(fileURLWithPath: "/Applications/Viewflow.app")
        if let bundle = Bundle(url: installed), bundle.bundleIdentifier == Bundle.main.bundleIdentifier { return installed }
        return original
    }
    static func executable(_ name: String) throws -> URL {
        let allowed: Set<String> = ["viewflowd", "vf-window-peer", "vf-clipboard-peer",
                                    "viewflow-macos-windows", "viewflow-macos-probe"]
        guard allowed.contains(name) else { throw ViewflowError.invalid("未知组件") }
        let url = appURL.appendingPathComponent("Contents/Helpers/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ViewflowError.invalid("安装包缺少组件：\(name)")
        }
        return url
    }
    static var driverURL: URL {
        appURL.appendingPathComponent("Contents/Library/SystemExtensions/org.viewflow.trackpad-probe.dext")
    }
    static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Viewflow")
    }
    static var developmentBuild: Bool {
        guard let url = Bundle.main.url(forResource: "build-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return manifest["signing"] as? String != "identity"
    }
}

// Probe subprocesses run off the UI thread and never post input. A timeout is
// only a watchdog for that diagnostic process; it cannot stop a live service.
enum NativeProbe {
    static func json(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 12) throws -> [String: Any] {
        let directory = ProfileStore.root.appendingPathComponent("run/probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output"), errorURL = directory.appendingPathComponent("error")
        try ProfileStore.writePrivate(Data(), to: outputURL)
        try ProfileStore.writePrivate(Data(), to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 2) == .timedOut && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            throw ViewflowError.invalid("状态检查暂时没有响应，请稍后刷新")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 4 * 1024 * 1024 else { throw ViewflowError.invalid("状态检查返回的数据过大") }
        let data = try Data(contentsOf: outputURL)
        if let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return report }
        let message = String(data: (try? Data(contentsOf: errorURL)) ?? Data(), encoding: .utf8) ?? ""
        throw ViewflowError.invalid(message.isEmpty ? "组件检查退出：\(process.terminationStatus)" : String(message.suffix(800)))
    }
}

@MainActor final class ManagedWorker {
    let id: String
    let component: Component
    let executable: URL
    let arguments: [String]
    private(set) var process: Process?
    private(set) var status = "已停止"
    private(set) var lastExit: Int32?
    private(set) var stopping = false
    var desired = false
    var changed: (() -> Void)?
    private var retry = RestartPolicy()
    private var nextStart = Date.distantPast
    private var started = Date.distantPast
    private var output: FileHandle?
    private var terminationStage = 0

    init(id: String, component: Component, executable: URL, arguments: [String]) {
        self.id = id; self.component = component; self.executable = executable; self.arguments = arguments
    }
    func reconcile() {
        guard desired, process == nil, Date() >= nextStart else { return }
        do {
            try FileManager.default.createDirectory(at: BundleTools.logs, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let log = BundleTools.logs.appendingPathComponent("\(id).log")
            if let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size]) as? NSNumber,
               size.intValue > 5 * 1024 * 1024 {
                let old = log.appendingPathExtension("previous")
                try? FileManager.default.removeItem(at: old)
                try FileManager.default.moveItem(at: log, to: old)
            }
            if !FileManager.default.fileExists(atPath: log.path) { try ProfileStore.writePrivate(Data(), to: log) }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            let child = Process()
            child.executableURL = executable; child.arguments = arguments
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = handle; child.standardError = handle
            var environment = ProcessInfo.processInfo.environment
            environment["VIEWFLOW_CURSOR_FEEDBACK"] = "1"
            child.environment = environment
            child.terminationHandler = { [weak self] child in
                DispatchQueue.main.async {
                    guard let self, self.process === child else { return }
                    self.lastExit = child.terminationStatus
                    self.process = nil; self.stopping = false
                    try? self.output?.close(); self.output = nil
                    if Date().timeIntervalSince(self.started) > 30 { self.retry.stableRun() }
                    self.status = self.desired ? "组件已退出，正在恢复（\(child.terminationStatus)）" : "已停止"
                    self.nextStart = Date().addingTimeInterval(self.retry.failed())
                    self.changed?()
                }
            }
            try child.run()
            process = child; output = handle; started = Date(); stopping = false; terminationStage = 0
            status = "正在运行"; changed?()
        } catch {
            status = "启动失败：\(error.localizedDescription)"
            nextStart = Date().addingTimeInterval(retry.failed()); changed?()
        }
    }
    // Invoked directly by the modal-mode termination timer. Do not depend on
    // the normal main-queue terminationHandler being serviced during app exit.
    func pollTermination(elapsed: TimeInterval) {
        guard let child = process else { return }
        if !child.isRunning {
            lastExit = child.terminationStatus; process = nil; stopping = false
            try? output?.close(); output = nil; status = "已停止"
            return
        }
        if elapsed >= 4 && terminationStage < 2 {
            terminationStage = 2; kill(child.processIdentifier, SIGKILL)
        } else if elapsed >= 2 && terminationStage < 1 {
            terminationStage = 1; child.terminate()
        }
    }
    func stop() {
        desired = false
        guard let child = process, child.isRunning, !stopping else { return }
        stopping = true; status = "正在结束连接"; changed?()
        child.interrupt() // Rust peers close QUIC/native stdin and release held input.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak child] in
            guard let self, let child, self.process === child, child.isRunning, self.stopping else { return }
            child.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak child] in
                guard let self, let child, self.process === child, child.isRunning, self.stopping else { return }
                kill(child.processIdentifier, SIGKILL)
            }
        }
    }
}

final class AppInstance {
    private let descriptor: Int32
    init() throws {
        try FileManager.default.createDirectory(at: ProfileStore.root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(ProfileStore.root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ViewflowError.invalid("无法打开应用状态目录") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); throw ViewflowError.invalid("Viewflow 已在运行，请使用已打开的应用")
        }
    }
    deinit { Darwin.close(descriptor) }
}
