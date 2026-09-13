import SwiftUI
import AppKit
import Darwin

@_silgen_name("viewflow_menu_backdrop_probe")
private func runBackdropProbe(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private let termination = TerminationCoordinator()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if termination.isWaiting { return .terminateLater }
        model.stop(persist: false)
        if model.fullyStopped { return .terminateNow }
        termination.begin(poll: { [weak model] elapsed in
            guard let model else { return true }
            model.pollTermination(elapsed: elapsed)
            // Only an explicit application exit uses this cleanup watchdog.
            // OS teardown releases the driver's remaining user-client handles.
            return model.fullyStopped || elapsed >= 6
        }, finish: { sender.reply(toApplicationShouldTerminate: true) })
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main @MainActor struct ViewflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    private let instance: AppInstance
    init() {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments.dropFirst()
        if args.first == "--help" {
            print("Viewflow: open the app to configure connections. Diagnostics: --driver-status; HID relay: --receive-stdin")
            exit(0)
        }
        if args.first == "--network-status", args.count == 3,
           let port = UInt16(args[args.index(args.startIndex, offsetBy: 2)]), port > 0 {
            exit(NetworkProbe.run(host: args[args.index(after: args.startIndex)], port: port))
        }
        if args.first == "--menu-backdrop-probe" {
            exit(runBackdropProbe(CommandLine.argc - 1, CommandLine.unsafeArgv.advanced(by: 1)))
        }
        if args.first == "--driver-status" { exit(TrackpadBridge.run("--driver-status")) }
        if args.first == "--receive-stdin" { exit(HIDServer.relay()) }
        do { instance = try AppInstance() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        WindowGroup("Viewflow", id: "main") {
            MainView(model: model, permissions: model.permissions)
                .onAppear { delegate.model = model }
                .onOpenURL { model.importProfile(from: $0) }
        }.defaultSize(width: 840, height: 620)
        MenuBarExtra("Viewflow", systemImage: "rectangle.connected.to.line.below") {
            MenuContent(model: model)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("打开 Viewflow") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(model.running ? "停止全部连接" : "启动 Viewflow") { if model.running { model.stop() } else { model.start() } }
        Divider()
        Button("退出 Viewflow") { NSApp.terminate(nil) }
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case overview = "连接", permissions = "权限设置", pairing = "配对", diagnostics = "诊断"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "rectangle.connected.to.line.below"
        case .permissions: return "hand.raised"
        case .pairing: return "link"
        case .diagnostics: return "stethoscope"
        }
    }
}

private struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: Permissions
    @State private var page: Page? = .overview
    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                .navigationTitle("Viewflow").navigationSplitViewColumnWidth(180)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text((page ?? .overview).rawValue).font(.largeTitle.bold())
                    switch page ?? .overview {
                    case .overview: overview
                    case .permissions: permissionPage
                    case .pairing: pairing
                    case .diagnostics: diagnostics
                    }
                    if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled) }
                }.padding(28).frame(maxWidth: 740, alignment: .leading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("窗口、输入、剪贴板和触控板，在一个应用里管理。").foregroundStyle(.secondary)
            if model.profile == nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("首次使用").font(.headline)
                        Text("1. 导入配对文件\n2. 按需要开启屏幕录制、辅助功能和 HID 驱动\n3. 启动连接")
                        Button("导入配对文件") { model.importProfile() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            HStack {
                Label(model.profile?.name ?? "尚未配对", systemImage: "desktopcomputer")
                Spacer()
                Button(model.running ? "停止全部" : "启动") { if model.running { model.stop() } else { model.start() } }
                    .buttonStyle(.borderedProminent)
            }
            ForEach(Component.allCases) { component in
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: component.symbol).font(.title2).frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(component.title).font(.headline)
                            Text(model.statuses[component] ?? "已停止").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Toggle(component.title, isOn: Binding(get: { model.enabled.contains(component) }, set: { model.setEnabled(component, $0) }))
                            .labelsHidden().toggleStyle(.switch)
                    }.padding(6)
                }
            }
            Text("“正在运行”表示组件已启动；实际连接和操作效果仍需在两端确认。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var permissionPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("macOS 的授权由你在系统设置中完成。缺少某项权限时，其余功能仍可使用。").foregroundStyle(.secondary)
            permissionRow("屏幕录制", purpose: "用于共享这台 Mac 的窗口。", granted: permissions.canCapture,
                          detail: permissions.screenMessage, action: "打开屏幕录制设置", perform: permissions.requestScreen)
            permissionRow("辅助功能", purpose: "用于接收远程鼠标、键盘和窗口操作。", granted: permissions.canPostInput,
                          detail: permissions.inputMessage, action: "打开辅助功能设置", perform: permissions.requestAccessibility)
            permissionRow("原生触控板驱动", purpose: "用于原生多指手势和 HID 触控板输入。", granted: permissions.driverAttached,
                          detail: permissions.driverMessage, action: "安装 / 更新驱动", perform: permissions.installDriver)
            GroupBox("本地网络") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("首次连接时，如 macOS 询问是否允许访问本地网络，请允许 Viewflow。")
                    Button("打开本地网络设置") { permissions.openSettings("Privacy_LocalNetwork") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Toggle("登录后打开 Viewflow", isOn: Binding(get: { permissions.loginEnabled }, set: permissions.setLogin))
            if !permissions.loginMessage.isEmpty { Text(permissions.loginMessage).font(.caption) }
            Button(permissions.refreshing ? "正在检查…" : "重新检查权限与驱动") { permissions.refresh() }.disabled(permissions.refreshing)
            Text("更改授权后若系统要求退出并重新打开，请照系统提示操作。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func permissionRow(_ title: String, purpose: String, granted: Bool, detail: String,
                               action: String, perform: @escaping () -> Void) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(title).font(.headline); Spacer(); Label(granted ? "已就绪" : "待设置 / 检查", systemImage: granted ? "checkmark.circle.fill" : "circle") }
                Text(purpose).foregroundStyle(.secondary)
                if !detail.isEmpty { Text(detail).font(.caption).textSelection(.enabled) }
                Button(action, action: perform)
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("配对文件把设备身份与连接地址一起导入。").foregroundStyle(.secondary)
            if let profile = model.profile {
                LabeledContent("当前配对", value: profile.name)
                LabeledContent("窗口接收端", value: "\(profile.windowDestinations.count) 台")
                LabeledContent("设备标识", value: profile.deviceID).textSelection(.enabled)
            }
            Text("在已配对电脑上使用导出工具生成 .viewflowconnection 文件，然后在这里导入。更换配对时会先结束旧连接。")
            Button("导入配对文件") { model.importProfile() }.buttonStyle(.borderedProminent)
            Text("配对文件包含设备私钥，请只通过你信任的方式传送。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
            if BundleTools.developmentBuild {
                Text("开发构建：签名、系统权限和 HID 激活需要在正式签名的完整安装包上验证。")
            }
            Button("导出诊断报告") { model.exportDiagnostics() }
            Button("打开日志文件夹") {
                try? FileManager.default.createDirectory(at: BundleTools.logs, withIntermediateDirectories: true)
                NSWorkspace.shared.open(BundleTools.logs)
            }
            Text("诊断报告包含组件状态与权限结果，不包含配对私钥、窗口内容或截图。").foregroundStyle(.secondary)
        }
    }
}
