# 自动 HDMI / Sidecar 路由

Linux 的 `viewflow-display-topology.service` 每轮读取右侧 HDMI 选择记录和 Mac 实时显示器清单，再调整已有连接。Sidecar 通过显示器厂商/产品标识与名称识别；Viewflow 停放屏不会被认作 Sidecar 或主物理屏。

| 右侧选择 | Sidecar | 输入和窗口连接 | Mac 主屏 |
| --- | --- | --- | --- |
| Windows | 未连接 | 仅 Windows | 不改未使用的 Mac 布局 |
| Mac | 未连接 | 仅 Mac HDMI | HDMI |
| Windows | 已连接 | Windows + Mac Sidecar | Sidecar |
| Mac | 已连接 | 仅 Mac，保留 HDMI 和 Sidecar 两个区域 | HDMI |

Sidecar 对应 Linux 的独立 headless 输出与窗口拖动区域。断开后停用该输出而不销毁它；重新连接按实时分辨率恢复。右侧 Mac + Sidecar 使用一条原生 HID 通道跟随两个输入区域，窗口发送端合并两个区域的窗口集合，避免跨区窗口被发送两次。

默认布局保持右侧 `(3072,390,1920×1200)`，Sidecar 在右侧下方 `(3072,1590)`。逻辑大小和原生像素大小分开处理。Mac 主屏原点改变时，输入位置偏移、接收窗口原点、Mac 共享窗口范围及 Linux 反向接收偏移同步调整。用户保存的配对文件不被覆盖。

选择来自现有控制中心按钮成功发送 IR 后保存的 `~/.local/state/hyprv/hdmi-target`。IR 没有实际输入口回读；绕过该按钮使用硬件遥控器时，软件选择记录不会自动更新。Sidecar 的在线状态来自实时 Mac 清单，不使用手工开关。

## 组件

- `tools/display_topology.py`：状态机、服务生命周期、失败重试、运行状态。
- `platform/display-topology/main.swift`：Mac 显示器只读探测，以及按已选拓扑设置主屏/排列。
- `platform/macos-app/Sources/DisplayTopology.swift`：从本机布局状态派生窗口路由，保留原始配对配置。
- `VIEWFLOW_CURSOR_OUTPUT_ORIGIN=X,Y`：光标目标屏在 Mac 全局坐标中的原点，默认 `0,0`。

临时探测/SSH 失败保留已经运行的独立路由并重试；Windows 已被用户选中时，其连接不依赖 Mac SSH 成功。普通切换只停止不再属于新拓扑的连接，不重启整套服务。接收窗口的坐标原点确实变化时，该接收组件正常重连。

Hyprland 新会话不会保留运行时创建的 headless 输出。监督器常驻 systemd 用户会话，在合成器暂时不存在时重试，而不随 `graphical-session.target` 一起退出；启动主输入路由前还会幂等恢复固定名称的 `HEADLESS-1`，并在输出存在但被禁用时先重新启用它。因此注销、合成器原地重启或输入设备短暂失败不会让路由陷入缺少输出的重启循环。

## 部署与检查

1. 编译 Mac helper：`xcrun swiftc -O platform/display-topology/main.swift -o viewflow-display-topology`；安装到 Mac 用户的 `~/.local/lib/viewflow/`。
2. 构建并部署包含 `DisplayTopology.swift` 的 Mac 应用。
3. 构建 `cargo build --locked -p viewflowd --bin vf-cursor-peer`。
4. 使用 `tools/install-display-topology.py --mac-ssh USER@HOST --mac-helper /absolute/path/viewflow-display-topology` 安装 Linux 服务；工具保存覆盖文件与原启用状态，不自动启动监督服务。
5. `python3 tools/display_topology.py --config ~/.config/viewflow/display-topology.json --check` 只读显示拟用拓扑。
6. `systemctl --user start viewflow-display-topology.service` 开始自动调整。

诊断状态：`$XDG_RUNTIME_DIR/viewflow/topology/status.json`；日志：`journalctl --user -u viewflow-display-topology.service`。停止自动调整只需停止该监督服务，当前输入连接不会因此被停止。

安装器按此桌面的已有服务、DP-4、输入设备和配对模板生成覆盖配置；迁移到其他电脑前应核对这些路径。回退资料位于 `~/.local/state/viewflow/topology-backup-*`，其中 `files.json` 记录文件原样备份，`enabled.json` 记录接管前的启用状态。

自动测试覆盖四种模式、Sidecar 分辨率变化、HID 跨区域跟随和非零输入原点。真实硬件热插拔、右侧切换及拖动效果由用户操作验收；服务状态与配置读回不等同于完整输入验收。
