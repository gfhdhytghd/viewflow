import Foundation
@main enum SpaceTransitionTests {
    static func main() throws {
        func sample(_ dx: Double = 0, animating: Bool = false, space: UInt64 = 10) -> WindowInventory {
            let windows = (1...3).map { n in
                NativeWindow(windowID: UInt32(n), pid: Int32(n), bundleID: "test", applicationName: "test",
                    executableName: "test", onScreen: true, layer: 0, framePoints: [Double(n)*100+dx, 0, 500, 500])
            }
            return WindowInventory(schemaVersion: 1, enumeration: "ok", windows: windows,
                physicalDisplays: [[0,0,1920,1080]], remoteDisplays: [[-1920,0,1920,1080]],
                spaceAnimating: animating, displaySpaces: ["1": space])
        }
        var gate = SpaceTransitionGate()
        precondition(!gate.observe(sample(), now: 1))
        var drag = sample(); drag.windows = [sample(-20).windows![0]] + Array(sample().windows!.dropFirst())
        precondition(!gate.observe(drag, now: 1.1))
        precondition(gate.observe(sample(animating: true), now: 2))
        precondition(gate.observe(sample(animating: true), now: 10))
        precondition(gate.observe(sample(), now: 10.1))
        precondition(!gate.observe(sample(), now: 10.3))
        precondition(gate.observe(sample(space: 11), now: 11))
        gate.spaceChanged(now: 11.2)
        precondition(gate.observe(sample(space: 11), now: 11.3))
        precondition(!gate.observe(sample(space: 11), now: 11.5))
        var fallback = SpaceTransitionGate()
        var first = sample(); first.spaceAnimating = nil; first.displaySpaces = nil
        var moved = sample(-20); moved.spaceAnimating = nil; moved.displaySpaces = nil
        precondition(!fallback.observe(first, now: 1))
        precondition(fallback.observe(moved, now: 1.1))
        precondition(!fallback.observe(moved, now: 1.4))
        // Existing selection survives a missing-window snapshot while the gate holds:
        // AppModel returns before selection, worker stop, or worker creation.
        precondition(gate.observe(sample(animating: true), now: 12))
        var empty = sample(); empty.windows = []
        precondition(gate.observe(empty, now: 12.1))
        let json = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "enumeration": "ok"])
        let legacy = try JSONDecoder().decode(WindowInventory.self, from: json)
        precondition(legacy.spaceAnimating == nil && legacy.displaySpaces == nil)
        print("Spaces admission tests passed")
    }
}
