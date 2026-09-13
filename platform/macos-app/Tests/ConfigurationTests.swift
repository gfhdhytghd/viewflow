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
        profile.windowsBind = profile.inputBind
        do { try profile.validate(); fatalError("accepted conflicting ports") } catch {}
        let one = NativeWindow(windowID: 1, pid: 10, bundleID: "com.example", applicationName: "Example",
                               executableName: "Example", onScreen: true, layer: 0, framePoints: [0,0,800,600])
        let two = NativeWindow(windowID: 2, pid: 11, bundleID: "com.example", applicationName: "Example",
                               executableName: "Example", onScreen: true, layer: 0, framePoints: [0,0,800,600])
        let proxy = NativeWindow(windowID: 3, pid: 12, bundleID: "org.viewflow.app", applicationName: "Viewflow",
                               executableName: "Viewflow", onScreen: true, layer: 0, framePoints: [0,0,800,600])
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
        precondition((try? crossing.selected(existing: [], limit: 8)) == [one])
        var covered = crossing
        covered.physicalDisplays = [[0,0,400,1200],[400,0,400,1200]]
        precondition((try? covered.selected(existing: [one.key], limit: 8)) == [])
        var gap = covered
        gap.physicalDisplays = [[0,0,300,1200],[400,0,400,1200]]
        gap.remoteDisplays = [[300,0,100,1200]]
        precondition((try? gap.selected(existing: [], limit: 8)) == [one])
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
