import AppKit
import Combine

@MainActor final class AppModel: ObservableObject {
    let permissions = Permissions()
    @Published private(set) var profile: ConnectionProfile?
    @Published private(set) var running = false
    @Published var message = ""
    @Published private(set) var statuses: [Component: String] = [:]
    @Published private(set) var enabled: Set<Component> = Set(Component.allCases)
    private var workers: [String: ManagedWorker] = [:]
    private var selected: Set<String> = []
    private var inventoryBusy = false
    private var identity: [String: Any] = [:]
    private var timer: Timer?
    private let hid = HIDServer()
    private var hidStarted = false
    private var pendingProfile: ConnectionProfile?
    private var refreshTicks = 0
    private var generation = UUID()

    init() {
        if let stored = UserDefaults.standard.stringArray(forKey: "components") {
            enabled = Set(stored.compactMap(Component.init(rawValue:)))
        }
        do { profile = try ProfileStore.load() }
        catch { if FileManager.default.fileExists(atPath: ProfileStore.root.appendingPathComponent("connection.json").path) { message = error.localizedDescription } }
        permissions.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if UserDefaults.standard.bool(forKey: "running") { start() }
    }
    func setEnabled(_ component: Component, _ value: Bool) {
        if value { enabled.insert(component) } else { enabled.remove(component) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "components")
        tick()
    }
    func start() {
        guard pendingProfile == nil else { message = "正在切换配对，请稍候"; return }
        do {
            if let profile { identity = try ProfileStore.identity(profile) }
            running = true; UserDefaults.standard.set(true, forKey: "running"); tick()
        } catch { message = error.localizedDescription }
    }
    func stop(persist: Bool = true) {
        running = false; generation = UUID()
        if persist { UserDefaults.standard.set(false, forKey: "running") }
        for worker in workers.values { worker.stop() }
        hid.stop(); hidStarted = false; selected = []
        for component in Component.allCases { statuses[component] = "已停止" }
    }
    var fullyStopped: Bool { hid.isStopped && workers.values.allSatisfy { $0.process == nil } }
    func pollTermination(elapsed: TimeInterval) {
        for worker in workers.values { worker.pollTermination(elapsed: elapsed) }
    }
    func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "导入 Viewflow 配对文件"; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importProfile(from: url)
    }
    func importProfile(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 512 * 1024 else { throw ViewflowError.invalid("配对文件过大") }
            let incoming = try JSONDecoder().decode(ConnectionProfile.self, from: data)
            try incoming.validate()
            stop(); pendingProfile = incoming
            message = "正在结束旧连接并保存新配对"; tick()
        } catch { message = error.localizedDescription }
    }
    private func configuration(_ id: String, fields: [String: Any]) throws -> URL {
        let url = ProfileStore.root.appendingPathComponent("run/\(id).json")
        try ProfileStore.writePrivate(JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), to: url)
        return url
    }
    private func worker(_ id: String, component: Component, binary: String, arguments: () throws -> [String]) throws {
        if workers[id] == nil {
            let new = try ManagedWorker(id: id, component: component, executable: BundleTools.executable(binary), arguments: arguments())
            new.changed = { [weak self] in self?.objectWillChange.send() }
            workers[id] = new
        }
        guard let worker = workers[id], !worker.stopping else { return }
        worker.desired = true; worker.reconcile()
        statuses[component] = worker.status
    }
    private func stopComponent(_ component: Component, reason: String) {
        for worker in workers.values where worker.component == component { worker.stop() }
        if component == .hid { hid.stop(); hidStarted = false }
        if component == .windowsShare { selected = [] }
        statuses[component] = reason
    }
    private func tick() {
        // Reap retired workers before reusing configuration files or identity.
        for (id, worker) in workers where !worker.desired && worker.process == nil { workers.removeValue(forKey: id) }
        if let incoming = pendingProfile, fullyStopped {
            do {
                try ProfileStore.save(incoming)
                profile = incoming; pendingProfile = nil; identity = [:]
                message = "已保存配对：\(incoming.name)。点击启动即可连接。"
            } catch { pendingProfile = nil; message = error.localizedDescription }
        }
        refreshTicks += 1
        if refreshTicks % 100 == 0 { permissions.refresh() }
        guard running else { return }
        for component in Component.allCases {
            guard enabled.contains(component) else { stopComponent(component, reason: "已关闭"); continue }
            if component == .hid {
                // Once running, a failed diagnostic must not sever HID input.
                if !hidStarted {
                    guard permissions.driverAttached else { statuses[component] = "等待 HID 驱动就绪"; continue }
                    do { try hid.start(); hidStarted = true } catch { statuses[component] = error.localizedDescription; continue }
                }
                statuses[component] = "正在运行，等待触控板连接"; continue
            }
            guard let profile else { statuses[component] = "请先导入配对文件"; continue }
            do {
                switch component {
                case .input:
                    if !permissions.canPostInput && workers["input"] == nil { statuses[component] = "等待辅助功能权限"; continue }
                    try worker("input", component: component, binary: "viewflowd") {
                        ["serve", "--bind", profile.inputBind, "--cert", identity["certificate"] as! String,
                         "--key", identity["private_key"] as! String, "--ca", identity["certificate_authority"] as! String,
                         "--input-backend", "native", "--device-id", profile.deviceID]
                    }
                case .windowsReceive:
                    try worker("windows-receive", component: component, binary: "vf-window-peer") {
                        var fields = identity; fields["bind"] = profile.windowsBind; fields["role"] = "presenter"
                        fields["backend"] = ["native": try BundleTools.executable("viewflow-macos-windows").path,
                            "args": ["present", "--scale", String(Int(profile.presentationScale)),
                                     "--origin-x", String(profile.presentationOriginX), "--origin-y", String(profile.presentationOriginY),
                                     "--performance-mode", profile.performanceMode]]
                        return ["--config", try configuration("windows-receive", fields: fields).path]
                    }
                case .clipboard:
                    try worker("clipboard", component: component, binary: "vf-clipboard-peer") {
                        var fields = identity; fields["bind"] = profile.clipboardBind
                        if let remote = profile.clipboardRemote { fields["remote"] = remote.address; fields["server_name"] = remote.serverName }
                        return ["--config", try configuration("clipboard", fields: fields).path]
                    }
                case .windowsShare:
                    guard !profile.windowDestinations.isEmpty else { statuses[component] = "配对文件未设置窗口接收端"; continue }
                    if !permissions.canCapture && selected.isEmpty { statuses[component] = "等待屏幕录制权限"; continue }
                    if let screen = profile.windowParking {
                        try worker("window-parking", component: .windowsShare, binary: "viewflow-macos-windows") {
                            ["--owner-pid", String(ProcessInfo.processInfo.processIdentifier), "--parking-display",
                             String(screen.width), String(screen.height), String(screen.x), String(screen.y)]
                        }
                    }
                    for worker in workers.values where worker.component == .windowsShare && worker.desired { worker.reconcile() }
                    enumerate(profile)
                case .hid: break
                }
            } catch { statuses[component] = error.localizedDescription }
        }
    }
    private func enumerate(_ profile: ConnectionProfile) {
        guard !inventoryBusy else { return }
        inventoryBusy = true; let token = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                let json = try NativeProbe.json(BundleTools.executable("viewflow-macos-windows"), ["--list-windows"])
                return try JSONDecoder().decode(WindowInventory.self, from: JSONSerialization.data(withJSONObject: json))
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.inventoryBusy = false
                guard self.running, self.enabled.contains(.windowsShare), token == self.generation else { return }
                do { try self.updateWindows(result.get(), profile) }
                catch { self.statuses[.windowsShare] = "窗口列表暂不可用，保留当前连接：\(error.localizedDescription)" }
            }
        }
    }
    private func updateWindows(_ inventory: WindowInventory, _ profile: ConnectionProfile) throws {
        let live = try inventory.selected(existing: selected, limit: profile.maxWindows)
        selected = Set(live.map(\.key))
        let desiredIDs = Set(["window-parking"]).union(live.flatMap { window in profile.windowDestinations.filter { window.layer != 101 || $0.id != "linux" }.map { "source-\(window.key)-\($0.id)" } })
        for (id, worker) in workers where worker.component == .windowsShare && !desiredIDs.contains(id) { worker.stop() }
        // Include retiring processes in the worker budget; never oversubscribe
        // the capture pool while an old stream is still releasing resources.
        for window in live {
            for peer in profile.windowDestinations {
                if window.layer == 101 && peer.id == "linux" { continue }
                let id = "source-\(window.key)-\(peer.id)"
                if workers[id] == nil && workers.values.filter({ $0.component == .windowsShare && $0.id.hasPrefix("source-") }).count >= (profile.maxWindows + 8) * profile.windowDestinations.count { continue }
                try worker(id, component: .windowsShare, binary: "vf-window-peer") {
                    var fields = identity
                    fields["bind"] = peer.address.hasPrefix("[") ? "[::]:0" : "0.0.0.0:0"
                    fields["remote"] = peer.address; fields["server_name"] = peer.serverName; fields["role"] = "source"
                    fields["backend"] = ["native": try BundleTools.captureExecutable(for: id).path,
                        "args": ["source", "--window", String(window.windowID), "--scale", String(peer.id == "linux" ? max(2, peer.captureScale) : peer.captureScale),
                                 "--fps", String(profile.frameRate), "--codec", peer.codec ?? "h264",
                                 "--performance-mode", profile.performanceMode,
                                 "--native-decorations", peer.id == "linux" ? "1" : "0"]]
                    return ["--config", try configuration(id, fields: fields).path]
                }
            }
        }
        let count = workers.values.filter { $0.component == .windowsShare && $0.id.hasPrefix("source-") && $0.process != nil && !$0.stopping }.count
        statuses[.windowsShare] = count == 0 ? "等待可共享窗口" : "正在运行：\(count) 个窗口流"
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Viewflow-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Deliberately excludes identity material, user window names and content.
            let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()),
                "application": Bundle.main.bundleURL.path, "development_build": BundleTools.developmentBuild,
                "running": running, "paired": profile != nil,
                "permissions": ["screen": permissions.screen, "accessibility": permissions.accessibility,
                                "driver_attached": permissions.driverAttached],
                "components": Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.rawValue, $0.value) }),
                "workers": workers.values.map { ["id": $0.id, "status": $0.status,
                    "pid": $0.process?.processIdentifier ?? 0, "last_exit": $0.lastExit ?? 0] as [String: Any] }]
            try ProfileStore.writePrivate(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), to: url)
            message = "诊断报告已导出"
        } catch { message = error.localizedDescription }
    }
}
