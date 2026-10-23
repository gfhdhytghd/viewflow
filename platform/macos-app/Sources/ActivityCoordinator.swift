import Foundation

// One host-wide background budget across source children. Connections retain
// their own focus and interaction histories; a busy connection cannot keep all
// other children's background work at an unconstrained rate.
struct ActivityBudget {
    private(set) var level = 0
    private var badWindows = 0
    private var goodSince: TimeInterval?
    mutating func sample(bad: Bool, now: TimeInterval) {
        if bad {
            goodSince = nil
            badWindows += 1
            if badWindows >= 3 { level = min(3, level + 1); badWindows = 0 }
        } else {
            badWindows = 0
            if goodSince == nil { goodSince = now }
            if level > 0, now - (goodSince ?? now) >= 2 { level -= 1; goodSince = now }
        }
    }
    var backgroundFPS: Int { [0, 30, 15, 5][level] }
}

@MainActor final class ActivityCoordinator {
    private var budget = ActivityBudget()
    private var lastSample: TimeInterval = 0
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func reportPath(_ source: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(source + ".json").path
    }
    func poll(active: Set<String>, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard now - lastSample >= 0.25 else { return }
        lastSample = now
        var bad = false
        for source in active {
            let path = directory.appendingPathComponent(source + ".json")
            guard let data = try? Data(contentsOf: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let updated = object["updated"] as? Double,
                  now - updated >= 0, now - updated < 2,
                  let queue = object["queue_us"] as? Double,
                  let target = object["target_fps"] as? Double else { continue }
            bad = bad || queue > 2_000_000 / max(1, target) || (object["saturated"] as? Bool ?? false)
        }
        budget.sample(bad: bad, now: now)
        let response: [String: Any] = ["updated": now, "background_fps": budget.backgroundFPS,
                                       "connections": active.count]
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            try? data.write(to: directory.appendingPathComponent("budget.json"), options: .atomic)
        }
    }
}
