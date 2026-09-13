import AppKit
import Darwin

// These tests use socket pairs only, never the real HID driver.
enum TrackpadBridge {
    static func run(_ command: String, inputFD: Int32) -> Int32 { 0 }
}

@main @MainActor enum TerminationTests {
    static func main() throws {
        let coordinator = TerminationCoordinator()
        var replies = 0, polls = 0, defaultFired = false
        let ordinary = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in defaultFired = true }
        coordinator.begin(poll: { _ in polls += 1; return polls >= 2 }, finish: { replies += 1 })
        coordinator.begin(poll: { _ in fatalError("repeated quit replaced active shutdown") }, finish: {})
        let deadline = Date().addingTimeInterval(2)
        while replies == 0 && Date() < deadline { RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05)) }
        precondition(replies == 1 && polls == 2 && !coordinator.isWaiting)
        precondition(!defaultFired, "test must exercise only the termination run-loop mode")
        ordinary.invalidate()

        let worker = ManagedWorker(id: "termination-test-\(UUID().uuidString)", component: .clipboard,
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' INT TERM; exec /bin/sleep 30"])
        worker.desired = true; worker.reconcile()
        guard let child = worker.process else { fatalError("test child failed to launch") }
        Thread.sleep(forTimeInterval: 0.1)
        worker.stop()
        worker.pollTermination(elapsed: 2.1)
        precondition(child.isRunning)
        worker.pollTermination(elapsed: 4.1)
        let childDeadline = Date().addingTimeInterval(2)
        while worker.process != nil && Date() < childDeadline {
            worker.pollTermination(elapsed: 4.2)
            RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02))
        }
        precondition(worker.process == nil && !child.isRunning)
        try? FileManager.default.removeItem(at: BundleTools.logs.appendingPathComponent("\(worker.id).log"))

        for sendReply in [true, false] {
            var input: [Int32] = [0,0], sockets: [Int32] = [0,0]
            precondition(pipe(&input) == 0 && socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
            let peer = sockets[1]
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.1)
                if sendReply {
                    var code = Int32(0).bigEndian
                    withUnsafeBytes(of: &code) { _ = Darwin.write(peer, $0.baseAddress, $0.count) }
                }
                Darwin.close(peer)
            }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let code = try HIDServer.relay(inputFD: input[0], socketFD: sockets[0])
                precondition(sendReply && code == 0)
            } catch { precondition(!sendReply) }
            precondition(ProcessInfo.processInfo.systemUptime - started < 1)
            // stdin's writer deliberately stayed open throughout relay().
            Darwin.close(input[0]); Darwin.close(input[1]); Darwin.close(sockets[0])
        }
        print("termination modal-loop, repeated quit, worker escalation, idle HID reply/EOF: passed")
    }
}
