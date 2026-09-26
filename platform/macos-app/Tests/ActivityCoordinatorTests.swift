import Foundation

// Standalone host-budget tests: temporary report files only, no GUI or input.
@main @MainActor enum ActivityCoordinatorTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vf-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ActivityCoordinator(directory: directory)
        let first = try coordinator.reportPath("first")
        let second = try coordinator.reportPath("second")
        func report(_ path: String, now: Double, queue: Double, saturated: Bool = false) throws {
            let object: [String: Any] = ["updated": now, "queue_us": queue, "target_fps": 60, "saturated": saturated]
            try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        func budget() throws -> [String: Any] {
            let data = try Data(contentsOf: directory.appendingPathComponent("budget.json"))
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func expect(_ key: String, _ value: Int) throws {
            let current = try budget()
            precondition(current[key] as? Int == value)
        }
        for now in [1.0, 1.25, 1.5] {
            try report(first, now: now, queue: 40_000)
            try report(second, now: now, queue: 0)
            coordinator.poll(active: ["first", "second"], now: now)
        }
        try expect("background_fps", 30)
        try expect("connections", 2)
        // Extra application polls cannot turn one 250 ms sample into several.
        coordinator.poll(active: ["first", "second"], now: 1.51)
        let unchanged = try budget()
        precondition(unchanged["updated"] as? Double == 1.5)
        for now in [1.75, 2.0, 2.25] {
            try report(first, now: now, queue: 0, saturated: true)
            coordinator.poll(active: ["first", "second"], now: now)
        }
        try expect("background_fps", 15)
        // An inactive connection's stale congested file must not hold the host
        // budget down. Two full normal seconds restore one level at a time.
        for step in 0...8 {
            let now = 2.5 + Double(step) * 0.25
            try report(second, now: now, queue: 0)
            coordinator.poll(active: ["second"], now: now)
        }
        try expect("background_fps", 30)
        try expect("connections", 1)
        for step in 1...8 {
            let now = 4.5 + Double(step) * 0.25
            try report(second, now: now, queue: 0)
            coordinator.poll(active: ["second"], now: now)
        }
        try expect("background_fps", 0)
        print("ActivityCoordinatorTests passed")
    }
}
