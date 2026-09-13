import Foundation
import Darwin

// The GUI process owns the driver connection. The CLI only transports bytes to
// this private local socket, so stopping the app also releases HID contacts.
final class HIDServer: @unchecked Sendable {
    private let receiver: @Sendable (Int32) -> Int32
    init(receiver: @escaping @Sendable (Int32) -> Int32 = { TrackpadBridge.run("--receive-stdin", inputFD: $0) }) {
        self.receiver = receiver
    }
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var clients = Set<Int32>()
    private var generation = UUID()
    private var activeThreads = 0
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return activeThreads == 0 }
    static var path: String { ProfileStore.root.appendingPathComponent("run/hid.sock").path }

    private static func address() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ViewflowError.invalid("用户目录路径过长，无法建立 HID 本地连接")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }
    private static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = try address()
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    private static func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listener < 0 else { return }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: Self.path).deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.failure() }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var ready = false
        defer { if !ready { Darwin.close(fd) } }
        unlink(Self.path)
        guard try Self.withAddress({ Darwin.bind(fd, $0, $1) }) == 0 else { throw Self.failure() }
        guard chmod(Self.path, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else { throw Self.failure() }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        activeThreads += 1
        listener = fd; generation = UUID(); let token = generation; ready = true
        DispatchQueue.global(qos: .userInteractive).async { [self] in serve(fd, token: token) }
    }
    private func serve(_ fd: Int32, token: UUID) {
        defer { Darwin.close(fd); lock.lock(); activeThreads -= 1; lock.unlock() }
        while true {
            lock.lock(); let liveListener = token == generation && listener == fd; lock.unlock()
            guard liveListener else { return }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 200)
            if ready == 0 { continue }
            if ready < 0 { if errno == EINTR { continue }; return }
            let accepted = accept(fd, nil, nil)
            if accepted < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            _ = fcntl(accepted, F_SETFL, 0)
            _ = fcntl(accepted, F_SETFD, FD_CLOEXEC)
            var noSignal: Int32 = 1
            _ = setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            guard token == generation, listener == fd else { lock.unlock(); Darwin.close(accepted); return }
            clients.insert(accepted); activeThreads += 1; lock.unlock()
            // An idle whole-desktop stream must not prevent proxy-window
            // streams from reaching the driver. Each stream stays ordered.
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                var code = receiver(accepted).bigEndian
                withUnsafeBytes(of: &code) { _ = Darwin.write(accepted, $0.baseAddress, $0.count) }
                lock.lock()
                clients.remove(accepted)
                Darwin.close(accepted)
                activeThreads -= 1
                lock.unlock()
            }
        }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
        for client in clients { shutdown(client, SHUT_RDWR) }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); listener = -1; unlink(Self.path) }
        // The accepting thread closes descriptors after driver release. Avoid
        // closing here: another component could immediately reuse the fd.
    }
    static func relay() -> Int32 {
        do {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw failure() }
            defer { Darwin.close(fd) }
            guard try withAddress({ Darwin.connect(fd, $0, $1) }) == 0 else {
                throw ViewflowError.invalid("请先打开 Viewflow.app 并启动原生触控板 HID")
            }
            return try relay(inputFD: STDIN_FILENO, socketFD: fd)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); return 1
        }
    }
    static func relay(inputFD: Int32, socketFD: Int32) throws -> Int32 {
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                // The owner can close the socket while SSH keeps stdin open.
                // Watch both descriptors so an idle relay exits with its app.
                var events = [pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0),
                              pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)]
                let ready = poll(&events, 2, -1)
                if ready < 0 { if errno == EINTR { continue }; throw failure() }
                if events[1].revents != 0 { break }
                if events[0].revents & Int16(POLLNVAL) != 0 { throw ViewflowError.invalid("HID 输入已关闭") }
                guard events[0].revents != 0 else { continue }
                let count = Darwin.read(inputFD, &bytes, bytes.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw failure() }
                var sent = 0
                while sent < count {
                    let n = bytes.withUnsafeBytes { Darwin.write(socketFD, $0.baseAddress!.advanced(by: sent), count - sent) }
                    if n < 0 { if errno == EINTR { continue }; throw failure() }
                    guard n > 0 else { throw ViewflowError.invalid("HID 本地连接已结束") }
                    sent += n
                }
            }
            shutdown(socketFD, SHUT_WR)
            var code: Int32 = 1, received = 0
            while received < 4 {
                let n = withUnsafeMutableBytes(of: &code) { Darwin.read(socketFD, $0.baseAddress!.advanced(by: received), 4 - received) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ViewflowError.invalid("HID 接收组件已结束") }
                received += n
            }
            return Int32(bigEndian: code)
    }

}
