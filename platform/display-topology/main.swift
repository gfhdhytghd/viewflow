import AppKit
import CoreGraphics
import Foundation

struct Display: Codable {
    let id: UInt32
    let name: String
    let kind: String
    let serial: UInt32
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let pixelsWidth: Int
    let pixelsHeight: Int
}
func inventory() -> [Display] {
    NSScreen.screens.map { screen in
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        let rect = CGDisplayBounds(id)
        let vendor = CGDisplayVendorNumber(id), product = CGDisplayModelNumber(id)
        let parking = vendor == 0x5646 && product == 0x5746
        let sidecar = (vendor == 0x6161706c && product == 0x69506164) || screen.localizedName.localizedCaseInsensitiveContains("Sidecar")
        let mode = CGDisplayCopyDisplayMode(id)
        return Display(id: id, name: screen.localizedName, kind: parking ? "parking" : sidecar ? "sidecar" : "physical",
            serial: CGDisplaySerialNumber(id), x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height),
            pixelsWidth: mode?.pixelWidth ?? Int(rect.width), pixelsHeight: mode?.pixelHeight ?? Int(rect.height))
    }
}
struct Request: Codable {
    let right: String
    let localWidth: Int
    let localHeight: Int
    let rightX: Int
    let rightY: Int
    let rightWidth: Int
    let rightHeight: Int
    let sidecarX: Int
    let sidecarY: Int
}
struct State: Codable, Equatable {
    let connected: Bool
    let windows: Bool
    let sidecar: Bool
    let linuxX: Int
    let linuxY: Int
    let linuxWidth: Int
    let linuxHeight: Int
    let windowsX: Int
    let windowsY: Int
    let windowsWidth: Int
    let windowsHeight: Int
}
func emit(_ displays: [Display], changed: Bool = false) throws {
    struct Report: Encodable { let main: UInt32; let displays: [Display]; let changed: Bool }
    let data = try JSONEncoder().encode(Report(main: CGMainDisplayID(), displays: displays, changed: changed))
    print(String(decoding: data, as: UTF8.self))
}
do {
    let before = inventory()
    if CommandLine.arguments.dropFirst().first == "--probe" { try emit(before) }
    else if CommandLine.arguments.dropFirst().first == "--apply" {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let request = try JSONDecoder().decode(Request.self, from: input)
        guard ["windows", "macos"].contains(request.right),
              [request.localWidth, request.localHeight, request.rightWidth, request.rightHeight].allSatisfy({ $0 > 0 && $0 <= 32768 }),
              [request.rightX, request.rightY, request.sidecarX, request.sidecarY].allSatisfy({ abs($0) <= 100000 }) else {
            throw NSError(domain: "Invalid topology request", code: 1)
        }
        let sidecar = before.first { $0.kind == "sidecar" }
        let hdmi = before.first { $0.kind == "physical" && $0.name.localizedCaseInsensitiveContains("HDMI") }
            ?? before.first { $0.kind == "physical" }
        let connected = request.right == "macos" || sidecar != nil
        let target = request.right == "macos" ? hdmi : sidecar
        if connected && target == nil { throw NSError(domain: "Waiting for selected physical Mac display", code: 2) }
        let anchorX = request.right == "macos" ? request.rightX : request.sidecarX
        let anchorY = request.right == "macos" ? request.rightY : request.sidecarY
        let state = State(connected: connected, windows: request.right == "windows" && sidecar != nil,
            sidecar: sidecar != nil, linuxX: -anchorX, linuxY: -anchorY,
            linuxWidth: request.localWidth, linuxHeight: request.localHeight,
            windowsX: request.rightX-anchorX, windowsY: request.rightY-anchorY,
            windowsWidth: request.rightWidth, windowsHeight: request.rightHeight)
        var moves: [(Display, Int, Int)] = []
        if let target {
            moves.append((target, 0, 0))
            if let sidecar, sidecar.id != target.id {
                moves.append((sidecar, request.sidecarX-anchorX, request.sidecarY-anchorY))
            }
            // A switch can retain the HDMI EDID when Windows is selected. Keep
            // this inactive Mac output off the Sidecar canvas without claiming it.
            if request.right == "windows", let hdmi { moves.append((hdmi, 50000, 0)) }
            for display in before where display.kind == "parking" {
                if display.serial == 1 { moves.append((display, state.linuxX, state.linuxY)) }
                else if display.serial == 2 && state.windows { moves.append((display, state.windowsX, state.windowsY)) }
            }
        }
        let changed = moves.contains { $0.0.x != $0.1 || $0.0.y != $0.2 } || (target != nil && CGMainDisplayID() != target!.id)
        if changed {
            var transaction: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else { throw NSError(domain: "Begin display layout", code: 3) }
            for (display, x, y) in moves {
                guard CGConfigureDisplayOrigin(transaction, display.id, Int32(x), Int32(y)) == .success else {
                    CGCancelDisplayConfiguration(transaction); throw NSError(domain: "Arrange display", code: 4)
                }
            }
            guard CGCompleteDisplayConfiguration(transaction, .forSession) == .success else { throw NSError(domain: "Commit display layout", code: 5) }
        }
        if let target, CGMainDisplayID() != target.id { throw NSError(domain: "Main display readback mismatch", code: 6) }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Viewflow/run")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("display-topology.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        if (try? Data(contentsOf: path)) != data { try data.write(to: path, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        try emit(inventory(), changed: changed)
    } else { throw NSError(domain: "Usage: viewflow-display-topology --probe|--apply", code: 1) }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
