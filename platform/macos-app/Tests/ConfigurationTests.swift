import Foundation

@main enum ConfigurationTests {
    static func main() throws {
        var profile = ConnectionProfile(name: "test", deviceID: String(repeating: "1", count: 32),
            certificatePEM: "-----BEGIN CERTIFICATE-----\ntest", privateKeyPEM: "-----BEGIN PRIVATE KEY-----\ntest",
            authorityPEM: "-----BEGIN CERTIFICATE-----\ntest")
        try profile.validate()
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        precondition(decoded == profile)
        for value in ["127.0.0.1:123", "[::1]:443", "[2001:db8::1]:65535"] { try ConnectionProfile.validateAddress(value) }
        for value in ["127.0.0.1:0", "127.0.0.256:123", "[:::]:123", "[a:b]:123", "1.2.3.4:65536", "1.2.3.4:1\n"] {
            do { try ConnectionProfile.validateAddress(value); fatalError("accepted invalid address: \(value)") } catch {}
        }
        var multiple = decoded
        multiple.windowReceivers = [.init(id: "windows", bind: "0.0.0.0:44223", scale: 2, originX: 0, originY: -1200)]
        try multiple.validate()
        precondition((try? JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(multiple))) == multiple)
        multiple.windowReceivers!.append(multiple.windowReceivers![0])
        do { try multiple.validate(); fatalError("accepted duplicate receiver") } catch {}
        multiple.windowReceivers = [.init(id: "windows", bind: multiple.windowsBind, scale: 2, originX: 0, originY: -1200)]
        do { try multiple.validate(); fatalError("accepted receiver port collision") } catch {}
        profile.windowsBind = profile.inputBind
        do { try profile.validate(); fatalError("accepted conflicting ports") } catch {}
        let one = NativeWindow(windowID: 1, pid: 10, bundleID: "com.example", applicationName: "Example",
                               executableName: "Example", onScreen: true, layer: 0, framePoints: [0,0,800,600])
        var dragInventory = NativeDragInventory()
        var dragSample = WindowInventory(schemaVersion: 1, enumeration: "ok", windows: [one], pointerPoints: [100, 20], leftButtonDown: true)
        dragInventory.observe(dragSample)
        precondition(dragInventory.grabs.isEmpty) // A press alone is not a window drag.
        let moved = NativeWindow(windowID: 1, pid: 10, bundleID: "com.example", applicationName: "Example",
                                executableName: "Example", onScreen: true, layer: 0, framePoints: [0,-40,800,600])
        dragSample.windows = [moved]; dragSample.pointerPoints = [100,-20]
        dragInventory.observe(dragSample)
        precondition(dragInventory.grabs[one.key] == [100,20])
        dragSample.leftButtonDown = false
        dragInventory.observe(dragSample)
        precondition(dragInventory.grabs[one.key] == [100,20]) // Routing release before source launch.
        dragInventory.observe(dragSample)
        precondition(dragInventory.grabs.isEmpty)
        dragSample.leftButtonDown = true
        dragInventory.observe(dragSample)
        let resized = NativeWindow(windowID: 1, pid: 10, bundleID: "com.example", applicationName: "Example",
                                  executableName: "Example", onScreen: true, layer: 0, framePoints: [0,-60,800,620])
        dragSample.windows = [resized]
        dragInventory.observe(dragSample)
        precondition(dragInventory.grabs.isEmpty) // Resize stays native.
        let two = NativeWindow(windowID: 2, pid: 11, bundleID: "com.example", applicationName: "Example",
                               executableName: "Example", onScreen: true, layer: 0, framePoints: [0,0,800,600])
        let proxy = NativeWindow(windowID: 3, pid: 12, bundleID: "org.viewflow.app", applicationName: "Viewflow",
                               executableName: "Viewflow", onScreen: true, layer: 0, framePoints: [0,0,800,600])
        let unbundledProxy = NativeWindow(windowID: 4, pid: 13, bundleID: "", applicationName: "kitty",
            executableName: "viewflow-macos-windows", onScreen: true, layer: 0, framePoints: [0,0,800,600])
        precondition(!unbundledProxy.eligible)
        let windowsPeer = ConnectionProfile.WindowDestination(id: "windows", address: "127.0.0.1:44221", serverName: "windows", viewport: .init(width: 1920, height: 1200, x: 0, y: -1200))
        precondition(!windowsPeer.accepts(one))
        var dualParking = decoded
        dualParking.windowParking = .init(width: 3072, height: 1728, x: -3072, y: -1590)
        dualParking.windowParkingDisplays = [.init(serial: 2, width: 1920, height: 1200, x: 0, y: -1200)]
        try dualParking.validate()
        dualParking.windowParkingDisplays![0].serial = 1
        do { try dualParking.validate(); fatalError("accepted repeated display serial") } catch {}
        let inventory = WindowInventory(schemaVersion: 1, enumeration: "ok", windows: [proxy,one,two], physicalDisplays: [[-1920,0,1920,1200]], remoteDisplays: [[0,0,3072,1728]])
        let selected = try inventory.selected(existing: [two.key], limit: 1)
        precondition(selected == [two])
        let menu = NativeWindow(windowID: 100, pid: 11, bundleID: "com.example", applicationName: "Example",
                                executableName: "Example", onScreen: true, layer: 101, framePoints: [20,20,216,321])
        var withMenu = inventory; withMenu.windows = [one,two,menu]
        precondition((try? withMenu.selected(existing: [two.key], limit: 1)) == [two,menu])
        precondition((try? withMenu.selected(existing: [one.key], limit: 1)) == [one])
        let local = WindowInventory(schemaVersion: 1, enumeration: "ok", windows: [one],
                                    physicalDisplays: [[0,0,1920,1200]], remoteDisplays: [[-3072,0,3072,1728]])
        precondition((try? local.selected(existing: [one.key], limit: 8)) == [])
        var crossing = local
        crossing.physicalDisplays = [[100,0,1920,1200]]
        crossing.remoteDisplays = [[-2972,0,3072,1728]]
        precondition((try? crossing.selected(existing: [], limit: 8)) == [])
        for edge in [399.0, 400.0, 401.0, 399.0] {
            crossing.physicalDisplays = [[edge,0,1920,1200]]
            crossing.remoteDisplays = [[edge-3072,0,3072,1728]]
            precondition(crossing.needsRemote(one) == (edge > 400))
        }
        let remotePeer = ConnectionProfile.WindowDestination(id: "linux", address: "127.0.0.1:44221", serverName: "linux", viewport: .init(width: 3072, height: 1728, x: -2671, y: 0))
        precondition(remotePeer.accepts(one))
        var touchingPeer = remotePeer; touchingPeer.viewport!.x = -2672
        precondition(!touchingPeer.accepts(one))
        var covered = crossing
        covered.physicalDisplays = [[0,0,400,1200],[400,0,400,1200]]
        precondition((try? covered.selected(existing: [one.key], limit: 8)) == [])
        var gap = covered
        gap.physicalDisplays = [[0,0,300,1200],[400,0,400,1200]]
        gap.remoteDisplays = [[300,0,100,1200]]
        precondition((try? gap.selected(existing: [], limit: 8)) == [])
        var noGeometry = local; noGeometry.physicalDisplays = nil
        precondition(!noGeometry.needsRemote(one))
        do {
            _ = try WindowInventory(schemaVersion: 1, enumeration: "unavailable", windows: []).selected(existing: [one.key], limit: 8)
            fatalError("failed inventory must not masquerade as empty desktop")
        } catch {}
        var retry = RestartPolicy()
        precondition((0..<8).map { _ in retry.failed() } == [1,2,4,8,16,30,30,30])
        retry.stableRun(); precondition(retry.failed() == 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProfileStore.save(decoded, at: root)
        let restored = try ProfileStore.load(at: root)
        precondition(restored == decoded)
        let fields = try ProfileStore.identity(decoded, at: root)
        for value in fields.values {
            let attrs = try FileManager.default.attributesOfItem(atPath: value as! String)
            precondition((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
        }
        print("Viewflow configuration, recovery and identity storage tests passed")
    }
}
