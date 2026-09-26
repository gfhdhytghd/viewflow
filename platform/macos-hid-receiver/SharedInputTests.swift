import Foundation
import Darwin
import IOKit

private final class FakeDevice: @unchecked Sendable {
    private let lock = NSLock()
    var failRelease = false
    private var frames = 0, lifts = 0
    func apply(_ bytes: [UInt8]) -> Int32 {
        lock.lock(); defer { lock.unlock() }; frames += 1; return KERN_SUCCESS
    }
    func release() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if failRelease { return kIOReturnError }; lifts += 1; return KERN_SUCCESS
    }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (frames, lifts) }
}

@main enum SharedInputTests {
    static func snapshot(active: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 72)
        bytes[0] = active ? 1 : 0; bytes[13] = active ? 1 : 0
        return bytes
    }
    static func send(_ bytes: [UInt8], _ fd: Int32) {
        bytes.withUnsafeBytes { precondition(Darwin.write(fd, $0.baseAddress, $0.count) == $0.count) }
    }
    static func pair() -> [Int32] {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0); return fds
    }
    static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let name = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(result == 0); return fd
    }
    static func main() throws {
        let fake = FakeDevice(), first = UUID(), second = UUID()
        let shared = SharedInput(apply: fake.apply, release: fake.release)
        precondition(shared.submit(snapshot(active: true), from: first) == KERN_SUCCESS)
        precondition(shared.submit(snapshot(active: true), from: second) == kIOReturnExclusiveAccess)
        shared.disconnected(second)
        precondition(fake.counts == (1, 0), "non-owner EOF must not release active contacts")
        precondition(shared.relinquish(first) == KERN_SUCCESS)
        precondition(shared.submit(snapshot(active: true), from: second) == KERN_SUCCESS)
        fake.failRelease = true
        shared.disconnected(second)
        precondition(shared.counters()["release_pending"] as? Bool == true)
        precondition(shared.submit(snapshot(active: true), from: first) == kIOReturnError)
        precondition(fake.counts.0 == 2, "no new reports before a failed release is recovered")
        fake.failRelease = false
        shared.retryRelease()
        precondition(shared.submit(snapshot(active: true), from: first) == KERN_SUCCESS)
        shared.disconnected(first)

        // Two real ordered byte streams share the fake device. The idle desktop
        // connection stays open while a proxy stream sends contacts and closes.
        let idle = pair(), proxy = pair(), group = DispatchGroup()
        let header = Array("VFTP".utf8) + [2, 0, 0, 0]
        for fds in [idle, proxy] {
            group.enter()
            DispatchQueue.global().async {
                precondition(shared.receive(fds[1]) == 0)
                Darwin.close(fds[1]); group.leave()
            }
            send(header, fds[0])
        }
        send(snapshot(active: false), idle[0])
        send(snapshot(active: true), proxy[0])
        shutdown(proxy[0], SHUT_WR)
        let deadline = Date().addingTimeInterval(2)
        while fake.counts.0 < 4 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(fake.counts.0 == 4, "idle producer blocked proxy input")
        shutdown(idle[0], SHUT_WR)
        precondition(group.wait(timeout: .now() + 2) == .success)
        Darwin.close(idle[0]); Darwin.close(proxy[0])
        precondition(shared.counters()["producer_active"] as? Bool == false)

        // Socket server shutdown wakes blocked readers and releases only the
        // currently active producer. Use a private test endpoint, never hid.sock.
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("vf-corehid-test-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("test.sock").path
        let server = HIDServer(path: path, receiver: { shared.receive($0) })
        try server.start()
        let idleClient = connect(path), activeClient = connect(path)
        send(header, idleClient); send(snapshot(active: false), idleClient)
        send(header, activeClient); send(snapshot(active: true), activeClient)
        let activeDeadline = Date().addingTimeInterval(2)
        while fake.counts.0 < 5 && Date() < activeDeadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(fake.counts.0 == 5)
        let beforeStop = fake.counts.1
        server.stop()
        let stopped = Date().addingTimeInterval(2)
        while !server.isStopped && Date() < stopped { Thread.sleep(forTimeInterval: 0.01) }
        precondition(server.isStopped)
        precondition(fake.counts.1 == beforeStop + 1)
        Darwin.close(idleClient); Darwin.close(activeClient)
        try? FileManager.default.removeItem(at: directory)
        print("CoreHID shared producers, idle stream, EOF ownership and failed-release recovery passed; OS input submissions=0")
    }
}
