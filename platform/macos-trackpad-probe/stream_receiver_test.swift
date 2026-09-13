// Compile with TrackpadBridge.swift and HIDServer.swift on macOS. All driver
// calls are injected fakes; these tests never submit system input.
import Foundation
import IOKit
import Darwin

enum ProfileStore {
    static let root = URL(fileURLWithPath: "/tmp/vfh-" + UUID().uuidString)
}
enum ViewflowError: Error { case invalid(String) }

final class Driver: @unchecked Sendable {
    let lock = NSLock()
    var owner: Int32?
    var entries = 0, reports = 0, releases = 0
    func receive(_ fd: Int32) -> Int32 {
        lock.lock(); entries += 1; lock.unlock()
        return TrackpadBridge.receiveStream(inputFD: fd, submit: { report in
            self.lock.lock(); defer { self.lock.unlock() }
            if let owner = self.owner, owner != fd { return kIOReturnExclusiveAccess }
            self.owner = fd; self.reports += 1
            return KERN_SUCCESS
        }, release: {
            self.lock.lock(); defer { self.lock.unlock() }
            precondition(self.owner == fd)
            self.owner = nil; self.releases += 1
            return KERN_SUCCESS
        })
    }
    func counts() -> (Int, Int, Int) {
        lock.lock(); defer { lock.unlock() }; return (entries, reports, releases)
    }
}

func eventually(_ condition: () -> Bool) {
    let end = Date().addingTimeInterval(3)
    while !condition() && Date() < end { usleep(1000) }
    precondition(condition(), "timed out waiting for local test worker")
}
let header: [UInt8] = [86,70,84,80,2,0,0,0]
func report(active: Bool) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 72)
    bytes[8] = 128; bytes[9] = 62; bytes[10] = 226; bytes[11] = 44
    if active { bytes[0] = 2; bytes[13] = 1; bytes[24] = 1; bytes[25] = 1 }
    return bytes
}
func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count-offset) }
        if n < 0 && errno == EINTR { continue }
        precondition(n > 0); offset += n
    }
}
func connectClient() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); precondition(fd >= 0)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(HIDServer.path.utf8)+[0]
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    precondition(result == 0)
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    precondition(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
    writeAll(fd,header); return fd
}
func finish(_ fd: Int32) -> Int32 {
    shutdown(fd, SHUT_WR)
    var code: Int32 = -1, offset = 0
    while offset < 4 {
        let n = withUnsafeMutableBytes(of: &code) { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), 4-offset) }
        if n < 0 && errno == EINTR { continue }
        precondition(n > 0); offset += n
    }
    close(fd); return Int32(bigEndian: code)
}

@main struct Tests {
    static func main() throws {
        let driver = Driver()
        let server = HIDServer(receiver: { driver.receive($0) })
        defer { server.stop(); try? FileManager.default.removeItem(at: ProfileStore.root) }
        try server.start()
        let desktop = connectClient()
        writeAll(desktop, report(active: false))
        eventually { driver.counts().0 == 1 }
        // Keep the desktop socket open for both complete proxy gestures.
        for _ in 0..<2 {
            let proxy = connectClient()
            writeAll(proxy,report(active: true)); writeAll(proxy,report(active: false))
            precondition(finish(proxy) == 0)
        }
        precondition(driver.counts().1 == 4 && driver.counts().2 == 2)
        // The same persistent desktop connection acquires after the proxies.
        writeAll(desktop,report(active: true)); writeAll(desktop,report(active: false))
        precondition(finish(desktop) == 0)
        precondition(driver.counts().1 == 6 && driver.counts().2 == 3)
        let a = connectClient(), b = connectClient()
        eventually { driver.counts().0 == 5 }
        server.stop(); eventually { server.isStopped }
        close(a); close(b)
        precondition(driver.counts().2 == 3, "idle disconnect must not release another producer")

        // Contention is recoverable on the following physical snapshot.
        var pipes = [Int32](repeating: 0, count: 2); precondition(pipe(&pipes) == 0)
        writeAll(pipes[1],header+report(active:true)+report(active:true)+report(active:false)); close(pipes[1])
        var calls = 0, releases = 0
        let status = TrackpadBridge.receiveStream(inputFD:pipes[0], submit: { _ in
            calls += 1; return calls == 1 ? kIOReturnExclusiveAccess : KERN_SUCCESS
        }, release: { releases += 1; return KERN_SUCCESS })
        close(pipes[0]); precondition(status == 0 && calls == 3 && releases == 1)
        // EOF during a gesture releases the held contacts exactly once.
        precondition(pipe(&pipes) == 0)
        writeAll(pipes[1],header+report(active:true)); close(pipes[1]); releases = 0
        precondition(TrackpadBridge.receiveStream(inputFD:pipes[0], submit:{ _ in KERN_SUCCESS },
            release:{ releases += 1; return KERN_SUCCESS }) == 0)
        close(pipes[0]); precondition(releases == 1)

        // Producer clocks can have unrelated epochs (and wrap). The shared
        // driver's timeline must follow the receiver, preserving 10 ms motion
        // intervals rather than collapsing a backwards epoch to 1 ms steps.
        var emitted: [[UInt8]] = []
        var now: UInt32 = 0xffff_ff00
        for sourceEpoch: UInt32 in [3_000_000_000, 100, 0xffff_fff0] {
            precondition(pipe(&pipes) == 0)
            var active = report(active: true)
            for byte in 0..<4 { active[4 + byte] = UInt8(truncatingIfNeeded: sourceEpoch >> (byte * 8)) }
            writeAll(pipes[1], header + active + active + report(active: false)); close(pipes[1])
            precondition(TrackpadBridge.receiveStream(inputFD: pipes[0], submit: { bytes in
                precondition(bytes[0..<4] == active[0..<4] || bytes[0] == 0)
                if bytes[0] != 0 { precondition(bytes[8...] == active[8...]) }
                emitted.append(bytes); return KERN_SUCCESS
            }, release: { KERN_SUCCESS }, clock: {
                defer { now &+= 100 }; return now
            }) == 0)
            close(pipes[0])
        }
        let stamps = emitted.map { bytes in
            (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[4 + $1]) << ($1 * 8)) }
        }
        precondition(stamps.count == 9)
        for i in 1..<stamps.count { precondition(stamps[i] &- stamps[i - 1] == 100) }
        print("HID stream and concurrent socket tests passed; OS input submissions: 0")
    }
}
