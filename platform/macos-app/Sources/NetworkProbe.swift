import Foundation
import Network

enum NetworkProbe {
    static func run(host: String, port: UInt16) -> Int32 {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data([0]), completion: .contentProcessed { error in
                    print("network-probe ready send-error=\(String(describing: error))")
                    fflush(stdout); done.signal()
                })
            case .waiting(let error), .failed(let error):
                print("network-probe blocked error=\(error) reason=\(String(describing: connection.currentPath?.unsatisfiedReason))")
                fflush(stdout); done.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        let completed = done.wait(timeout: .now() + 5) == .success
        if !completed { print("network-probe timed out state=\(connection.state) reason=\(String(describing: connection.currentPath?.unsatisfiedReason))") }
        connection.cancel()
        return completed ? 0 : 1
    }
}
