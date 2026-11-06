import Foundation
import CoreGraphics
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ViewflowError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum Component: String, Codable, CaseIterable, Identifiable {
    case input, windowsReceive, windowsShare, clipboard, hid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .input: return "鼠标与键盘"
        case .windowsReceive: return "接收其他电脑的窗口"
        case .windowsShare: return "共享这台 Mac 的窗口"
        case .clipboard: return "剪贴板同步"
        case .hid: return "触控板 HID 转发"
        }
    }
    var symbol: String {
        switch self {
        case .input: return "keyboard"
        case .windowsReceive: return "rectangle.on.rectangle"
        case .windowsShare: return "macwindow"
        case .clipboard: return "doc.on.clipboard"
        case .hid: return "hand.draw"
        }
    }
}

// A connection file contains pairing material, not commands or executable paths.
// All runtime programs are selected by the application from its signed bundle.
struct ConnectionProfile: Codable, Equatable {
    var version = 1
    var name: String
    var deviceID: String
    var pairingDeviceID: String?
    var groupID: String?
    var groupRole: String?
    var groupHostID: String?
    var groupConnections: [ConnectionProfile]?
    var certificatePEM: String
    var privateKeyPEM: String
    var authorityPEM: String
    var desktopHandoffNotice: String?
    var desktopHandoff: DesktopHandoff?
    struct DesktopHandoff: Codable, Equatable {
        struct Rect: Codable, Equatable { var x: Int; var y: Int; var width: Int; var height: Int }
        var bind: String
        var remote: String
        var server_name: String
        var device_id: String
        var peer_id: String
        var local: Rect
        var peer: Rect
        var sender: Bool
        var receiver: Bool
    }
    var inputBind = "0.0.0.0:44139"
    var windowsBind = "0.0.0.0:44220"
    var clipboardBind = "0.0.0.0:44141"
    var windowDestinations: [WindowDestination] = []
    var clipboardRemote: Endpoint?
    var windowParking: WindowParking?
    var windowParkingDisplays: [WindowParking]?
    // Each source desktop has its own coordinate origin. Older pairing files
    // retain the primary receiver; extra listeners are optional.
    var windowReceivers: [WindowReceiver]?
    struct WindowReceiver: Codable, Equatable {
        var id: String
        var bind: String
        var scale: Int
        var originX: Int
        var originY: Int
    }
    struct WindowParking: Codable, Equatable {
        var serial: UInt32?
        var width: Int
        var height: Int
        var x: Int
        var y: Int
    }
    var presentationScale = 1.0
    var presentationOriginX = 0
    var presentationOriginY = 0
    var frameRate = 60
    var maxWindows = 8
    var performanceMode = "frame-rate"
    // Optional keys keep older pairing files decodable with the default on.
    var transparency: Bool?
    var hidForwarding: Bool?
    var transparencyEnabled: Bool { transparency ?? true }
    var hidForwardingEnabled: Bool { hidForwarding ?? true }
    var desktopInputEnvironment: [String: String] {
        ["VIEWFLOW_DESKTOP_HID": hidForwardingEnabled ? "1" : "0"]
    }

    static let qualityModes = ["auto", "high_quality", "save_bandwidth"]

    static func presentationEnvironment(transparency: Bool, qualityMode: String = "auto") -> [String: String] {
        var environment = ["VIEWFLOW_TRANSPARENCY": transparency ? "1" : "0"]
        // Unset means auto, so older window sources keep their defaults.
        if qualityMode != "auto" && qualityModes.contains(qualityMode) {
            environment["VIEWFLOW_QUALITY_MODE"] = qualityMode
        }
        return environment
    }

    struct Endpoint: Codable, Equatable {
        var address: String
        var serverName: String
    }
    struct WindowDestination: Codable, Equatable, Identifiable {
        var id: String
        var address: String
        var serverName: String
        var captureScale = 2
        var codec: String?
        var viewport: WindowParking?
        func accepts(_ window: NativeWindow, existing: Bool = false) -> Bool {
            if existing { return true } // Visibility never withdraws an established stream.
            guard let viewport else { return true }
            guard window.framePoints.count == 4 else { return false }
            let frame = CGRect(x: window.framePoints[0], y: window.framePoints[1], width: window.framePoints[2], height: window.framePoints[3])
            let target = CGRect(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height)
            let hit = frame.intersection(target)
            return !hit.isNull && hit.width > 0 && hit.height > 0
        }
    }

