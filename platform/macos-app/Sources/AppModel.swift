import AppKit
import Combine

@MainActor final class AppModel: ObservableObject {
    let permissions = Permissions()
    let recall = WindowRecallController()
    let pairing = PairingController()
    private var startAfterPairing = false
    @Published private(set) var profile: ConnectionProfile?
    @Published private(set) var running = false
    @Published var message = ""
    @Published private(set) var statuses: [Component: String] = [:]
    @Published private(set) var enabled: Set<Component> = Set(Component.allCases)
    private var workers: [String: ManagedWorker] = [:]
    private var selected: Set<String> = []
    private var inventoryBusy = false
    private var nativeDragInventory = NativeDragInventory()
    private var identity: [String: Any] = [:]
    private var linkIdentities: [String: [String: Any]] = [:]
    private var pendingRetained: Set<String> = []
    private var pendingClear = false
    private let activityCoordinator = ActivityCoordinator(directory: ProfileStore.root.appendingPathComponent("run/activity"))
    private var timer: Timer?
    private let hid = HIDServer()
    private var hidStarted = false
    private var pendingProfile: ConnectionProfile?
    private var configuredProfile: ConnectionProfile?
    private var displayTopology: DisplayTopology?
    private var refreshTicks = 0
    private var generation = UUID()

