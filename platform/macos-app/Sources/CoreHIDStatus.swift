import Foundation
import Darwin

// Read-only diagnostics. Unlike --probe, this never creates another HID
// device just to paint the permissions page.
enum CoreHIDStatus {
    static var url: URL { URL(fileURLWithPath: HIDServer.path).deletingLastPathComponent().appendingPathComponent("corehid-status.json") }
    static func read(at url: URL = url) -> [String: Any] {
        let stopped: [String: Any] = ["backend": "corehid", "native_multitouch_attached": false,
                                      "status_call_submits_input": false, "running": false]
        guard let data = try? Data(contentsOf: url),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = report["pid"] as? Int32, pid > 0,
              kill(pid, 0) == 0 || errno == EPERM else { return stopped }
        return report
    }
    static func printStatus() -> Int32 {
        guard let data = try? JSONSerialization.data(withJSONObject: read(), options: [.sortedKeys]) else { return 1 }
        FileHandle.standardOutput.write(data + Data([10])); return 0
    }
}
