import Foundation
import CoreHID
import IOKit
import Darwin

private let serial = "Viewflow-UserHID-MT-v1-\(getpid())"
private func record(_ fields: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
        FileHandle.standardError.write(data + Data([10]))
    }
}
private enum ReceiverError: Error { case unsupportedReport, insufficientSpace }

// Feature transactions run independently of the blocking VFTP input reader.
// Share the current DriverKit protocol implementation, including mutable 0xc8.
private actor Features: HIDVirtualDeviceDelegate {
    private let state = vf_features_create()!
    private var gets = 0, sets = 0, errors = 0
    deinit { vf_features_destroy(state) }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {
        sets += 1
        let accepted = data.withUnsafeBytes {
            vf_features_set(state, UInt8(truncatingIfNeeded: id?.rawValue ?? 0),
                            $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        guard accepted != 0 else { errors += 1; throw ReceiverError.unsupportedReport }
    }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        gets += 1
        var bytes = [UInt8](repeating: 0, count: 96)
        let count = vf_features_get(state, UInt8(truncatingIfNeeded: id?.rawValue ?? 0), &bytes)
        guard count > 0 else { errors += 1; throw ReceiverError.unsupportedReport }
        guard count <= maxSize else { errors += 1; throw ReceiverError.insufficientSpace }
        return Data(bytes.prefix(count))
    }
    func counters() -> [String: Int] { ["feature_gets": gets, "feature_sets": sets, "feature_errors": errors] }
}

private func nativeAttached() -> Bool {
    func containsNative(_ entry: io_registry_entry_t, depth: Int = 0) -> Bool {
        if IOObjectConformsTo(entry, "AppleMultitouchDevice") != 0 { return true }
        guard depth < 16 else { return false }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            let found = containsNative(child, depth: depth + 1)
            IOObjectRelease(child)
            if found { return true }
        }
        return false
    }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(iterator) }
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, "SerialNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        if value as? String == serial, containsNative(entry) { return true }
    }
    return false
}

// Only the dedicated reader thread accesses native State. Waiting for an async
// CoreHID submission never blocks a Swift executor or the feature delegate.
private final class Receiver: @unchecked Sendable {
    let device: HIDVirtualDevice
    let state = vf_state_create()!
    init(_ device: HIDVirtualDevice) { self.device = device }
    deinit { vf_state_destroy(state) }
    private static let submit: VFSubmit = { context, bytes, count in
        let receiver = Unmanaged<Receiver>.fromOpaque(context!).takeUnretainedValue()
        return receiver.dispatch(Data(bytes: bytes!, count: count))
    }
    private func dispatch(_ data: Data) -> Int32 {
        let completed = DispatchSemaphore(value: 0)
        // Semaphore establishes completion before the result is read.
        final class Result: @unchecked Sendable { var code: Int32 = KERN_SUCCESS }
        let result = Result()
        Task {
            do { try await device.dispatchInputReport(data: data, timestamp: SuspendingClock.now) }
            catch {
                result.code = kIOReturnError
                record(["event": "report_failed", "error": String(describing: error)])
            }
            completed.signal()
        }
        completed.wait()
        return result.code
    }
    func apply(_ bytes: [UInt8]) -> Int32 {
        let context = Unmanaged.passUnretained(self).toOpaque()
        return bytes.withUnsafeBufferPointer { vf_state_apply(state, $0.baseAddress, $0.count, Self.submit, context) }
    }
    func release() -> Int32 {
        vf_state_release(state, Self.submit, Unmanaged.passUnretained(self).toOpaque())
    }

}

