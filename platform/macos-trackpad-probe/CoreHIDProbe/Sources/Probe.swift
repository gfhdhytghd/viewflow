import Foundation
import CoreHID
import IOKit

func record(_ fields: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
enum ProbeError: Error { case unsupported, insufficientSpace }
actor Features: HIDVirtualDeviceDelegate {
    var pending: UInt8?
    var gets = 0
    var sets = 0
    var failures = 0
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {
        sets += 1
        let reportID = id?.rawValue ?? 0
        record(["event":"set", "id":reportID, "bytes":Array(data)])
        if reportID == 1, data.count >= 2, data[0] == 1, featureValues[data[1]] != nil {
            pending = data[1]; return
        }
        if reportID == 2, data.count >= 2, data[0] == 2 { return }
        failures += 1; throw ProbeError.unsupported
    }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        gets += 1
        let reportID = id?.rawValue ?? 0
        let reply: Data?
        if reportID == 1, let requested = pending, let value = featureValues[requested] {
            let n = value.count - 1
            reply = Data([1, requested, 0, UInt8(n & 255), UInt8(n >> 8)])
        } else { reply = featureValues[reportID] }
        record(["event":"get", "id":reportID, "maxSize":maxSize,
                "reply":reply.map { Array($0) } as Any? ?? NSNull()])
        guard let reply else { failures += 1; throw ProbeError.unsupported }
        guard reply.count <= maxSize else { failures += 1; throw ProbeError.insufficientSpace }
        return reply
    }
    func counters() -> [String:Int] { ["gets":gets,"sets":sets,"failures":failures] }
}
func nativeAttached() -> Bool {
    func containsNative(_ entry: io_registry_entry_t) -> Bool {
        if IOObjectConformsTo(entry, "AppleMultitouchDevice") != 0 { return true }
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        while case let child = IOIteratorNext(it), child != 0 {
            let found = containsNative(child); IOObjectRelease(child)
            if found { return true }
        }
        return false
    }
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &it) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(it) }
    while case let entry = IOIteratorNext(it), entry != 0 {
        defer { IOObjectRelease(entry) }
        if let s = IORegistryEntryCreateCFProperty(entry, "SerialNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
           s == "Viewflow-CoreHID-Native-v1", containsNative(entry) { return true }
    }
    return false
}
@main struct Probe {
    static func main() async {
        let properties = HIDVirtualDevice.Properties(descriptor: nativeDescriptor, vendorID: 0x5ac,
            productID: 2, transport: .virtual, product: "Viewflow CoreHID Native MT Probe",
            manufacturer: "Viewflow", versionNumber: 0x804, serialNumber: "Viewflow-CoreHID-Native-v1",
            extraProperties: ["HIDDefaultBehavior":"Trackpad" as NSString,"ReportInterval":8000 as NSNumber])
        guard let device = HIDVirtualDevice(properties: properties) else {
            record(["event":"creation_failed", "input_submitted":0]); exit(1)
        }
        let features = Features()
        await device.activate(delegate: features)
        record(["event":"activated", "input_submitted":0])
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            if nativeAttached() {
                record(["event":"native_attached", "counters":await features.counters(), "input_submitted":0])
                // Remain alive briefly so the controller can inspect the actual subtree.
                try? await Task.sleep(for: .seconds(30)); return
            }
        }
        record(["event":"probe_complete", "native_attached":nativeAttached(),
                "counters":await features.counters(), "input_submitted":0])
    }
}
