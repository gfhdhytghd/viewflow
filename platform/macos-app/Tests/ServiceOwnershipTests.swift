import Foundation
@main struct ServiceOwnershipTests {
    static func main() throws {
        let exe = URL(fileURLWithPath: "/Applications/Viewflow.app/Contents/Helpers/vf-clipboard-peer")
        let args = ["--config", "/Users/test/Library/Application Support/Viewflow/run/clipboard-peer.json"]
        let command = ([exe.path] + args).joined(separator: " ")
        let snapshot = """
          501 101 1 \(command)
          501 102 777 \(command)
          502 103 1 \(command)
          501 104 1 \(command)-other
          501 105 1 /tmp/vf-clipboard-peer --config x
          501 106 1 \(command) --extra
        """
        precondition(OrphanService.matching(snapshot, uid: 501, executable: exe, arguments: args).map(\.pid) == [101])
        precondition(OrphanService.matching("", uid: 501, executable: exe, arguments: args).isEmpty)
        print("service ownership selection tests passed")
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let duration = String(60000 + getpid())
        let live = Process()
        live.executableURL = sleep; live.arguments = [duration]
        try live.run()
        defer { if live.isRunning { live.terminate() } }
        let ownership = ServiceOwnership()
        let liveReady = try ownership.ready(executable: sleep, arguments: [duration])
        precondition(liveReady)
        precondition(live.isRunning)
        let parent = Process(), output = Pipe()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "/bin/sleep \(duration) >/dev/null 2>&1 & echo $!"]
        parent.standardOutput = output
        try parent.run()
        let pidText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        parent.waitUntilExit()
        let orphan = Int32(pidText)!
        Thread.sleep(forTimeInterval: 0.2)
        let initiallyReady = try ownership.ready(executable: sleep, arguments: [duration])
        precondition(!initiallyReady)
        var recovered = false
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.1)
            if try ownership.ready(executable: sleep, arguments: [duration]) { recovered = true; break }
        }
        if !recovered { kill(orphan, SIGKILL) }
        precondition(recovered && live.isRunning)
        print("real orphan reclaimed; live sibling preserved")
    }
}