    func validate() throws {
        if let groupID {
            let validID: (String) -> Bool = { $0.count == 32 && $0.allSatisfy({ $0.isASCII && $0.isHexDigit }) }
            guard validID(groupID), ["host", "client"].contains(groupRole ?? ""),
                  validID(groupHostID ?? ""), let links = groupConnections, (1...2).contains(links.count),
                  Set(links.compactMap(\.pairingDeviceID)).count == links.count,
                  links.allSatisfy({ $0.groupConnections == nil && $0.groupID == nil && $0.deviceID == deviceID && validID($0.pairingDeviceID ?? "") }),
                  (groupRole == "host" ? groupHostID == deviceID : (links.count == 1 && links[0].pairingDeviceID == groupHostID)) else {
                throw ViewflowError.invalid("连接组必须包含一台主机和最多两台从机")
            }
            let binds = links.flatMap { [$0.inputBind, $0.windowsBind, $0.clipboardBind] + ($0.desktopHandoff.map { [$0.bind] } ?? []) }
            guard Set(binds).count == binds.count else { throw ViewflowError.invalid("连接组成员监听地址重复") }
            let parking = links.flatMap { ($0.windowParking.map { [$0] } ?? []) + ($0.windowParkingDisplays ?? []) }.map { $0.serial ?? 1 }
            guard Set(parking).count == parking.count else { throw ViewflowError.invalid("连接组成员显示器标识重复") }
            for link in links { try link.validate() }
        } else if groupConnections != nil {
            throw ViewflowError.invalid("连接记录不属于任何连接组")
        }
        guard version == 1 else { throw ViewflowError.invalid("不支持的配对文件版本") }
        guard !name.isEmpty, name.count <= 120 else { throw ViewflowError.invalid("配对名称无效") }
        guard deviceID.count == 32, deviceID.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw ViewflowError.invalid("设备标识必须是 32 位十六进制字符")
        }
        guard certificatePEM.contains("-----BEGIN CERTIFICATE-----"),
              authorityPEM.contains("-----BEGIN CERTIFICATE-----"),
              privateKeyPEM.contains("PRIVATE KEY-----"),
              [certificatePEM, authorityPEM, privateKeyPEM].allSatisfy({ $0.utf8.count < 65_536 }) else {
            throw ViewflowError.invalid("配对文件缺少证书或私钥")
        }
        for address in [inputBind, windowsBind, clipboardBind] { try Self.validateAddress(address) }
        guard Set([inputBind, windowsBind, clipboardBind]).count == 3 else {
            throw ViewflowError.invalid("输入、窗口和剪贴板必须使用不同监听地址")
        }
        guard (1...4).contains(presentationScale), presentationScale.rounded() == presentationScale,
              (1...120).contains(frameRate), (1...32).contains(maxWindows),
              ["frame-rate", "latency"].contains(performanceMode),
              (-1_000_000...1_000_000).contains(presentationOriginX),
              (-1_000_000...1_000_000).contains(presentationOriginY) else {
            throw ViewflowError.invalid("窗口显示参数超出支持范围")
        }
        guard windowDestinations.count <= 8,
              Set(windowDestinations.map(\.id)).count == windowDestinations.count else {
            throw ViewflowError.invalid("窗口接收端重复或超过 8 台")
        }
        for peer in windowDestinations {
            guard !peer.id.isEmpty, peer.id.count < 80,
                  peer.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  !peer.serverName.isEmpty, (1...4).contains(peer.captureScale),
                  ["h264", "hevc"].contains(peer.codec ?? "h264") else {
                throw ViewflowError.invalid("窗口接收端配置无效")
            }
            try Self.validateAddress(peer.address)
            if let viewport = peer.viewport {
                guard viewport.width > 0, viewport.height > 0 else { throw ViewflowError.invalid("窗口目标区域无效") }
            }
        }
        var receiverBinds = Set([inputBind, windowsBind, clipboardBind])
        if let handoff = desktopHandoff {
            try Self.validateAddress(handoff.bind); try Self.validateAddress(handoff.remote)
            guard receiverBinds.insert(handoff.bind).inserted,
                  handoff.device_id == deviceID, handoff.peer_id == pairingDeviceID,
                  handoff.server_name == "vf-" + handoff.peer_id + ".local",
                  handoff.local.width >= 2, handoff.local.height >= 2,
                  handoff.peer.width >= 2, handoff.peer.height >= 2 else {
                throw ViewflowError.invalid("桌面光标接管配置无效")
            }
        }
        var receiverIDs = Set<String>()
        for receiver in windowReceivers ?? [] {
            guard !receiver.id.isEmpty, receiver.id.count <= 32,
                  receiver.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  receiverIDs.insert(receiver.id).inserted,
                  receiverBinds.insert(receiver.bind).inserted,
                  (1...4).contains(receiver.scale),
                  (-1_000_000...1_000_000).contains(receiver.originX),
                  (-1_000_000...1_000_000).contains(receiver.originY) else {
                throw ViewflowError.invalid("窗口接收端标识、监听地址或坐标无效")
            }
            try Self.validateAddress(receiver.bind)
        }
        var parkingIDs = Set<UInt32>()
        for screen in (windowParking.map { [$0] } ?? []) + (windowParkingDisplays ?? []) {
            guard parkingIDs.insert(screen.serial ?? 1).inserted, (screen.serial ?? 1) > 0 else {
                throw ViewflowError.invalid("远程显示器标识重复或无效")
            }
            guard (64...8192).contains(screen.width), (64...8192).contains(screen.height),
                  (-100_000...100_000).contains(screen.x), (-100_000...100_000).contains(screen.y) else {
                throw ViewflowError.invalid("远程窗口显示区域超出支持范围")
            }
        }
        if let peer = clipboardRemote {
            try Self.validateAddress(peer.address)
            guard !peer.serverName.isEmpty else { throw ViewflowError.invalid("剪贴板接收端缺少 TLS 名称") }
        }
    }

    static func validateAddress(_ address: String) throws {
        guard let split = address.lastIndex(of: ":"), !address[..<split].isEmpty,
              let port = UInt16(address[address.index(after: split)...]), port > 0,
              !address.contains(where: { $0.isWhitespace }) else {
            throw ViewflowError.invalid("连接地址无效：\(address)")
        }
        // The existing Rust peers accept SocketAddr, so keep DNS resolution out
        // of their configuration. Bracketed IPv6 and IPv4 are supported.
        let host = String(address[..<split])
        var v4 = in_addr(), v6 = in6_addr()
        let valid: Bool
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let parts = host.dropFirst().dropLast().split(separator: "%", omittingEmptySubsequences: false)
            let scopeValid = parts.count == 1 || (parts.count == 2 && UInt32(parts[1]) != nil)
            valid = scopeValid && String(parts[0]).withCString { inet_pton(AF_INET6, $0, &v6) } == 1
        } else {
            valid = host.withCString { inet_pton(AF_INET, $0, &v4) } == 1
        }
        guard valid else { throw ViewflowError.invalid("请使用有效 IPv4 地址或带方括号的 IPv6 地址") }
    }
}

