import Foundation

@main enum HandoffConfigurationTests {
    static func main() throws {
        let local = String(repeating: "a", count: 32), remote = String(repeating: "b", count: 32)
        var profile = ConnectionProfile(name: "same-hostname", deviceID: local,
            pairingDeviceID: remote,
            certificatePEM: "-----BEGIN CERTIFICATE-----\nfixture",
            privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nfixture",
            authorityPEM: "-----BEGIN CERTIFICATE-----\nfixture")
        profile.desktopHandoff = .init(bind: "0.0.0.0:44300", remote: "127.0.0.1:44301",
            server_name: "vf-" + remote + ".local", device_id: local, peer_id: remote,
            local: .init(x: 0, y: 0, width: 1920, height: 1080),
            peer: .init(x: -1920, y: 0, width: 1920, height: 1080), sender: true, receiver: true)
        try profile.validate()
        let copy = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        precondition(copy == profile && copy.desktopHandoff?.sender == true && copy.desktopHandoff?.receiver == true)
        profile.desktopHandoff!.bind = profile.inputBind
        do { try profile.validate(); fatalError("accepted colliding handoff listener") } catch {}
        profile.desktopHandoff = nil
        try profile.validate() // Old profiles retain their working lanes.
        print("Handoff configuration checks passed; no input posted")
    }
}
