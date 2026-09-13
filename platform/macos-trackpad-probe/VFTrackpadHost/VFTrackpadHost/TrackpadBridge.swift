import Foundation
import IOKit
import Darwin

// The app's signed executable doubles as a headless SSH receiver. The status
// mode opens a user client and reads counters only; it never submits a report.
enum TrackpadBridge {
    private static func message(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
    private static func call(_ connection: io_connect_t, _ selector: UInt32,
                             _ bytes: [UInt8]? = nil) -> kern_return_t {
        if let bytes {
            return bytes.withUnsafeBytes {
                IOConnectCallMethod(connection, selector, nil, 0, $0.baseAddress, $0.count,
                                    nil, nil, nil, nil)
            }
        }
        return IOConnectCallMethod(connection, selector, nil, 0, nil, 0, nil, nil, nil, nil)
    }
    private static func readExactly(_ count: Int, from inputFD: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n = bytes.withUnsafeMutableBytes {
                Darwin.read(inputFD, $0.baseAddress!.advanced(by: received), count - received)
            }
            if n == 0 {
                if received == 0 { return [] }
                throw NSError(domain: "ViewflowTruncatedStream", code: received)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            received += n
        }
        return bytes
    }
    private static func hasNativeMultitouch(_ entry: io_registry_entry_t, depth: Int = 0) -> Bool {
        if IOObjectConformsTo(entry, "AppleMultitouchDevice") != 0 { return true }
        if depth >= 12 { return false }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            let found = hasNativeMultitouch(child, depth: depth + 1)
            IOObjectRelease(child)
            if found { return true }
        }
        return false
    }
    static func run(_ mode: String, inputFD: Int32 = STDIN_FILENO) -> Int32 {
        guard let matching = IOServiceMatching("IOUserService") as NSMutableDictionary? else { return 1 }
        matching["IOPropertyMatch"] = ["IOUserClass": "VFTrackpadRoot",
                                        "CFBundleIdentifier": "org.viewflow.trackpad-probe"]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { message("Viewflow trackpad driver not registered"); return 1 }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == KERN_SUCCESS else {
            message(String(format: "IOServiceOpen failed: 0x%08x (check host DriverKit user-client entitlement and driver version)", opened))
            return 1
        }
        defer { IOServiceClose(connection) }
        var counters = [UInt64](repeating: 0, count: 16)
        var count: UInt32 = 16
        let status = counters.withUnsafeMutableBufferPointer {
            IOConnectCallScalarMethod(connection, 0, nil, 0, $0.baseAddress, &count)
        }
        guard status == KERN_SUCCESS, count == 16, counters[0] == 2 else {
            message(String(format: "Driver status/ABI check failed: 0x%08x", status)); return 1
        }
        if mode == "--driver-status" {
            let status: [String: Any] = [
                "abi": counters[0], "submitted": counters[1], "releases": counters[2],
                "errors": counters[3], "active_contacts": counters[5] != 0,
                "current_contacts": counters[5], "peak_contacts": counters[6],
                "button_transitions": counters[7], "button_down": counters[8] != 0,
                "feature_gets": counters[9], "feature_sets": counters[10],
                "unknown_features": counters[11], "last_feature_request": counters[12],
                "last_report_contacts": counters[13], "last_scan_ticks": counters[14],
                "native_profile": counters[15], "native_multitouch_attached": hasNativeMultitouch(service),
                "status_call_submits_input": false
            ]
            if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }

            return 0
        }
        return receiveStream(inputFD: inputFD,
            submit: { call(connection, 1, $0) }, release: { call(connection, 2) })
    }

    // Injectable calls permit stream/ownership tests without submitting OS input.
    static func receiveStream(inputFD: Int32, submit: ([UInt8]) -> kern_return_t,
                              release: () -> kern_return_t,
                              clock: () -> UInt32 = {
                                  // Native HID wraps at 2^21 milliseconds. Wrap
                                  // here, not at UInt32's unrelated 100 us period.
                                  UInt32(UInt64(ProcessInfo.processInfo.systemUptime * 10_000) % 20_971_520)
                              }) -> Int32 {
        var result: Int32 = 0
        var submitted: UInt64 = 0
        var ownsInput = false
        var waitingForOwner = false
        do {
            guard try readExactly(8, from: inputFD) == Array("VFTP".utf8) + [2, 0, 0, 0] else {
                message("Invalid/missing VFTP version 2 stream header"); return 2
            }
            while true {
                var report = try readExactly(72, from: inputFD)
                if report.isEmpty { break }
                guard report[0] <= 5 else { result = 2; break }
                let active = report[1] != 0 || (0..<Int(report[0])).contains { report[13 + 12 * $0] != 0 }
                // A connected but idle producer does not own the virtual device.
                if !ownsInput && !active { continue }
                // All producers share one native device and its timestamp history.
                // Linux and macOS uptime have different epochs; passing them through
                // makes the driver's backward-time recovery compress real motion
                // to 1 ms per report after a producer handoff. Stamp at this common
                // receiver boundary in ABI-2's 100 us units instead.
                let ticks = clock()
                for byte in 0..<4 { report[4 + byte] = UInt8(truncatingIfNeeded: ticks >> (byte * 8)) }
                let kr = submit(report)
                if kr == kIOReturnExclusiveAccess {
                    if !waitingForOwner { message("HID stream waiting for previous producer release") }
                    waitingForOwner = true
                    continue // Next physical snapshot can acquire after handoff.
                }
                if kr != KERN_SUCCESS {
                    message(String(format: "Touch report rejected: 0x%08x", kr)); result = 2; break
                }
                waitingForOwner = false
                ownsInput = true
                submitted += 1
                if !active {
                    let kr = release()
                    if kr != KERN_SUCCESS { result = 2; break }
                    ownsInput = false
                }
            }
        } catch {
            message("Input stream failed: \(error)"); result = 2
        }
        let released = ownsInput ? release() : KERN_SUCCESS
        if released != KERN_SUCCESS {
            message(String(format: "Touch release failed: 0x%08x; driver retries on close", released))
            result = 2
        }
        message("Viewflow stream ended: \(submitted) reports submitted, release=\(released)")
        return result
    }
}
