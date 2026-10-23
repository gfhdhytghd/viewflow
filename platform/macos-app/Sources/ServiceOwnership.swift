import Foundation
import Darwin

// Upgrade recovery for helpers launched before owner monitoring was introduced.
// Match the complete service invocation and user, never just a port or a name.
struct OrphanService {
    let pid: Int32
    static func matching(_ snapshot: String, uid: UInt32, executable: URL, arguments: [String]) -> [OrphanService] {
        let expected = ([executable.path] + arguments).joined(separator: " ")
        return snapshot.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, UInt32(fields[0]) == uid,
                  let pid = Int32(fields[1]), pid > 1, fields[2] == "1",
                  String(fields[3]) == expected else { return nil }
            return OrphanService(pid: pid)
        }
    }
}

final class ServiceOwnership {
    private var retiring: [Int32: Date] = [:]
    func ready(executable: URL, arguments: [String]) throws -> Bool {
        let query = Process(), pipe = Pipe()
        query.executableURL = URL(fileURLWithPath: "/bin/ps")
        query.arguments = ["-axww", "-o", "uid=,pid=,ppid=,command="]
        query.standardOutput = pipe
        query.standardError = FileHandle.nullDevice
        try query.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        query.waitUntilExit()
        guard query.terminationStatus == 0 else { throw ViewflowError.invalid("无法检查旧连接进程") }
        let orphans = OrphanService.matching(String(decoding: data, as: UTF8.self), uid: getuid(), executable: executable, arguments: arguments)
        let now = Date()
        retiring = retiring.filter { entry in orphans.contains { $0.pid == entry.key } }
        for orphan in orphans {
            if let since = retiring[orphan.pid] {
                let elapsed = now.timeIntervalSince(since)
                if elapsed >= 7 { kill(orphan.pid, SIGKILL) }
                else if elapsed >= 5 { kill(orphan.pid, SIGTERM) }
            } else {
                retiring[orphan.pid] = now
                kill(orphan.pid, SIGINT)
            }
        }
        return orphans.isEmpty
    }
}
