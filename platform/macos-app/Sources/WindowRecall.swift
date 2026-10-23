import AppKit
import Combine
import Darwin

@MainActor final class WindowRecallController: ObservableObject {
    @Published private(set) var shortcut = UserDefaults.standard.string(forKey: "recallShortcut") ?? "Ctrl+Alt+Shift+H"
    @Published private(set) var status = "正在注册收回窗口快捷键"
    private var process: Process?
    private var log: FileHandle?
    private var desired = true
    private var retryAt = Date.distantPast
    private var previous: String?
    private var restarting = false
    private let logURL = ProfileStore.root.appendingPathComponent("run/window-recall.log")
    var isStopped: Bool { process?.isRunning != true }

    static func canonical(_ input: String) throws -> String {
        let aliases = ["CTRL":"Ctrl", "CONTROL":"Ctrl", "ALT":"Alt", "OPTION":"Alt", "SHIFT":"Shift", "SUPER":"Super", "WIN":"Super", "CMD":"Super", "COMMAND":"Super"]
        var modifiers = Set<String>(), letter: String?
        for part in input.uppercased().split(separator: "+", omittingEmptySubsequences: false) {
            let token = part.trimmingCharacters(in: .whitespaces)
            if let name = aliases[token] {
                guard modifiers.insert(name).inserted else { throw ViewflowError.invalid("快捷键修饰键重复") }
            } else if token.utf8.count == 1, let code = token.utf8.first, code >= 65 && code <= 90, letter == nil {
                letter = token
            } else { throw ViewflowError.invalid("请输入修饰键和一个字母，例如 Ctrl+Alt+Shift+H") }
        }
        guard let letter, !modifiers.isEmpty else { throw ViewflowError.invalid("快捷键需要修饰键和一个字母") }
        return (["Ctrl", "Alt", "Shift", "Super"].filter { modifiers.contains($0) } + [letter]).joined(separator: "+")
    }
    func configure(_ input: String) {
        do {
            let value = try Self.canonical(input)
            previous = shortcut; shortcut = value; desired = true; retryAt = .distantPast
            if process?.isRunning == true { restarting = true; process?.terminate() }
            poll()
        } catch { status = error.localizedDescription }
    }
    func poll() {
        if let child = process, !child.isRunning {
            let message = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            process = nil; try? log?.close(); log = nil
            let wasRestarting = restarting; restarting = false
            if desired, !wasRestarting, !message.contains("recall ready") {
                status = message.isEmpty ? "收回窗口快捷键未注册" : String(message.suffix(400))
                if let old = previous { shortcut = old; previous = nil }
                retryAt = Date().addingTimeInterval(5)
                return
            }
        }
        guard desired else { return }
        if process == nil, Date() >= retryAt {
            do {
                let child = Process()
                child.executableURL = try BundleTools.executable("viewflow-window-recall")
                child.arguments = ["--watch", "--shortcut", shortcut, "--parent", String(ProcessInfo.processInfo.processIdentifier)]
                try ProfileStore.writePrivate(Data(), to: logURL)
                log = try FileHandle(forWritingTo: logURL)
                child.standardInput = FileHandle.nullDevice; child.standardOutput = log; child.standardError = log
                try child.run(); process = child; status = "正在注册收回窗口快捷键"
            } catch { status = error.localizedDescription; retryAt = Date().addingTimeInterval(5); try? log?.close(); log = nil }
        } else if !restarting, process?.isRunning == true,
                  let output = try? String(contentsOf: logURL, encoding: .utf8), output.contains("recall ready") {
            previous = nil
            UserDefaults.standard.set(shortcut, forKey: "recallShortcut")
            status = "收回本机窗口：\(shortcut)（Alt 对应 Option）"
        }
    }
    func perform() {
        do {
            let executable = try BundleTools.executable("viewflow-window-recall")
            // The resident watcher retains the last physical-screen selection.
            // --once requests its local action and never waits for a remote peer.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let child = Process(); child.executableURL = executable; child.arguments = ["--once"]
                let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
                do {
                    try child.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    DispatchQueue.main.async { self?.status = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                } catch { DispatchQueue.main.async { self?.status = error.localizedDescription } }
            }
        } catch { status = error.localizedDescription }
    }
    func stop() {
        desired = false
        if process?.isRunning == true { process?.terminate() }
    }
    func pollTermination(elapsed: TimeInterval) {
        poll()
        if elapsed >= 2, let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