    init() {
        if let stored = UserDefaults.standard.stringArray(forKey: "components") {
            enabled = Set(stored.compactMap(Component.init(rawValue:)))
        }
        do {
            let stored = try ProfileStore.load()
            if stored.groupID == nil {
                let archive = ProfileStore.root.appendingPathComponent("legacy/connection-\(UUID().uuidString).json")
                try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: ProfileStore.root.appendingPathComponent("connection.json"), to: archive)
                UserDefaults.standard.set(false, forKey: "running")
                message = "旧版连接已归档。请选择主机或从机，建立唯一连接组。"
            }
            // The pairing service is authoritative; never autostart a cached
            // profile before it has confirmed the local group membership.
        }
        catch { if FileManager.default.fileExists(atPath: ProfileStore.root.appendingPathComponent("connection.json").path) { message = error.localizedDescription } }
        configuredProfile = profile
        pairing.connected = { [weak self] incoming, reason in self?.reconcileGroup(incoming, reason: reason) }
        pairing.start()
        permissions.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func reconcileGroup(_ incoming: ConnectionProfile?, reason: String) {
        guard let incoming else {
            pendingProfile = nil; pendingRetained = []; startAfterPairing = false
            pendingClear = true; stop()
            message = "请选择主机或从机，或等待从机加入当前连接组。"
            return
        }
        if configuredProfile == incoming && pendingProfile == nil {
            if (reason == "joined" || reason == "connected") && !running { start() }
            return
        }
        let shouldStart = running || (reason == "joined" || reason == "connected") || (reason == "restored" && UserDefaults.standard.bool(forKey: "running"))
        let sameGroup = configuredProfile?.groupID == incoming.groupID && incoming.groupID != nil
        let old = Dictionary(uniqueKeysWithValues: (configuredProfile?.groupConnections ?? []).map { ($0.pairingDeviceID!, $0) })
        let preserved = Set((incoming.groupConnections ?? []).filter { old[$0.pairingDeviceID!] == $0 }.compactMap(\.pairingDeviceID))
        pendingRetained = sameGroup ? Set(workers.values.filter { preserved.contains($0.groupPeerID ?? "") && !$0.stopping }.map(\.id)) : []
        if sameGroup, let sharedHID = workers["corehid"], !sharedHID.stopping, enabled.contains(.hid) {
            pendingRetained.insert(sharedHID.id)
        }
        for worker in workers.values where !pendingRetained.contains(worker.id) { worker.stop() }
        if !sameGroup { hid.stop(); hidStarted = false; running = false }
        generation = UUID()
        pendingProfile = incoming; startAfterPairing = shouldStart; pendingClear = false
        message = "正在同步当前连接组。"
    }
    private func prepareIdentities(_ profile: ConnectionProfile) throws {
        linkIdentities = [:]
        for link in profile.groupConnections ?? [profile] {
            let root = profile.groupID.map { ProfileStore.root.appendingPathComponent("groups/\($0)/\(link.pairingDeviceID!)") } ?? ProfileStore.root
            let material = try ProfileStore.identity(link, at: root)
            linkIdentities[link.pairingDeviceID ?? ""] = material
        }
        identity = linkIdentities[profile.pairingDeviceID ?? ""] ?? [:]
    }
    func setEnabled(_ component: Component, _ value: Bool) {
        if value { enabled.insert(component) } else { enabled.remove(component) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "components")
        tick()
    }
    func start() {
        guard pendingProfile == nil else { message = "正在切换配对，请稍候"; return }
        do {
            guard let profile else { message = "请先建立或加入连接组。"; return }
            try prepareIdentities(profile)
            running = true; UserDefaults.standard.set(true, forKey: "running"); tick()
        } catch { message = error.localizedDescription }
    }
    func stop(persist: Bool = true) {
        startAfterPairing = false
        running = false; generation = UUID()
        if persist { UserDefaults.standard.set(false, forKey: "running") }
        for worker in workers.values { worker.stop() }
        hid.stop(); hidStarted = false; selected = []
        nativeDragInventory = NativeDragInventory()
        for component in Component.allCases { statuses[component] = "已停止" }
    }
    var fullyStopped: Bool { hid.isStopped && workers.values.allSatisfy { $0.process == nil } }
    func pollTermination(elapsed: TimeInterval) {
        recall.pollTermination(elapsed: elapsed)
        for worker in workers.values { worker.pollTermination(elapsed: elapsed) }
    }
    func importProfile() {
        message = "请在配对页面选择主机或从机；旧版配对文件不能与连接组同时使用。"
    }
    func importProfile(from url: URL) {
        importProfile()
    }
    private func configuration(_ id: String, fields: [String: Any]) throws -> URL {
        let url = ProfileStore.root.appendingPathComponent("run/\(id).json")
        try ProfileStore.writePrivate(JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), to: url)
        return url
    }
    private func worker(_ id: String, component: Component, binary: String, peerID: String? = nil, arguments: () throws -> [String]) throws {
        if workers[id] == nil {
            let new = try ManagedWorker(id: id, component: component, executable: BundleTools.executable(binary), arguments: arguments())
            new.groupPeerID = peerID
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
        recall.poll()
        activityCoordinator.poll(active: Set(workers.values.filter { $0.desired && $0.process != nil && $0.id.hasPrefix("source-") }.map(\.id)))
        // Reap retired workers before reusing configuration files or identity.
        for (id, worker) in workers where !worker.desired && worker.process == nil { workers.removeValue(forKey: id) }
        if pendingClear && fullyStopped {
            pendingClear = false; profile = nil; configuredProfile = nil; identity = [:]; linkIdentities = [:]
            try? FileManager.default.removeItem(at: ProfileStore.root.appendingPathComponent("connection.json"))
        }
        if let incoming = pendingProfile, workers.values.allSatisfy({ $0.process == nil || pendingRetained.contains($0.id) }) && (running || hid.isStopped) {
            do {
                try ProfileStore.save(incoming)
                profile = incoming; configuredProfile = incoming; displayTopology = nil; pendingProfile = nil; pendingRetained = []
                try prepareIdentities(incoming)
                message = "当前连接组已同步。"
                if startAfterPairing { startAfterPairing = false; start(); return }
            } catch { pendingProfile = nil; message = error.localizedDescription }
        }
        refreshTicks += 1
        if refreshTicks % 100 == 0 { permissions.refresh() }
        guard running, pendingProfile == nil, !pendingClear else { return }
        if configuredProfile?.pairingDeviceID == nil, let topology = DisplayTopology.load(), topology != displayTopology, let configuredProfile {
            let updated = topology.applying(to: configuredProfile)
            generation = UUID() // Discard an inventory completed for the old coordinates.
            if updated.presentationOriginX != profile?.presentationOriginX || updated.presentationOriginY != profile?.presentationOriginY || updated.windowReceivers != profile?.windowReceivers {
                stopComponent(.windowsReceive, reason: "正在更新屏幕布局")
            }
            let parkingIDs = Set(((updated.windowParking.map { [$0] } ?? []) + (updated.windowParkingDisplays ?? [])).map { ($0.serial ?? 1) == 1 ? "window-parking" : "window-parking-\($0.serial ?? 1)" })
            for worker in workers.values where worker.id.hasPrefix("window-parking") && !parkingIDs.contains(worker.id) { worker.stop() }
            for worker in workers.values where worker.id.hasPrefix("source-") && !updated.windowDestinations.contains(where: { worker.id.hasSuffix("-" + $0.id) }) { worker.stop() }
            profile = updated; displayTopology = topology
        }
        for component in Component.allCases {
            if displayTopology?.connected == false && component != .input && component != .hid {
                stopComponent(component, reason: "当前仅连接 Windows"); continue
            }
            guard enabled.contains(component) else { stopComponent(component, reason: "已关闭"); continue }
            if component == .hid {
                if BundleTools.usesCoreHID {
                    guard BundleTools.coreHIDSupported else { statuses[component] = "原生触控板需要 macOS 26 或更新版本"; continue }
                    do {
                        try worker("corehid", component: .hid, binary: "ViewflowHIDReceiver") {
                            ["--serve", "--socket", HIDServer.path, "--status-file", CoreHIDStatus.url.path]
                        }
                        if workers["corehid"]?.process?.isRunning == true {
                            let ready = CoreHIDStatus.read()["native_multitouch_attached"] as? Bool == true
                            statuses[component] = ready ? "原生触控板已就绪，等待输入" : "正在初始化原生触控板"
                        }
                    } catch { statuses[component] = error.localizedDescription }
                    continue
                }
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
                    for link in profile.groupConnections ?? [profile] {
                        let peer = link.pairingDeviceID ?? ""
                        let id = peer.isEmpty ? "input" : "input-" + peer
                        if !permissions.canPostInput && workers[id] == nil { statuses[component] = "等待辅助功能权限"; continue }
                        let material = linkIdentities[peer] ?? identity
                        try worker(id, component: component, binary: "viewflowd", peerID: peer) {
                            ["serve", "--bind", link.inputBind, "--cert", material["certificate"] as! String,
                             "--key", material["private_key"] as! String, "--ca", material["certificate_authority"] as! String,
                             "--input-backend", "native", "--device-id", link.deviceID]
                        }
                    }
                case .windowsReceive:
                    for link in profile.groupConnections ?? [profile] {
                        let peer = link.pairingDeviceID ?? ""
                        let receivers = [ConnectionProfile.WindowReceiver(id: "", bind: link.windowsBind,
                            scale: Int(link.presentationScale), originX: link.presentationOriginX,
                            originY: link.presentationOriginY)] + (link.windowReceivers ?? [])
                        for receiver in receivers {
                            let id = "windows-receive" + (peer.isEmpty ? "" : "-" + peer) + (receiver.id.isEmpty ? "" : "-" + receiver.id)
                            try worker(id, component: component, binary: "vf-window-peer", peerID: peer) {
                                var fields = linkIdentities[peer] ?? identity
                                fields["bind"] = receiver.bind; fields["role"] = "presenter"
                                fields["backend"] = ["native": try BundleTools.executable("viewflow-macos-windows").path,
                                    "args": ["present", "--scale", String(receiver.scale),
                                             "--origin-x", String(receiver.originX), "--origin-y", String(receiver.originY),
                                             "--performance-mode", link.performanceMode]]
                                return ["--config", try configuration(id, fields: fields).path]
                            }
                        }
                    }
                case .clipboard:
                    for link in profile.groupConnections ?? [profile] {
                        let peer = link.pairingDeviceID ?? ""
                        let id = peer.isEmpty ? "clipboard" : "clipboard-" + peer
                        try worker(id, component: component, binary: "vf-clipboard-peer", peerID: peer) {
                            var fields = linkIdentities[peer] ?? identity; fields["bind"] = link.clipboardBind
                            if let remote = link.clipboardRemote { fields["remote"] = remote.address; fields["server_name"] = remote.serverName }
                            return ["--config", try configuration(id, fields: fields).path]
                        }
                    }
                case .windowsShare:
                    guard !profile.windowDestinations.isEmpty else { statuses[component] = "等待连接组成员"; continue }
                    if !permissions.canCapture && selected.isEmpty { statuses[component] = "等待屏幕录制权限"; continue }
                    for link in profile.groupConnections ?? [profile] {
                        for screen in (link.windowParking.map { [$0] } ?? []) + (link.windowParkingDisplays ?? []) {
                            let serial = screen.serial ?? 1
                            let id = serial == 1 ? "window-parking" : "window-parking-\(serial)"
                            try worker(id, component: .windowsShare, binary: "viewflow-macos-windows", peerID: link.pairingDeviceID) {
                                ["--owner-pid", String(ProcessInfo.processInfo.processIdentifier), "--parking-display",
                                 String(screen.width), String(screen.height), String(screen.x), String(screen.y), String(serial)]
                            }
                        }
                    }
                    for worker in workers.values where worker.component == .windowsShare && worker.desired { worker.reconcile() }
                    var sharing = profile
                    if let links = profile.groupConnections {
                        sharing.windowDestinations = links.flatMap(\.windowDestinations)
                        let screens = links.flatMap { ($0.windowParking.map { [$0] } ?? []) + ($0.windowParkingDisplays ?? []) }
                        sharing.windowParking = screens.first; sharing.windowParkingDisplays = Array(screens.dropFirst())
                    }
                    enumerate(sharing)
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
        nativeDragInventory.observe(inventory)
        // Native-decoration streams include their owned popup windows. Creating
        // another menu stream duplicates the same menu and its input target.
        let live = try inventory.selected(existing: selected, limit: profile.maxWindows).filter { $0.layer == 0 }
        selected = Set(live.map(\.key))
        let parkingIDs = Set(((profile.windowParking.map { [$0] } ?? []) + (profile.windowParkingDisplays ?? [])).map {
            ($0.serial ?? 1) == 1 ? "window-parking" : "window-parking-\($0.serial ?? 1)"
        })
        let desiredIDs = parkingIDs.union(live.flatMap { window in profile.windowDestinations.filter { $0.accepts(window) }.map { "source-\(window.key)-\($0.id)" } })
        for (id, worker) in workers where worker.component == .windowsShare && !desiredIDs.contains(id) { worker.stop() }
        // Include retiring processes in the worker budget; never oversubscribe
        // the capture pool while an old stream is still releasing resources.
        for window in live {
            for peer in profile.windowDestinations where peer.accepts(window) {
                let id = "source-\(window.key)-\(peer.id)"
                if workers[id] == nil && workers.values.filter({ $0.component == .windowsShare && $0.id.hasPrefix("source-") }).count >= (profile.maxWindows + 8) * profile.windowDestinations.count { continue }
                try worker(id, component: .windowsShare, binary: "vf-window-peer", peerID: peer.id) {
                    var fields = linkIdentities[peer.id] ?? identity
                    fields["bind"] = peer.address.hasPrefix("[") ? "[::]:0" : "0.0.0.0:0"
                    fields["remote"] = peer.address; fields["server_name"] = peer.serverName; fields["role"] = "source"
                    var sourceArgs = ["source", "--window", String(window.windowID), "--scale", String(peer.id == "linux" ? max(2, peer.captureScale) : peer.captureScale),
                                 "--fps", String(profile.frameRate), "--codec", peer.codec ?? "h264",
                                 "--performance-mode", profile.performanceMode,
                                 "--native-decorations", "1",
                                 "--activity-coordinator", try activityCoordinator.reportPath(id)]
                    if let grab = nativeDragInventory.grabs[window.key] {
                        let seed = ProfileStore.root.appendingPathComponent("run/\(id)-drag.json")
                        try ProfileStore.writePrivate(JSONSerialization.data(withJSONObject: ["grab_x": grab[0], "grab_y": grab[1]]), to: seed)
                        sourceArgs += ["--native-drag-seed", seed.path]
                    }
                    fields["backend"] = ["native": try BundleTools.captureExecutable(for: id).path, "args": sourceArgs]
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