struct NativeWindow: Decodable, Equatable {
    let windowID: UInt32
    let pid: Int32
    let bundleID: String
    let applicationName: String
    let executableName: String
    let onScreen: Bool
    let layer: Int
    let framePoints: [Double]
    var key: String { "\(windowID)-\(pid)" }
    enum CodingKeys: String, CodingKey {
        case windowID = "window_id", pid, bundleID = "bundle_id", applicationName = "application_name"
        case executableName = "executable_name", onScreen = "on_screen", layer, framePoints = "frame_points"
    }
    var eligible: Bool {
        onScreen && (layer == 0 || layer == 101) && windowID > 0 && pid > 0 &&
        !bundleID.hasPrefix("org.viewflow.") &&
        !applicationName.hasPrefix("viewflow-macos-windows") &&
        !executableName.hasPrefix("viewflow-macos-windows") &&
        framePoints.count == 4 && framePoints.allSatisfy(\.isFinite) &&
        framePoints[2] > 0 && framePoints[3] > 0
    }
}

struct WindowInventory: Decodable {
    var schemaVersion: Int
    var enumeration: String
    var windows: [NativeWindow]?
    var pointerPoints: [Double]? = nil
    var leftButtonDown: Bool? = nil
    var physicalDisplays: [[Double]]? = nil
    var remoteDisplays: [[Double]]? = nil
    var spaceAnimating: Bool? = nil
    var displaySpaces: [String: UInt64]? = nil
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", enumeration, windows
        case pointerPoints = "pointer_points", leftButtonDown = "left_button_down"
        case physicalDisplays = "physical_displays", remoteDisplays = "remote_displays"
        case spaceAnimating = "space_animating", displaySpaces = "display_spaces"
    }
    // Match native capture and destination selection: a positive-area crossing
    // starts sharing, after subtracting the physical display union.
    func needsRemote(_ window: NativeWindow) -> Bool {
        guard let physicalDisplays, let remoteDisplays else { return false }
        func rect(_ values: [Double]) -> CGRect? {
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        guard let frame = rect(window.framePoints) else { return false }
        for remote in remoteDisplays.compactMap(rect) {
            let hit = frame.intersection(remote)
            if hit.isNull || hit.width <= 0 || hit.height <= 0 { continue }
            var uncovered = [hit]
            for display in physicalDisplays.compactMap(rect) {
                uncovered = uncovered.flatMap { part -> [CGRect] in
                    let covered = part.intersection(display)
                    if covered.isNull || covered.width <= 0 || covered.height <= 0 { return [part] }
                    return [CGRect(x: part.minX, y: part.minY, width: part.width, height: covered.minY-part.minY),
                            CGRect(x: part.minX, y: covered.maxY, width: part.width, height: part.maxY-covered.maxY),
                            CGRect(x: part.minX, y: covered.minY, width: covered.minX-part.minX, height: covered.height),
                            CGRect(x: covered.maxX, y: covered.minY, width: part.maxX-covered.maxX, height: covered.height)]
                        .filter { $0.width > 0 && $0.height > 0 }
                }
            }
            if !uncovered.isEmpty { return true }
        }
        return false
    }
    func selected(existing: Set<String>, limit: Int) throws -> [NativeWindow] {
        guard schemaVersion == 1, enumeration == "ok" else {
            throw ViewflowError.invalid("窗口列表暂不可用：\(enumeration)")
        }
        guard let physicalDisplays, let remoteDisplays,
              (physicalDisplays + remoteDisplays).allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) && $0[2] > 0 && $0[3] > 0 }) else {
            throw ViewflowError.invalid("显示器布局暂不可用，保留当前窗口连接")
        }
        guard let windows else { throw ViewflowError.invalid("窗口列表暂不可用，保留当前窗口连接") }
        let candidates = windows.filter { ($0.layer == 0 && existing.contains($0.key)) || ($0.eligible && needsRemote($0)) }
        let normal = Array(candidates.filter { $0.layer == 0 }.sorted {
            let a = existing.contains($0.key), b = existing.contains($1.key)
            return a != b ? a : ($0.windowID, $0.pid) < ($1.windowID, $1.pid)
        }.prefix(limit))
        // Finder context menus are separate CG popup-menu windows (level 101).
        // Reserve a transient budget so opening a menu never evicts its parent.
        let owners = Set(normal.map(\.pid))
        let menus = candidates.filter { $0.layer == 101 && owners.contains($0.pid) }
        return normal + menus.prefix(8)
    }
}

