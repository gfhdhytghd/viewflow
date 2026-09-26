import Foundation

@main enum GroupConfigurationTests {
    static func main() throws {
        func link(_ peer: String, _ port: Int, _ serial: UInt32) -> ConnectionProfile {
            var profile = ConnectionProfile(name: "Member", deviceID: String(repeating: "a", count: 32),
                pairingDeviceID: String(repeating: peer, count: 32),
                certificatePEM: "-----BEGIN CERTIFICATE-----\ntest", privateKeyPEM: "-----BEGIN PRIVATE KEY-----\ntest",
                authorityPEM: "-----BEGIN CERTIFICATE-----\ntest")
            profile.inputBind = "0.0.0.0:\(port)"
            profile.windowsBind = "0.0.0.0:\(port + 1)"
            profile.clipboardBind = "0.0.0.0:\(port + 2)"
            profile.windowParking = .init(serial: serial, width: 1920, height: 1080, x: 1920 * Int(serial), y: 0)
            return profile
        }
        let first = link("b", 41000, 1), second = link("c", 42000, 2)
        var group = first
        group.groupID = String(repeating: "d", count: 32)
        group.groupRole = "host"; group.groupHostID = group.deviceID
        group.groupConnections = [first, second]
        try group.validate()
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(group))
        precondition(decoded == group)
        func rejects(_ profile: ConnectionProfile) {
            do { try profile.validate(); fatalError("accepted invalid group") } catch {}
        }
        var invalid = group
        invalid.groupConnections = [first, second, link("e", 43000, 3)]; rejects(invalid)
        invalid = group; invalid.groupRole = "client"; rejects(invalid)
        invalid = group; invalid.groupConnections![1].inputBind = first.inputBind; rejects(invalid)
        invalid = group; invalid.groupConnections![1].windowParking!.serial = 1; rejects(invalid)
        invalid = group; invalid.groupConnections![1].pairingDeviceID = first.pairingDeviceID; rejects(invalid)
        invalid = group; invalid.groupID = nil; rejects(invalid)
        var client = first
        client.groupID = group.groupID; client.groupRole = "client"; client.groupHostID = first.pairingDeviceID
        client.groupConnections = [first]; try client.validate()
        print("Group configuration checks passed; no input posted")
    }
}
