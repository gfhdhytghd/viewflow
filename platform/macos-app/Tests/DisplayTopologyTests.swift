import Foundation
@main enum DisplayTopologyTests {
    static func main() throws {
        var profile = ConnectionProfile(name: "test", deviceID: String(repeating: "1", count: 32),
            certificatePEM: "test", privateKeyPEM: "test", authorityPEM: "test")
        profile.windowDestinations = [
            .init(id: "linux", address: "127.0.0.1:44222", serverName: "linux"),
            .init(id: "windows", address: "127.0.0.1:44223", serverName: "windows")]
        profile.windowReceivers = [.init(id: "windows", bind: "0.0.0.0:44223", scale: 2, originX: 0, originY: -1200)]
        let mac = DisplayTopology(connected: true, windows: false, sidecar: true,
            linuxX: -3072, linuxY: -390, linuxWidth: 3072, linuxHeight: 1728,
            windowsX: 0, windowsY: 0, windowsWidth: 1920, windowsHeight: 1200)
        let onlyMac = mac.applying(to: profile)
        precondition(onlyMac.windowDestinations.map(\.id) == ["linux"])
        precondition(onlyMac.windowReceivers == [])
        precondition(onlyMac.windowParkingDisplays == [])
        precondition(onlyMac.presentationOriginY == -390)
        precondition(onlyMac.windowDestinations[0].viewport?.y == -390)
        let both = DisplayTopology(connected: true, windows: true, sidecar: true,
            linuxX: -3072, linuxY: -1590, linuxWidth: 3072, linuxHeight: 1728,
            windowsX: 0, windowsY: -1200, windowsWidth: 1920, windowsHeight: 1200).applying(to: profile)
        precondition(both.windowDestinations.count == 2)
        precondition(both.windowParkingDisplays?.first?.y == -1200)
        precondition(both.windowDestinations[0].viewport?.y == -1590)
        let absent = DisplayTopology(connected: false, windows: false, sidecar: false,
            linuxX: -3072, linuxY: -1590, linuxWidth: 3072, linuxHeight: 1728,
            windowsX: 0, windowsY: -1200, windowsWidth: 1920, windowsHeight: 1200).applying(to: profile)
        precondition(absent.windowDestinations.isEmpty && absent.windowParking == nil)
        precondition(profile.windowDestinations.count == 2) // Saved pairing is unchanged.
        print("display topology profile tests passed")
    }
}
