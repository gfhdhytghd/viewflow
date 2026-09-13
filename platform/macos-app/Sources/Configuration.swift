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
        case .hid: return "原生触控板 HID"
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
    var certificatePEM: String
    var privateKeyPEM: String
    var authorityPEM: String
    var inputBind = "0.0.0.0:44139"
    var windowsBind = "0.0.0.0:44220"
    var clipboardBind = "0.0.0.0:44141"
    var windowDestinations: [WindowDestination] = []
    var clipboardRemote: Endpoint?
    var windowParking: WindowParking?
    struct WindowParking: Codable, Equatable {
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
    }

    func validate() throws {
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
        }
        if let screen = windowParking {
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
            valid = String(host.dropFirst().dropLast()).withCString { inet_pton(AF_INET6, $0, &v6) } == 1
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
    var physicalDisplays: [[Double]]? = nil
    var remoteDisplays: [[Double]]? = nil
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", enumeration, windows
        case physicalDisplays = "physical_displays", remoteDisplays = "remote_displays"
    }
    // Subtract physical rectangles rather than comparing against their bounding
    // box: gaps between monitors are not local display area.
    func needsRemote(_ window: NativeWindow) -> Bool {
        guard let physicalDisplays, let remoteDisplays else { return false }
        func rect(_ values: [Double]) -> CGRect? {
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        guard let frame = rect(window.framePoints), remoteDisplays.compactMap(rect).contains(where: { $0.intersects(frame) }) else { return false }
        var uncovered = [frame]
        for display in physicalDisplays.compactMap(rect) {
            uncovered = uncovered.flatMap { part -> [CGRect] in
                let hit = part.intersection(display)
                if hit.isNull || hit.isEmpty { return [part] }
                return [CGRect(x: part.minX, y: part.minY, width: part.width, height: hit.minY - part.minY),
                        CGRect(x: part.minX, y: hit.maxY, width: part.width, height: part.maxY - hit.maxY),
                        CGRect(x: part.minX, y: hit.minY, width: hit.minX - part.minX, height: hit.height),
                        CGRect(x: hit.maxX, y: hit.minY, width: part.maxX - hit.maxX, height: hit.height)].filter { !$0.isEmpty }
            }
        }
        return !uncovered.isEmpty
    }
    func selected(existing: Set<String>, limit: Int) throws -> [NativeWindow] {
        guard schemaVersion == 1, enumeration == "ok" else {
            throw ViewflowError.invalid("窗口列表暂不可用：\(enumeration)")
        }
        guard let physicalDisplays, let remoteDisplays,
              (physicalDisplays + remoteDisplays).allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) && $0[2] > 0 && $0[3] > 0 }) else {
            throw ViewflowError.invalid("显示器布局暂不可用，保留当前窗口连接")
        }
        let candidates = (windows ?? []).filter { $0.eligible && needsRemote($0) }
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