struct RestartPolicy {
    private(set) var failures = 0
    mutating func failed() -> TimeInterval {
        failures = min(failures + 1, 6)
        return min(pow(2, Double(failures - 1)), 30)
    }
    mutating func stableRun() { failures = 0 }
}

enum ProfileStore {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Viewflow", isDirectory: true)
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func load(at root: URL = root) throws -> ConnectionProfile {
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(contentsOf: root.appendingPathComponent("connection.json")))
        try profile.validate()
        return profile
    }
    static func save(_ profile: ConnectionProfile, at root: URL = root) throws {
        try profile.validate()
        try writePrivate(JSONEncoder().encode(profile), to: root.appendingPathComponent("connection.json"))
    }
    static func identity(_ profile: ConnectionProfile, at root: URL = root) throws -> [String: Any] {
        let names = [("certificate", "device.pem", profile.certificatePEM),
                     ("private_key", "device.key", profile.privateKeyPEM),
                     ("certificate_authority", "ca.pem", profile.authorityPEM)]
        var fields: [String: Any] = [:]
        for (field, name, value) in names {
            let url = root.appendingPathComponent("identity/\(name)")
            try writePrivate(Data(value.utf8), to: url)
            fields[field] = url.path
        }
        return fields
    }
}

// Metadata observer shared by all source launches. A source often starts after
// HID routing released the Mac button, so it cannot reconstruct this itself.
struct NativeDragInventory {
    private var previous: WindowInventory?
    private(set) var grabs: [String: [Int]] = [:]
    mutating func observe(_ inventory: WindowInventory) {
        defer { previous = inventory }
        guard let pointer = inventory.pointerPoints, pointer.count == 2,
              pointer.allSatisfy(\.isFinite), let held = inventory.leftButtonDown else { return }
        if held && previous?.leftButtonDown != true { grabs.removeAll() }
        if !held && previous?.leftButtonDown != true { grabs.removeAll() }
        guard let previous else { return }
        let old = Dictionary(uniqueKeysWithValues: (previous.windows ?? []).map { ($0.key, $0) })
        for window in inventory.windows ?? [] where window.eligible && window.layer == 0 {
            guard let before = old[window.key], before.framePoints.count == 4,
                  before.framePoints[2] == window.framePoints[2], before.framePoints[3] == window.framePoints[3],
                  before.framePoints[0] != window.framePoints[0] || before.framePoints[1] != window.framePoints[1],
                  held || previous.leftButtonDown == true else { continue }
            if grabs[window.key] != nil { continue }
            let point = held ? pointer : (previous.pointerPoints ?? pointer)
            let frame = held ? window.framePoints : before.framePoints
            guard point.count == 2 else { continue }
            grabs[window.key] = [Int((point[0] - frame[0]).rounded()), Int((point[1] - frame[1]).rounded())]
        }
    }
}

