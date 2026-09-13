import AppKit

// terminateLater runs NSModalPanelRunLoopMode. A default-mode Timer or an
// extra Task/main-queue hop can stall forever while AppKit waits for our reply.
@MainActor final class TerminationCoordinator: NSObject {
    private var timer: Timer?
    private var started: TimeInterval = 0
    private var poll: ((TimeInterval) -> Bool)?
    private var finish: (() -> Void)?
    var isWaiting: Bool { timer != nil }

    func begin(poll: @escaping (TimeInterval) -> Bool, finish: @escaping () -> Void) {
        guard timer == nil else { return }
        self.poll = poll; self.finish = finish
        started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
    @objc private func tick() {
        guard poll?(ProcessInfo.processInfo.systemUptime - started) == true else { return }
        timer?.invalidate(); timer = nil; poll = nil
        let reply = finish; finish = nil
        reply?()
    }
}
