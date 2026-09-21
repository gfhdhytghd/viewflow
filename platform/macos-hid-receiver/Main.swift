import Foundation
import CoreHID
import IOKit
import Darwin

private let serial = "Viewflow-UserHID-MT-v1"
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
    func run() -> Int32 {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = TrackpadBridge.receiveStream(inputFD: STDIN_FILENO, submit: { bytes in
            bytes.withUnsafeBufferPointer { vf_state_apply(self.state, $0.baseAddress, $0.count, Self.submit, context) }
        }, release: { vf_state_release(self.state, Self.submit, context) })
        // Retained state allows one final release attempt after an I/O failure.
        let released = vf_state_release(state, Self.submit, context)
        record(["event": "stream_ended", "result": result, "release_result": released])
        return released == KERN_SUCCESS ? result : 2
    }
}

@main struct ViewflowHIDReceiver {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args == ["--probe"] || args == ["--driver-status"] || args == ["--receive-stdin"] else {
            print("Viewflow HID receiver: --probe (no input reports), --receive-stdin (VFTP v2 over authenticated SSH)")
            return
        }
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
        if args != ["--receive-stdin"] {
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
        let result: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(returning: receiver.run())
            }
        }
        record(["event": "receiver_complete", "counters": await features.counters()])
        exit(result)
    }
}