// Same admission policy as window_space_transition.hpp. Samples are the existing
// discovery inventory; no gesture interception or additional polling loop.
struct SpaceTransitionGate {
    private var previous: [String: NativeWindow] = [:]
    private var spaces: [String: UInt64] = [:]
    private var until: Double = 0
    mutating func spaceChanged(now: Double) { until = now + 0.25 }
    mutating func observe(_ inventory: WindowInventory, now: Double) -> Bool {
        let current = inventory.displaySpaces ?? [:]
        let changed = current.contains { key, value in
            value != 0 && spaces[key] != nil && spaces[key] != 0 && spaces[key] != value
        }
        spaces = current
        let windows = (inventory.windows ?? []).filter { $0.eligible && $0.layer == 0 }
        func display(_ w: NativeWindow) -> Int? {
            let f = w.framePoints
            return (inventory.physicalDisplays ?? []).firstIndex { d in
                d.count == 4 && f[0] < d[0]+d[2] && f[0]+f[2] > d[0] &&
                f[1] < d[1]+d[3] && f[1]+f[3] > d[1]
            }
        }
        var motions: [(Int, Double)] = []
        for w in windows {
            guard let p = previous[w.key], let d = display(w), display(p) == d else { continue }
            let a = w.framePoints, b = p.framePoints, dx = a[0]-b[0]
            if abs(dx) >= 2 && abs(a[1]-b[1]) <= 2 && abs(a[2]-b[2]) <= 2 && abs(a[3]-b[3]) <= 2 {
                motions.append((d, dx))
            }
        }
        let coherent = motions.contains { m in
            motions.filter { $0.0 == m.0 && abs($0.1-m.1) <= 2 }.count >= 3
        }
        previous = Dictionary(windows.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        if inventory.spaceAnimating == true || changed || coherent { until = now + 0.25 }
        return now < until
    }
}
