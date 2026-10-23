import SwiftUI

struct PairingView: View {
    @ObservedObject var controller: PairingController
    @State private var address = ""
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("一个连接组包含一台主机和最多两台从机。主机显示配对码，从机选择主机后加入。")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("本机角色").font(.headline)
                    Picker("本机角色", selection: Binding(get: { controller.role }, set: { role in
                        if !role.isEmpty { controller.send("setRole", role: role) }
                    })) {
                        Text("请选择角色").tag("")
                        Text("主机").tag("host")
                        Text("从机").tag("client")
                    }.disabled(controller.busy)
                    Text(controller.role == "host" ? "由本机管理连接组，等待从机加入。" : "从机只能加入一个主机的连接组。")
                        .foregroundStyle(.secondary)
                    if controller.members.count > 1 { Text("切换角色会退出当前连接组。").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            if controller.role == "host" {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("主机配对码").font(.headline)
                        Text(controller.name)
                        if !controller.code.isEmpty { Text(controller.code).font(.system(size: 36, weight: .medium, design: .monospaced)).textSelection(.enabled) }
                        if controller.members.count >= 3 { Text("连接组已满，最多三台电脑。").foregroundStyle(.secondary) }
                        HStack {
                            Button(controller.code.isEmpty ? "显示配对码" : "更换配对码") { controller.send("showCode") }
                                .disabled(controller.busy || controller.members.count >= 3)
                            if !controller.code.isEmpty { Button("取消") { controller.send("cancelCode") } }
                        }
                        Text(controller.addresses.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            if !controller.groupID.isEmpty {
                Text("当前连接组 · \(controller.members.count)/3").font(.headline)
                ForEach(controller.members) { member in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(member.name).font(.headline)
                            Text("\(member.platform) · \(member.role == "host" ? "主机" : "从机") · \(member.local ? "本机" : member.online ? "在线" : "等待重连")")
                                .foregroundStyle(.secondary)
                            if let address = member.address, !address.isEmpty { Text(address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if controller.role == "host" && !member.local {
                                Button("移出连接组") { controller.send("removeMember", id: member.id) }.disabled(controller.busy)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                HStack {
                    Button { controller.send("disconnect") } label: { Image(systemName: "xmark.circle") }
                        .help("断开连接").accessibilityLabel("断开连接").disabled(controller.busy || controller.paused)
                    Button { controller.send("reconnect") } label: { Image(systemName: "arrow.clockwise") }
                        .help("断开并重新连接").accessibilityLabel("断开并重新连接").disabled(controller.busy)
                    Button(controller.role == "host" ? "解散连接组" : "退出连接组") { controller.send("leaveGroup") }.disabled(controller.busy)
                }
            }
            if controller.role == "client" && controller.groupID.isEmpty {
                Text("附近的主机").font(.headline)
                if controller.machines.isEmpty { Text("正在查找局域网中的主机。也可以在下方输入主机地址。").foregroundStyle(.secondary) }
                ForEach(controller.machines) { machine in PairingMachineRow(controller: controller, machine: machine) }
                Text("手动输入主机地址").font(.headline)
                TextField("主机名或 IP 地址（可带端口）", text: $address).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("主机的六位配对码", text: $code).textFieldStyle(.roundedBorder)
                    Button("加入连接组") { controller.send("connect", address: address, code: code) }
                        .buttonStyle(.borderedProminent).disabled(controller.busy || address.isEmpty || code.count != 6)
                }
            }
            if !controller.warning.isEmpty {
                Text(controller.warning).foregroundStyle(.secondary)
                Button("重试设备发现") { controller.start() }
            }
        }
    }
}

private struct PairingMachineRow: View {
    @ObservedObject var controller: PairingController
    let machine: NearbyMachine
    @State private var code = ""
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(machine.name).font(.headline)
                Text("\(machine.platform) · \(machine.address) · \(machine.count)/3").foregroundStyle(.secondary)
                HStack {
                    TextField("主机的六位配对码", text: $code).textFieldStyle(.roundedBorder)
                    Button("加入连接组") { controller.send("connect", address: machine.address, code: code, id: machine.id) }
                        .buttonStyle(.borderedProminent).disabled(controller.busy || machine.count >= 3 || code.count != 6)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}