@main struct ViewflowHIDReceiver {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        signal(SIGPIPE, SIG_IGN)
        let serving = args.count == 5 && args[0] == "--serve" && args[1] == "--socket" && args[3] == "--status-file"
        guard serving || args == ["--probe"] || args == ["--driver-status"] || args == ["--receive-stdin"] else {
            print("Viewflow HID receiver: --probe (no input reports), --receive-stdin (VFTP v2 over authenticated SSH)")
            return
        }
        // Lock before creating a device or replacing a stale socket. Two GUI
        // instances must never silently steal each other's shared HID endpoint.
        var serviceLock: Int32 = -1
        if serving {
            let socketURL = URL(fileURLWithPath: args[2])
            do {
                try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { record(["event": "service_failed", "error": String(describing: error)]); exit(1) }
            serviceLock = open(args[2] + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard serviceLock >= 0, flock(serviceLock, LOCK_EX | LOCK_NB) == 0 else {
                record(["event": "service_already_running"]); exit(1)
            }
            try? FileManager.default.removeItem(atPath: args[4])
        }
        defer { if serviceLock >= 0 { close(serviceLock) } }
        var size = 0
        let descriptor = vf_descriptor(&size)!
        let properties = HIDVirtualDevice.Properties(descriptor: Data(bytes: descriptor, count: size),
            vendorID: 0x5ac, productID: 2, transport: .virtual, product: "Viewflow Virtual Trackpad",
            manufacturer: "Viewflow", versionNumber: 0x804, serialNumber: serial,
            extraProperties: ["HIDDefaultBehavior": "Trackpad" as NSString, "ReportInterval": 8000 as NSNumber])
        guard let device = HIDVirtualDevice(properties: properties) else {
            record(["event": "creation_failed", "input_submitted": 0,
                    "hint": "Check the signed executable and embedded profile for com.apple.developer.hid.virtual.device"])
            exit(1)
        }
        let features = Features()
        await device.activate(delegate: features)
        record(["event": "activated", "serial": serial, "input_submitted": 0])
        if !serving && args != ["--receive-stdin"] {
            // Observation deadline only; never a stream or performance cutoff.
            for _ in 0..<30 {
                if nativeAttached() { break }
                try? await Task.sleep(for: .seconds(1))
            }
            let attached = nativeAttached()
            record(["event": "probe_complete", "native_multitouch_attached": attached,
                    "counters": await features.counters(), "input_submitted": 0])
            if args == ["--driver-status"] {
                let status: [String: Any] = ["abi": 2, "native_profile": 1,
                    "backend": "corehid", "native_multitouch_attached": attached,
                    "status_call_submits_input": false]
                if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
                    FileHandle.standardOutput.write(data + Data([10]))
                }
            }
            exit(attached ? 0 : 3)
        }
        let receiver = Receiver(device)
        let shared = SharedInput(apply: receiver.apply, release: receiver.release)
        if serving {
            let server = HIDServer(path: args[2], receiver: { shared.receive($0) })
            let stop = StopRequest()
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { stop.request() }; source.resume(); return source
            }
            defer { for source in signals { source.cancel() } }
            // Parent identity is sampled before waiting. This is process ownership,
            // not a focus or performance deadline; loss of a GUI tears down only
            // its own helper/device.
            let parent = getppid()
            do { try server.start() }
            catch { record(["event": "service_failed", "error": String(describing: error)]); exit(1) }
            let statusURL = URL(fileURLWithPath: args[4])
            while !stop.requested && getppid() == parent && parent > 1 {
                var status = shared.counters()
                status.merge(["backend": "corehid", "pid": getpid(), "owner_pid": parent,
                              "abi": 2, "native_profile": 1, "running": true,
                              "serial": serial, "native_multitouch_attached": nativeAttached(),
                              "status_call_submits_input": false]) { _, new in new }
                status["features"] = await features.counters()
                if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
                    try? data.write(to: statusURL, options: .atomic)
                    _ = chmod(statusURL.path, 0o600)
                }
                shared.retryRelease()
                try? await Task.sleep(for: .milliseconds(200))
            }
            server.stop()
            try? FileManager.default.removeItem(at: statusURL)
            // An explicit process exit may bound cleanup; ordinary stream delays
            // have no cutoff. Device teardown releases contacts even if a native
            // submission cannot finish while the application is exiting.
            let deadline = Date().addingTimeInterval(3)
            while !server.isStopped && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            record(["event": "service_stopped", "clean": server.isStopped])
            exit(server.isStopped ? 0 : 2)
        }
        let result: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(returning: shared.receive(STDIN_FILENO))
            }
        }
        record(["event": "receiver_complete", "counters": await features.counters()])
        exit(result)
    }
}

private final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func request() { lock.lock(); value = true; lock.unlock() }
}
