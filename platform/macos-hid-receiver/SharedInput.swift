import Foundation
import IOKit

// One virtual device and one native report history, shared by all socket
// producers. An idle connection does not own the device. The active producer
// retains ownership until lift or disconnect; there is no gesture time limit.
final class SharedInput: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?
    private var pendingRelease = false
    private let apply: ([UInt8]) -> Int32
    private let release: () -> Int32
    private var submitted = 0, releases = 0, errors = 0

    init(apply: @escaping ([UInt8]) -> Int32, release: @escaping () -> Int32) {
        self.apply = apply; self.release = release
    }
    func submit(_ bytes: [UInt8], from producer: UUID) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil || owner == producer else { return kIOReturnExclusiveAccess }
        if pendingRelease {
            let result = release()
            guard result == KERN_SUCCESS else { errors += 1; return result }
            pendingRelease = false; releases += 1
        }
        // Even a partial native submission needs cleanup on error.
        owner = producer
        let result = apply(bytes)
        if result == KERN_SUCCESS { submitted += 1 } else { errors += 1 }
        return result
    }
    func relinquish(_ producer: UUID) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard owner == producer else { return KERN_SUCCESS }
        let result = release()
        if result == KERN_SUCCESS { owner = nil; releases += 1 }
        else { errors += 1 }
        return result
    }
    func disconnected(_ producer: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard owner == producer else { return }
        var result = release()
        if result != KERN_SUCCESS { result = release() }
        pendingRelease = result != KERN_SUCCESS
        if pendingRelease { errors += 1 } else { releases += 1 }
        owner = nil
    }
    func retryRelease() {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil, pendingRelease else { return }
        if release() == KERN_SUCCESS { pendingRelease = false; releases += 1 }
    }
    func counters() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["submitted": submitted, "releases": releases, "errors": errors,
                "producer_active": owner != nil, "release_pending": pendingRelease]
    }
    func receive(_ fd: Int32) -> Int32 {
        let producer = UUID()
        defer { disconnected(producer) }
        return TrackpadBridge.receiveStream(inputFD: fd,
            submit: { self.submit($0, from: producer) }, release: { self.relinquish(producer) })
    }
}
