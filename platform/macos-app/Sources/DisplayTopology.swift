import Foundation

// Written by the local display-layout helper after Quartz confirms the layout.
// Pairing material and the user's saved profile are never rewritten here.
struct DisplayTopology: Codable, Equatable {
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

    static func load() -> DisplayTopology? {
        let path = ProfileStore.root.appendingPathComponent("run/display-topology.json")
        guard let data = try? Data(contentsOf: path), data.count < 16384,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              [value.linuxWidth, value.linuxHeight, value.windowsWidth, value.windowsHeight].allSatisfy({ $0 > 0 && $0 <= 32768 }),
              [value.linuxX, value.linuxY, value.windowsX, value.windowsY].allSatisfy({ (-100000...100000).contains($0) }) else { return nil }
        return value
    }
    func applying(to original: ConnectionProfile) -> ConnectionProfile {
        var profile = original
        profile.presentationOriginX = linuxX; profile.presentationOriginY = linuxY
        let linux = ConnectionProfile.WindowParking(serial: 1, width: linuxWidth, height: linuxHeight, x: linuxX, y: linuxY)
        let win = ConnectionProfile.WindowParking(serial: 2, width: windowsWidth, height: windowsHeight, x: windowsX, y: windowsY)
        profile.windowParking = connected ? linux : nil
        profile.windowParkingDisplays = windows ? [win] : []
        profile.windowDestinations = original.windowDestinations.filter { connected && ($0.id != "windows" || windows) }.map { destination in
            var value = destination
            if value.id == "linux" { value.viewport = linux }
            if value.id == "windows" { value.viewport = win }
            return value
        }
        profile.windowReceivers = (original.windowReceivers ?? []).filter { $0.id != "windows" || windows }.map { receiver in
            var value = receiver
            if value.id == "windows" { value.originX = windowsX; value.originY = windowsY }
            return value
        }
        return profile
    }
}
