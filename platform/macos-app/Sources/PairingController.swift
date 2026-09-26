import AppKit
import Combine

struct NearbyMachine: Decodable, Identifiable {
    var id: String
    var name: String
    var platform: String
    var address: String
    var paired: Bool
    var online: Bool
    var count: Int
}

struct GroupMember: Decodable, Identifiable {
    var id: String
    var name: String
    var platform: String
    var role: String
    var local: Bool
    var address: String?
    var online: Bool
}

struct GroupDisplay: Decodable, Identifiable {
    var id: String
    var name: String
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var host: Bool
}

@MainActor final class PairingController: ObservableObject {
    @Published var displays: [GroupDisplay] = []
    @Published var machines: [NearbyMachine] = []
    @Published var code = ""
    @Published var addresses: [String] = []
    @Published var name = ""
    @Published var warning = ""
    @Published var paused = false
    @Published var busy = false
    @Published var role = ""
    @Published var groupID = ""
    @Published var members: [GroupMember] = []
    var connected: ((ConnectionProfile?, String) -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var stopping = false

    func start() {
        guard process == nil, !stopping else { return }
        do {
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = try BundleTools.executable("viewflow-pairing")
            let screen = NSScreen.main
            let size = screen?.frame.size ?? NSSize(width: 1920, height: 1080)
            let scale = screen?.backingScaleFactor ?? 1
            child.arguments = ["--directory", ProfileStore.root.appendingPathComponent("pairing").path,
                "--width", String(Int(size.width * scale)), "--height", String(Int(size.height * scale)),
                "--scale", String(Double(scale))]
            child.standardInput = stdin; child.standardOutput = stdout
            child.standardError = FileHandle.nullDevice
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor [weak self] in self?.consume(data) }
            }
            child.terminationHandler = { [weak self] child in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.process = nil; self.busy = false
                    if !self.stopping { self.warning = "设备发现服务已停止，可重试。" }
                }
            }
            try child.run()
            input = stdin; output = stdout; process = child; warning = ""
        } catch { warning = error.localizedDescription }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 1024 * 1024 else { buffer.removeAll(); warning = "设备发现服务返回了无效数据"; return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            do {
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                switch value["type"] as? String {
                case "state":
                    displays = try JSONDecoder().decode([GroupDisplay].self, from: JSONSerialization.data(withJSONObject: value["displays"] ?? []))
                    machines = try JSONDecoder().decode([NearbyMachine].self, from: JSONSerialization.data(withJSONObject: value["machines"] ?? []))
                    code = value["code"] as? String ?? ""; name = value["name"] as? String ?? ""
                    addresses = value["addresses"] as? [String] ?? []
                    warning = value["warning"] as? String ?? ""; busy = value["busy"] as? Bool ?? false
                    paused = value["paused"] as? Bool ?? false
                    role = value["role"] as? String ?? ""; groupID = value["groupID"] as? String ?? ""
                    members = try JSONDecoder().decode([GroupMember].self, from: JSONSerialization.data(withJSONObject: value["members"] ?? []))
                case "group":
                    var profile: ConnectionProfile?
                    if let object = value["profile"] as? [String: Any] {
                        profile = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: object))
                        try profile?.validate()
                    }
                    connected?(profile, value["reason"] as? String ?? "updated")
                case "error": warning = value["message"] as? String ?? "连接失败"
                default: break
                }
            } catch { warning = error.localizedDescription }
        }
    }

    func send(_ action: String, address: String = "", code: String = "", id: String = "", role: String = "", x: Int = 0, y: Int = 0) {
        if process == nil { start() }
        do {
            var data = try JSONSerialization.data(withJSONObject: ["action": action, "address": address, "code": code, "id": id, "role": role, "x": x, "y": y])
            data.append(10)
            try input?.fileHandleForWriting.write(contentsOf: data)
        } catch { warning = error.localizedDescription }
    }

    func stop() {
        stopping = true
        try? input?.fileHandleForWriting.close()
        process?.terminate()
        output?.fileHandleForReading.readabilityHandler = nil
    }
}
