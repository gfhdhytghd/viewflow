# 自动虚拟显示器管理：审计与设计

日期：2026-10-30。阶段：phase 1（只读审计与设计）。
审计基线：`vdisplay` 分支，`badc189d7c9fbdce8672ef0453d67f438ec7d0fa`。
本文描述当前源码，不声称当前安装包、远端驱动或运行中的服务与源码相同。
本文没有实施自动管理器，也没有改变本机或远端的显示、输入、焦点或屏幕捕获状态。

## 1. 结论与约束

用户目标是「虚拟显示器自动管理，并在所有必要时机同步」。当前不存在统一管理器：

- Windows 启动脚本仅同步 DPI；工具本身已有模式、刷新率和位置修改能力。
- macOS 每个 parking worker 创建一个固定几何的 `CGVirtualDisplay`。特殊 HDMI 拓扑工具可以另行移动它。
- Linux 同时有 shell launcher、Python route supervisor 和 HDMI topology supervisor。后两者已有部分恢复能力，但没有统一所有权与实时几何传播。
- Qt 与 Swift 前端启动时读取屏幕。配对每约 3 秒恢复通信，但不会主动重新读取物理屏幕。
- UI 布局可以更新配对记录和部分组件配置；这不等于所有宿主虚拟显示器同步成功。

[AGENTS.md](../AGENTS.md) 与 [安全与可用性指导原则](security-and-availability-policy.md) 是约束。
33 ms 仅是性能目标，不是显示事务的有效期、安全门槛或断开条件。
普通焦点切换、悬停、暂时拥塞和可恢复几何错误不得终止整个会话。
显示目标确实消失时，仅暂停其输入路由，按顺序释放持有的按键和按钮；保留其他连接。
本阶段不得注入输入、改变焦点、捕获屏幕、改变真实显示设置或创建/删除真实输出。
不推送。本文中的 API 调用与测试用例都是未来实现计划，不是本阶段执行命令。

### 1.1 术语与坐标

- `connection_id`：一个 group 内两台设备间的稳定连接标识；不采用进程 PID 或临时端口。
- `display_key`：`host_device_id / group_id / connection_id / purpose / slot`。主机本地管理器据此合并需求。
- `desired`：连接声明的显示需求；不表示 OS 已接受。
- `observed`：宿主重新枚举获得的实际身份、模式、位置、缩放与能力。
- `applied_revision`：宿主读回成功且依赖组件接受的版本；不得把写调用返回成功直接当作完成。
- `native_identity`：当前 OS 对象身份。其生命周期短于 `display_key`，重建后必须更新。
- `pixel_size`：输出物理像素；`logical_size`、`position`：所属宿主桌面的逻辑坐标。
- `scale`：物理像素与逻辑长度的比值；Windows DPI 百分比、macOS backing scale 与 Hyprland scale 通过适配器转换。
- `parking`：承载远程窗口的宿主虚拟显示器；不是接收端代理窗口。

Windows 原生窗口坐标采用 Per Monitor V2 上下文中的实际单位；适配器必须显式转换，
不得假设 `share_bounds` 全部乘除一个全局 scale 就能覆盖混合 DPI。
macOS `CGDisplayBounds` 使用左上原点；`NSScreen.frame` 使用另一坐标约定；统一转换后再发布。
Hyprland `width/height` 是模式像素，`x/y` 是逻辑位置；奇数 transform 必须交换宽高。
`scale` 不代表毫米尺寸推导的 physical DPI，也不得用它反向修改物理显示器。

## 2. 当前所有者与消费者审计

表内行号基于上述基线。函数名用于后续定位。所有运行期结论均为源码检查，未做实机验证。

| ID / 平台 / 用途 | 当前创建者、时机、输入 | 几何消费者 | 当前所有权与退出 |
|---|---|---|---|
| W1 / Windows / 窗口 parking VDD | 已安装的外部签名 `Root\\MttVDD` 驱动产生 monitor。`virtual_display.cpp:116` 的 `wmain(install)` 能注册一个 PnP adapter 并安装外部 INF；常规配对不会调用它。尺寸、数量和初始布局来自驱动/OS 配置 | `pairing_display.py:6` 查 `share_bounds`；`pairing_profiles.py:23` 生成 Windows share backend 参数与对端 presentation origin；`windows-reverse/main.cpp` 按 viewport 枚举/捕获窗口；`runtime.materialize()` 写配置 | 常规会话只使用既有显示器，没有 per-connection monitor 创建/删除账本。工具仅凭显示名称含 `Virtual` 判断候选，不证明是 Viewflow 所有 |
| W2 / Windows / VDD DPI 与模式工具 | `tools/windows_virtual_display_scale.py:75` 的 `sync_scale()` 经现有 SSH 和短命交互登录任务运行 `dpi`；`desktop-autostart-linux.py:297,327` 在 media route 切换或 peer 启动路径触发。scale 来自 Linux monitor；模板指定 Windows device | Windows effective DPI；启动日志读回。该选项不会更新分辨率和位置。独立 CLI 的 `configure`、`transient-*` 可以修改既有显示器模式与位置，详见 §5 | DPI 失败记录日志而保留流。交互任务结束后删除自身与结果文件；不是常驻显示管理器，也不拥有 VDD monitor |
| W3 / Windows / fullscreen DD 预留输出 | `windows-reverse/main.cpp:595` 与 `fullscreen_window_capture.hpp` 使用 `VIEWFLOW_FULLSCREEN_OUTPUT` 选择既有输出；不创建新 monitor | `fullscreen_output_lease.hpp`、DD 捕获、WGC fallback、backing/presentation 坐标与绝对输入转换 | 是既有输出的租用消费者，不是输出创建者。新管理器必须与此租用方协调，不能在 DD/GPU 使用期间改模式或删除输出 |
| M1 / macOS / 每连接 parking | `macos/window_main.mm:142` 解析 `--parking-display W H X Y SERIAL`；`window_parking.mm:72` 的 `run_parking_display()` 建立 descriptor、2x pixel 上限、HiDPI 单模式和位置。Swift `AppModel.swift:283` 为每 link/serial 启动 worker；配对输入来自 peer 屏幕逻辑尺寸及 `share_origin` | `is_parking_display()`、`remote_window_needed()`、`backing_position()`；窗口 inventory、captureScale、destination viewport、输入范围、接收端 presentation origin | vendor `0x5646`、product `0x5746`、serial（配对 slot 1/2）。进程持有 Objective-C 对象；SIGTERM/owner 消失后释放对象。释放时 OS 会把窗口放回剩余桌面。没有动态调整命令 |
| M2 / macOS / Sidecar 与 HDMI、现有 parking 的特殊布局 | Sidecar 由 Apple/用户创建，Viewflow 不创建。`platform/display-topology/main.swift:17` 的 `inventory()` 分类；Linux `display_topology.Supervisor.probe()` 经 SSH 调用 helper。`--apply` 可以调整 HDMI、Sidecar 和 serial 1/2 parking 的位置，并写 `display-topology.json` | Linux remote viewport、native cursor、窗口共享路由；Swift `DisplayTopology.applying()` 更新非配对旧 profile 的 parking 需求、窗口 destinations/receivers、presentation origin | Sidecar 与物理 HDMI 是外部输出；不得当作 Viewflow 创建。当前特殊 helper 会配置物理主屏与位置，属于现有 HDMI-selector 行为，不是通用管理器的默认权限 |
| L1 / Linux / 手动与旧桌面 launcher headless | `desktop-drag-linux.sh:244` 的 `start()` 创建匿名 `HEADLESS-N`，或采用 `--existing-output`；读取当前 physical monitor 与准备后的 `desktop.remote_display`，执行 `hl.monitor` 配置模式/位置/scale 和专用 special workspace | capture producer、`cursor_monitor_id`、输入边界、auto enrollment、native control、窗口共享。启动时复制配置到私有 state | `created-output` 标记区分新建与借用；stop 仅移除标记的新建输出。PID/start token 与 compositor socket 用于恢复。stop/失败清理不是统一事务账本 |
| L2 / Linux / group 与 Sidecar route headless | `multiscreen-input-linux.py:17` 的 `prepare()` 读取 `hyprctl instances/monitors`，按 route/state 复用同 compositor 的 `output.json`，否则复用或创建固定名字 `viewflow-<route>` 的 headless 输出（2026-11-10 起；此前为匿名 `HEADLESS-N`）。按名字识别虚拟输出的代码同时接受 `HEADLESS-` 与 `viewflow-` 前缀。`paired-linux-session.py:43` 选择 physical monitor 一次；GUI group 使用独立 `gui-<local>-<slot>` route | 每 route 的 source config、capture、native cursor 环境、`cursor_monitor_id`；`macos-window-share-linux.py:89` 循环读 routes/config 和 monitor/client inventory | `output.json` 只有 name/instance；进程退出保留输出与窗口。循环每秒重新注册 input route、修复存在输出的几何；没有完整持久删除策略 |
| L3 / Linux / HDMI-selector 主 viewport | `display_topology.py:80` 的 `ensure_primary_output()` 创建固定名称（默认 `HEADLESS-1`）或启用 disabled 输出；`Supervisor.plan/reconcile` 约 3 秒探测 Mac/本地 monitor，输入来自 selector、Mac inventory 与缓存的 Windows remote template | 生成 `right-macos.json`、`sidecar.json`、`linux-receive.json`，服务启动/局部重启、HID routes、窗口 routes、Mac topology 状态 | 此 supervisor 与旧 launcher 共用既有主输出；它按名字恢复，尚无统一创建凭据。Sidecar 消失时可 disable 对应 Linux 输出；没有统一资源引用计数 |
| L4 / Linux / Rust 后端原语 | `crates/viewflow-hyprland/src/lib.rs:193,203` 提供 `create_headless_output()` / `remove_headless_output()`；需 `MutationPolicy::AllowHeadlessOutputs`。全仓调用搜索只有本 crate 测试，未发现生产管理循环使用 | `topology_result():223` 实时枚举 monitor，生成带 instance signature 的 display ID 与 topology generation | 默认 `from_env()` 是 ReadOnly。提供 IPC 原语，不是当前启动时的另一个活动 supervisor；compositor 重启会改变其 display ID |
| A1 / Qt、Python、Swift / 屏幕元数据与布局（不创建输出） | Qt `qt_app.py:76` 只读 `primaryScreen()`；Swift `PairingController.swift:59` 只在启动 helper 时读 `NSScreen.main`。`PairingService.__init__():93` 存 device；host `set_display_position():254` 更新 group 位置 | `display_arrangement.arrange()`、布局 UI、`build_profile/build_group_profile()`、generated component JSON、native args、`runtime.Worker` 和 Swift `ManagedWorker` | 这些是需求/元数据所有者。配对身份、证书和 group 生命周期不应随显示重建而重建 |

### 2.1 格式与恢复差距

1. **Windows inventory 格式不一致。** `virtual_display.cpp:202` 附加 `refresh_hz=...`，
   `pairing_display.py:16` 却用 `re.fullmatch()` 只接受 `X,Y WxH`。
   因而当前源码组合会排除工具正常输出，得到 `share_bounds=None`。
   这是静态格式结论，不证明现有安装包遇到同一故障。必须增加结构化 JSON inventory，兼容旧格式并测试 suffix。
2. **Qt 更新已有局部保留能力。** `qt_app.py:272` 的 `link_signature()` 与
   `paired_connection()` 按 component/config/files 判断复用，不能笼统说每次布局都重启全部进程。
   但引用同一 link 的全部附件仍会扩大某些变更范围，且运行中 native 配置没有统一热更新接口。
3. **Swift 保留粒度较粗。** `AppModel.reconcileGroup():61` 按整个 link 比较，
   几何变化会退役该 link 多个 worker。`worker():158` 对已有 worker 不重新生成 arguments。
   非配对 `tick():197` 虽读 topology 文件，已有 parking 的尺寸变更不会因此自动调用 `applySettings`。
   helper 会移动 parking，但没有调整它的模式；不得把文件更新当成显示同步成功。
4. **L3 恢复不是完整 mode reconcile。** `ensure_primary_output()` 对存在且 enabled
   的输出不比较几何；刚创建后如果 enabled，也不由该函数强制目标模式。
   adopted launcher 启动时另有 `restore_existing_output()`。Sidecar L2 的循环可恢复存在输出的几何，
   但发现输出完全消失时不会在该循环内重新创建；重启 `prepare()` 才会再分配。
5. **配置文件改变不保证消费者热加载。** `macos-window-share-linux.py` 会重读路由并更新
   eligible window 集合，但已运行 capture child 不是自动接受所有新参数。
   `runtime.materialize()` 只是写文件，`Worker.tick()` 只是监督进程；两者都不创建显示器。
6. **驱动源码边界。** 本 worktree 没有 `build/vdd-upstream`、IddCx 驱动源或 IOCTL monitor 服务。
   [旧审计](looking-glass-fullscreen-output-binding.md) 记录过另一份本地驱动源码：
   `FinishInit()` 按配置数量创建 monitors，IO-control callback 注册注释掉。
   该历史记录不能证明当前安装驱动能力。当前可以确认的是仓库工具没有 monitor add/remove 控制接口。

### 2.2 运行期变化矩阵（当前源码）

`无监听` 指没有在上述所有者路径发现完整 reconcile，不代表 OS 不会发通知。
下表把事件覆盖与实际恢复机制分开；OS/驱动特定结果未验证。

| 当前路径 | 本地 scale / resolution 改变 | monitor hotplug | 虚拟输出被 OS/驱动移除 | compositor / WindowServer / 图形栈重启 |
|---|---|---|---|---|
| W1/W2/W3 | DPI 下一次 peer 启动或 route 切换再同步；share bounds/native viewport 不主动重读。fullscreen 租用可局部回退，但不承担显示管理 | 无统一 `WM_DISPLAYCHANGE`/DisplayConfig listener；transient 快照身份不符则拒绝旧事务 | 没有 add monitor 管理循环；仅受影响消费者失败/回退/监督重启，不能凭此恢复 monitor | 没有宿主管理器重新关联 monitor；不得声称组件重启会重建 VDD |
| M1 parking | 创建后固定；peer 元数据变更触发 profile 更新时，配对路径可重启 link worker；不是原对象 mode 热更新 | 没有 reconfiguration callback；窗口 inventory 中部分判断会读取当前 bounds，但 parking 创建参数不跟随 | run loop 只看信号与 owner；没有 display 消失检测。Swift 对象/worker 活着也不证明屏存在 | 没有明确重关联流程；owner/worker 退出后重新创建是进程恢复，不是 WindowServer 恢复保证 |
| M2 Sidecar / helper | L3 下次 probe 使用 Mac 新像素/逻辑尺寸更新 Sidecar 路由；parking 仅位置更新，尺寸仍有差距 | 约 3 秒 probe 重算 Sidecar/HDMI，切换服务并提交 Mac 布局 | Sidecar 本身不重建；L3 disable 对应 Linux viewport、收回对应服务 | helper 每次 probe 新枚举 ID；图形服务不可用时重试，不保证创建 parking 的 worker恢复 |
| L1 legacy autostart | `prepare()` 启动时取 monitor；常驻循环未监听物理几何。adopted 输出在启动时恢复 | 所选 monitor 暂缺时启动等待；运行中无统一 hotplug 重规划 | peer 重启不等于输出重建；残留 state/丢失 output 可能使启动查询失败 | 常驻循环发现 command socket 消失即退出；依赖外层服务重启。下次入口可归档旧实例 state，不是跨实例复用对象 |
| L2 route/group | 每秒按内存旧 `remote_display` 恢复存在输出；没有读新 physical geometry 或配置版本，可能把外部修改改回旧值 | 无完整 physical selection 监听；只在 prepare 时选 monitor | 循环只在 output 非空时修复；缺失不创建。外层脚本重启后 prepare 可创建 | 进程循环没有重新发现 instance/重算全部 socket 和 PID；prepare 再运行才识别新实例 |
| L3 topology | probe 读新 local monitor 和 Sidecar；主 remote 尺寸来自 `__init__()` 缓存模板；enabled 主输出 mode 缺少统一比较 | selector 与 Mac inventory 循环更新 generated configs；不是通用 pairing 拓扑 | 固定主输出缺失可按名字创建；Sidecar 创建仍依赖 layout prepare；所有权证明有限 | 主输出有局部恢复；route socket、插件、worker instance 的端到端重绑定仍不完整 |
| A1 frontend + L4 原语 | Qt/Swift 无屏幕变化订阅；Rust `topology()` 每次读取可反映变化，但无主动传播循环 | 同左；UI 仍使用已存 device | 不负责重建输出 | 无统一重新采样/发布入口；Rust instance ID 随实例变化 |

| 当前路径 | peer 重连且屏幕不同 | UI arrangement 改动 | sleep / resume | user logout |
|---|---|---|---|---|
| W1/W2/W3 | resume 交换 device，但前端未重采样时仍是旧尺寸；W2 重启可更新 DPI，不能创建/调整 W1 模式 | 配对可改配置原点，但不会调用 Windows mode/position 工具；W3 是独立租用消费者 | 无统一恢复事件；旧 DisplayConfig 快照不能直接重放 | DPI scheduled task 需要交互登录用户；无登录时失败。VDD 是驱动资源，不随连接自动删除 |
| M1 parking | device 真改变后可生成新需求并重启 link；没有原对象热更新 | `share_origin` 更新 profile；配对路径的 link 重建会移除/新建 parking，OS 可搬回窗口 | 无显式恢复检测；存活 worker 不代表 CG display 仍有效 | owner 结束则释放对象；新登录 worker 重新创建。WindowServer 生命周期行为需实机验证 |
| M2 Sidecar / helper | 专用 SSH 拓扑独立于 pairing device，下一次 probe 重新枚举 | pairing UI 和专用 selector 没有同一 desired 账本；两方可写不同布局 | probe 重试并更新状态；没有完整 post-wake 原生对象重关联 | SSH/图形会话失效时保留最后路由、重试；不能保证 user service 与图形会话同时退出 |
| L1 legacy | 重启可解析新 peer 地址；remote 几何仍取模板。没有自动屏幕协商 | 配对的 L2 路径见下行；旧模板路径不跟随 UI | 循环继续或服务重启；无专门 wake inventory | compositor socket 消失使进程结束。输出随 compositor 消亡；旧 state 可归档；用户服务重启策略由安装配置决定 |
| L2 route/group | pairing 重建有变化的组件后 prepare 可取新模板；旧进程继续时不重新计算 | Qt 按签名局部重启后 prepare 恢复新几何；对应输出短时保留，其他 link 可复用 | 没有统一 wake 探测；依赖下次 tick/进程恢复 | 输出随 compositor 生命周期结束；route state 记录旧 instance；不在 finally 删除输出 |
| L3 topology | 不协商通用 peer 屏幕；Mac inventory 变化可更新 Sidecar | selector 是它的权威输入；普通 UI arrangement 不接入它 | 下一次约 3 秒 probe 重算；SSH 失败保留路由并执行 Windows fallback | service 使用 user manager，安装为 default target；不能从该 unit 推断严格 logout 清理 |
| A1 frontend + L4 原语 | Python client resume 约 3 秒发送 `self.device`，host 更新 record；host 的 `local_device` 是此前复制值，缺少刷新入口。Swift helper 启动参数也固定 | host normalize/save/apply layout；客户端下一次认证 resume 获取更新；Qt 比较组件，Swift 比较 link | 无统一重采样，已有 pairing 失败不拆 media/input | 配对 group/证书保存在磁盘；GUI worker 退出与输出真正销毁是不同事实；Rust 后端不会主动回收输出 |

### 2.3 安装与生成链路

- `tools/install-display-topology.py:15` 写 supervisor 和 route-specific systemd units/drop-ins，
  启用 supervisor，但脚本说明不启动它。它是现有 selector 特例，不能与未来 manager 双写。
- `tools/desktop-autostart-linux.py:129` 的 `prepare()` 写 runtime config、compositor PID、
  command socket、physical geometry。launcher 的 `windows_virtual_display` 不传给 media schema。
- `pairing_profiles.py:23,146` 的 `build_profile()/build_group_profile()` 将每 link 证书、端口、
  几何和 native args 分开；Linux 为每 slot 生成 route。`runtime.py:102` 的 `materialize()` 展开 token 并写文件。
- Qt `ApplicationModel.activate()` 与 `paired_connection()` 负责 Worker 差异；
  Swift `PairingController` 通过 Python `pairing_helper.py` JSON-lines bridge 收发 group/profile，
  `AppModel` 再管理原生 worker。
- `tools/build-desktop-app.py` 将 scripts、pairing modules 与 `viewflow_virtual_display` 打入 bundle。
  新模块与 helper 命令必须纳入同一 bundle manifest/哈希链，不能只修改开发目录。
- 搜索范围覆盖 `platform/`、`tools/`、`crates/`、安装入口与现有文档。
  EGL headless probe、compositor headless test 与 wallpaper/input 的 “sidecar” 不创建 OS 显示输出，
  不计为另一个 display owner。没有发现 Viewflow 创建 Apple Sidecar 的代码。

## 3. 目标模型：连接声明，宿主协调

### 3.1 需求、能力与实际结果分离

每台宿主在其交互用户会话中仅运行一个 `DisplayManager`。所有 GUI、service、legacy launcher
调用它；不再各自创建同名输出。`host_device_id` 指资源宿主，不必等于 pairing group 的 host role。
初期 Python 公共模型加各平台 adapter；macOS adapter 在 Swift/ObjC worker 内实现同一 JSON 契约。

以下是**待实施 schema**，不是现有协议字段。示例值仅用于说明单位。

```json
{
  "version": 1,
  "display_key": "host/group/connection/parking/1",
  "host_device_id": "host-device-id",
  "connection_id": "stable-pair-id",
  "revision": 7,
  "purpose": "parking",
  "presence": "present",
  "source_screen_id": "peer-physical-screen-id",
  "pixel_size": [3840, 2160],
  "logical_size": [1920, 1080],
  "scale": 2.0,
  "position": [1920, 0],
  "refresh_millihz": 60000,
  "mode_policy": "follow_peer",
  "ownership": "managed"
}
```

`observed` 必须另含 `native_identity`、`incarnation`、实际像素/逻辑 bounds、scale、
refresh、`inventory_generation`、`applied_revision`、capabilities 和 `pending/error`。
能力至少区分 `create_monitor`、`remove_monitor`、`resize`、`reposition`、`set_scale`、
`requires_recreate`。不支持的字段返回 `unsupported` 和实际结果，不能默默舍入后宣称同步完成。
`presence=absent` 只删除本连接声明；多个连接/租用消费者仍引用该输出时不得删除资源。
共享 parking 只允许需求完全相同且映射明确的连接；默认每 connection/purpose 独立分配。

### 3.2 同步方向与冲突规则

| 数据 | 权威来源 → 接收者 | 变化后的行为 |
|---|---|---|
| peer 物理屏幕像素、逻辑尺寸、scale、rotation、refresh、稳定 screen ID | 屏幕所在设备 observer → 认证 pairing → 资源宿主 manager | `follow_peer` 需求重新计算；不从已创建 virtual screen 再反推 peer 物理屏，防止反馈环 |
| 连接组屏幕相对位置 | group host 的 `set_display_position()/arrange()` → 各连接需求 | position 是组内逻辑布局；adapter 转为宿主原点；显示 manager 读回 actual 后更新 input/capture |
| 宿主实际 mode、位置、scale、身份、能力 | 宿主 OS → manager → pairing 状态、依赖组件、UI | actual 始终如实发布。managed 输出外部变更后恢复最新 desired；不把旧 actual 自动改写为 peer 需求 |
| 外部输出（Sidecar、physical、非 Viewflow VDD） | OS/用户 → observer | 默认只读跟随；不创建/删除。明确配置的 borrowed 输出可以调整连接所需模式，退出仅恢复自己改过且身份未变的字段 |
| 断开与重新加入 | group 连接状态 → manager | 网络暂断保留需求与输出；显式离组/关闭功能才释放引用。重连不同屏幕更新同一 key，不分配重复输出 |

默认选择实际物理 primary screen，后续保留明确选中的 stable screen ID；不得把 Viewflow
新输出选成自己的 source。选中物理屏消失时发布 unavailable，暂留其最后需求。
如果另一物理屏成为 primary，自动改用它并发布新 screen ID。没有物理屏时不得拿零尺寸覆盖需求。
用户固定模式以 `mode_policy=fixed` 表达；peer 变化只更新实际元数据，不覆盖固定需求。
旧 HDMI-selector 明确的主屏行为单独保留为 `legacy_selector` 策略；通用 manager 不默认继承它。
同一输出仅一个 writer；迁移时旧脚本交出创建/配置职责，不能与 manager 相互“修复”。

### 3.3 身份、所有权与清理

宿主按登录会话加互斥锁，账本原子写入应用数据目录。连接结束不会删除账本的故障证据。
记录 `display_key`、创建操作 ID、OS identity、创建前 inventory、原模式、引用者、最后成功版本。
每次操作先写 intent，再调用 OS，最后读回写完成；进程在两步之间退出后，可用 inventory 恢复。

- Linux 稳定命名为 `VF-<key digest>`，另记 compositor instance signature、PID/start time、
  实际 monitor ID 与 incarnation。名字不是删除权证明；新实例先重新枚举，再创建本实例资源。
  创建前已存在同名对象且账本无法证明来源时，标记 collision，分配另一个名字并保留原对象。
- Windows 用 PnP adapter instance、monitor device path、connector/EDID serial 与宿主账本关联。
  adapter LUID、source/target ID、`DISPLAYn` 都是当前 inventory 的运行期映射，不能单独作跨重启主键。
  外部预装 MttVDD monitor 默认为 borrowed；`install` 注册 adapter 不等于拥有其每个 monitor。
- macOS 用应用 vendor/product、分配后持久保存的 serial 和 live `displayID`/对象 handle 关联。
  新 manager 初期保留已有 slot serial 1/2 的兼容映射，后续扩容再协商；不得仅凭 vendor/product
  删除其他 Viewflow 进程持有的对象。应用内同一 serial 只有一个所有者。

移除时：停止分配新 capture、排空已开始的 GPU/帧任务、释放该路由按键、解除引用，
再释放自己创建的对象。borrowed 输出不得 remove；恢复前重新确认身份及字段未被外部另改。
窗口仍在输出上时，必须记录 OS 移屏后果；先使该连接的 capture/presentation 可恢复，再删除。
不得通过隐藏、移动无关窗口或切换用户焦点来“验收”清理。
用户 logout 时，仅关闭本登录会话的引用和通知源。OS 已销毁的对象记为 absent；不向下一次登录
重放旧 `DISPLAYn`/displayID/monitor ID。机器级驱动不随任意连接注销而卸载。

### 3.4 reconcile、去抖与失败恢复

```text
事件/认证状态更新/启动/唤醒/安全检查
  → dirty(display_key)
  → 合并最新 revision，枚举实际 inventory
  → plan(desired, observed, capabilities, ownership, references)
  → 串行执行该宿主的必要操作
  → 读回 actual + identity
  → 发布 geometry revision 到依赖组件
  → 消费者确认；登记 applied_revision；无差异时不写 OS
```

每宿主串行执行原生拓扑事务；无关输出的需求计算与连接通信独立。
默认去抖 200 ms，连续事件的最长合并等待 1 s；这些是调度参数，不是会话期限。
OS 回调只排队，不在回调栈中改显示。写引起的事件也重新枚举，actual 相等就停止，不形成循环。
低频检查默认 10 s，带 ±20% jitter；启动、恢复和事件 socket 重连立即枚举。
一次 inventory 失败不等于空列表，不得据此批量删除输出。

每 key 重试退避为 0.5、1、2、4、8、16、30 s，随后最大 30 s 并加 jitter。
新 desired revision、wake 或原生能力变化时立即重新计划。永久不支持的模式只报告能力差距，
等待新的需求/能力，不重复安装驱动或忙循环。同一目标重复执行必须无新增对象、无重复 worker。
保存并区分 `desired_revision`、OS 写成功、读回成功、消费者接受；失败不能提前发 applied。

超时仅结束无响应的该次 helper/操作，标记结果未知并重新枚举，不能关闭整个组。
若旧操作迟到完成，不再启动并发反向写；收集完成结果后依据最新 desired 再协调。
回滚只能覆盖本事务改过、身份相同且没有外部变更的字段；不能恢复整机旧布局覆盖刚插入的新屏。
保留最后完整画面，丢弃过时帧，等待当前 revision 的完整帧/关键帧。
窗口与连接身份不因显示 incarnation 改变而重建。

### 3.5 依赖传播与局部重连

对每个 display_key 建依赖集合：捕获 viewport、输入坐标变换、native cursor、share bounds、
presentation origin、pairing device info、arrangement UI、DD reserved-output lease。
只有 readback 的实际几何进入下一阶段，不能先把期望几何当成真实路由。

1. 冻结该路由的旧几何切换点；按现有可靠输入顺序结束旧坐标域的事件并释放持有状态。
2. 在输出 adapter 读回后生成一个不可变 geometry snapshot；capture/input/presenter 使用相同 revision。
3. 更新对应 producer 的 viewport、cursor monitor ID、presentation origin 和 scale；
   区分 output topology、capture surface size、codec config 三类变化，按需增加已有 generation。
4. 新模式改变像素缓冲尺寸时排空旧 in-flight 工作，重建该 capture/encoder 资源并请求关键帧。
   原点平移且缓冲尺寸不变时仅更新变换；不得把它扩展成关闭 clipboard、HID receiver 或别的 link。
5. 消费者确认匹配 revision 后恢复该路由；过时更新与旧帧不能覆盖新映射。

配对 revision 不是现有 atlas `geometry_epoch` 的同义词。
`pairing_profiles.py` 目前把 `geometry_epoch/config_generation/topology_generation` 初始化为 1；
热更新时由对应运行组件单调推进自己的代次，不在每次 profile rebuild 中重置成 1。
现有窗口 `DomainControl::Geometry` 描述窗口几何，不能冒充完整的 display 生命周期消息。

初期没有热更新接口的 native 组件，只替换依赖的 capture/input/presentation 子进程，保留连接组和
无关 worker；长期沿已有认证 control stream 增加经过能力协商的组件内几何更新。
只有 native display identity/捕获坐标原点或其配置确实变化、且组件不能热接纳时才局部重连。
纯 UI 标签/online 状态、相同快照、重复通知不得重启组件。
DD 租用方进入局部 WGC fallback 并排空 lease 后才允许模式变更；不得强行回收活跃 GPU 对象。

## 4. 认证通道与兼容协议

### 4.1 首选现有 pairing resume，不新开端口

现有 `pairing_protocol.Channel` 是 SPAKE2 派生的 AES-GCM 双向有序 envelope。
首次配对用六位码；恢复使用已保存的 pair secret。`PairingService._connect()` 的 client 发请求，
`_serve()` 的 host 回应；每次 resume 是短连接，不是已有的服务端推送长连接。
`_resume_loop()` 约每 3 秒重复，暂时失败保留 media/input。

**决定：** 管理面第一版复用这个认证请求/响应通道。保持 pairing `VERSION=2` 和现有顶层字段。
新字段先作为可选 capability 广告；只有双方显式支持后才发送扩展状态。discovery 的 TXT 仅作发现提示，
不得凭 mDNS、裸 IP 或 selector 文件接收远端显示创建命令。显示更新不重新配对、不轮换证书。

待实施扩展位于认证 request/response 的可选 `display_management` 对象：

| 字段 | 语义与版本规则 |
|---|---|
| `version: 1`、`capabilities` | 支持 `inventory-v1`、`desired-v1`、`applied-v1`；缺字段视为 legacy；未知子版本不启用扩展 |
| `inventory_revision`、`session_incarnation`、`screens` | 仅屏幕所在设备声明实际物理/外部屏幕；每条带 stable ID、kind、pixel/logical bounds、scale、rotation、refresh。incarnation 改变后新建接收基线，旧 session 消息失效 |
| `layout_revision`、`desired` | group host 规范化布局版本与每连接需求；host role 不等于显示资源宿主，宿主只执行指向自身且属于该认证连接的需求 |
| `applied` | 每 key 的 desired revision、actual/native identity 摘要、能力、错误、消费者接受状态；不传私钥或远端 shell 配置 |
| `ack_revision` | 确认收到最新状态，重传幂等；这不是逐输入事件回执，也不阻塞普通输入往返 |

每连接只接受单调 revision；旧 session 的计数不能压过新 session。
屏幕/需求数组有数量和编码大小上限，沿用 128 KiB 消息上限；超限只拒绝该更新。
所有数字必须 finite、维度正值、scale 与单位一致；值域依据双方实际 adapter/codec capability 取交集，
不增加额外焦点、捕获新鲜度或性能时限门槛。

host 更新本地屏幕时必须同时刷新 `self.device`、group member 与每条 record 的 `local_device`，
保留每 link 的 ports、证书、slot 和 share origin。client inventory 同样刷新其 record，
再由 host normalize 布局并回传。manager 的 actual 放在扩展中，不能冒充 peer 的物理 `display`。
`update_local_display(snapshot)` 必须在锁内验证/更新，再 emit/wakeup，不直接调用全组 disconnect。
Swift 用 JSON-lines `updateDisplay` action 调用同一方法，不能重启 pairing helper 来更新屏幕。

client 本地变化可唤醒 resume。host 本地变化和 UI 修改在下一次 client poll 回应中发出；
正常无错误时状态传播延迟包含至多一个既有约 3 秒 poll 周期，再加原生协调时间。
不宣称亚帧即时同步。后续如要求更低延迟，可以在同一认证 pairing 连接协商长轮询，
或协商后经既有 mTLS QUIC reliable control stream 发 `display-state-v1` 提示；
其唯一权威快照仍来自同一 manager，不能双通道各自改 desired。

### 4.2 旧端行为

- 缺 capability 时保持原 `display/share_bounds/share_origin/share_serial` 字段和既有启动行为。
  不向旧端发送新 enum/control 消息，不把扩展塞入可能严格反序列化的 media config。
- 新 host + 旧 client：现有 polling/布局仍运行；标记该 link 无 live inventory，
  不声称知道 peer 的实时物理屏幕。新 manager 可以恢复自己已有的本地资源。
- 新 client + 旧 host：认证交换成功后继续原协议；不要求重配对，也不执行远端未确认的 desired。
- 两端支持时，legacy device 字段仍填当前主屏摘要，扩展携带精确多屏实际状态。
- 旧 Windows textual inventory 同时兼容有/无 `refresh_hz`；新版优先 JSON，不靠名称猜所有权。

## 5. 各平台实施计划

### 5.1 Windows：先区分 mode 与 monitor 生命周期

`platform/windows-reverse/virtual_display.cpp` 当前能力：

| 命令/入口 | 当前能力 | 自动管理的使用方式 |
|---|---|---|
| 无参数、`modes DISPLAY` | 枚举 device/current mode 与支持模式 | 增加 `inventory --json`、stable identity、DPI、能力；保留旧文本输出 |
| `install INF` | 创建一个 PnP instance，加载外部签名驱动；安装失败尝试移除该 instance | 安装生命周期与会话协调分离。不能按每连接重复安装 adapter，更不能把它声称为 per-monitor add |
| `configure DISPLAY X Y W H` | 对既有 virtual adapter 执行 CDS_TEST，再持久设置模式/位置，固定 60 Hz | 不作为自动临时协调的默认入口；无精确 readback/所有权账本 |
| `primary DISPLAY` | 平移全部 active 输出并设置 primary，验证失败回滚 | 通用管理器不调用；此命令会影响其他输出 |
| `dpi DISPLAY [PERCENT]` | 查询/设置已支持的离散有效 DPI，使用 DisplayConfig 源 ID 与内部 `-3/-4` packet | 仅在 owned/明确 borrowed 输出上使用，报告 unsupported；私有 packet 需逐 Windows 版本验证 |
| `test-refresh` / `refresh` | 测试/临时改变既有输出 Hz，读回 | 集成进一次 mode 事务，避免独立 setter 相互覆盖 |
| `transient-backup/test/apply/restore` | 保存版本化全布局身份/DEVMODE；只改已选 active non-primary virtual 输出；无 registry/primary 写；读回并检查其他输出 | 复用 `inventory()/change()/restore()` 与 `virtual_display_transient_checks.hpp`；每个计划取新基线。不得无限复用旧全布局备份 |

`ChangeDisplaySettingsEx` 可以选择驱动已经支持的模式，不会替驱动创建 monitor 或增加任意 mode。
[Microsoft IddCxMonitorArrival](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/iddcx/nf-iddcx-iddcxmonitorarrival)
规定 driver 在 `IddCxMonitorCreate` 后报告 arrival；
[IddCx 对象生命周期](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iddcx-objects)
说明断开/重连需 departure/arrival。这证明框架有接口，不证明 MttVDD 已暴露它。
[IddCxMonitorUpdateModes](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/iddcx/nf-iddcx-iddcxmonitorupdatemodes)
支持 driver 更新 mode list；HDR 使用
[UpdateModes2](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/iddcx/nf-iddcx-iddcxmonitorupdatemodes2)，
其版本/FP16 要求需驱动确认。

实施顺序：

1. 增加结构化 inventory/capabilities 和 Windows adapter；借用现有 active VDD 可自动调整支持的 mode/位置/scale。
   输出不足时保持其他连接，标记该需求 `unsupported/create_monitor`；预配置 pool 不是完整自动创建的验收。
2. 建立交互用户会话常驻 observer，隐藏的普通 top-level window 接收
   [WM_DISPLAYCHANGE](https://learn.microsoft.com/en-us/windows/win32/gdi/wm-displaychange)，
   同时考虑 device-change、DPI/settings、session 与 power 通知，再 `QueryDisplayConfig`/`DisplayConfigGetDeviceInfo` 全量枚举。
   单靠 WM_DISPLAYCHANGE 的分辨率参数不能重建多屏拓扑，message-only HWND 也不能假定收到广播。
3. 把 observer/mutation helper 放在同一个交互会话中。SSH Session 0 不是显示操作宿主；
   迁移 `startup_script()/sync_scale()` 为现有认证管理通道的兼容包装，避免每次 tick 创建 scheduled task。
4. 完整自动创建需要新增有固定版本与 monitor identity 的 driver control backend。
   当前 worktree 缺少 driver 源：先明确依赖的签名 driver 包/版本及控制 ABI，再添加用户态 add/remove/query
   和 driver 侧 arrival/departure/mode-list 更新。不可编造现有 IOCTL，不重启全 adapter来模拟局部 hotplug。
   该能力缺失时如实降级，不影响其他输出。签名部署是后续 Windows 实机门槛。
5. mode setter 与 readback 重新检查当前 DisplayConfig identity；本地 API 无原子身份+模式事务，
   继续保留紧邻调用前检查、调用后全量读回与局部恢复；不得把短小 race 隐藏成已证明原子性。
   primary VDD 的 transient helper 现不支持，返回能力差距；不能自动平移全桌面绕过。

[transient 文档](virtual-display-transient-mode.md) 记录过具体 mode apply/restore 实验，
那是历史证据，只覆盖所列输出/模式。它不是本次 Windows 运行证明或任意热插拔验收。

### 5.2 macOS：对象存活时调整，必要时局部重建

- 将 `run_parking_display()` 拆成 `ParkingDisplay` 对象与 `observe/apply/release` 操作。
  保留 descriptor、live object、serial、maxPixels 和 geometry snapshot；加入版本化本地 JSON command/status
  或现有 worker control pipe，Swift 不再只传一次 CLI 参数。
- 同一 descriptor 容量内尝试 `applySettings` 更新 mode list/HiDPI，重新枚举并选择/确认实际模式；
  位置独立使用 `CGBeginDisplayConfiguration`、`CGConfigureDisplayOrigin`、
  `CGCompleteDisplayConfiguration(kCGConfigureForSession)`，保持非目标显示不变。
  [Apple origin 文档](https://developer.apple.com/documentation/coregraphics/cgconfiguredisplayorigin(_:_:_:_:))
  说明系统可调整请求位置，因此 readback actual 是必要步骤。
- `CGVirtualDisplay` 是私有动态 API。源码只证明初始化时调用过 `applySettings`，
  [Chromium 参考实现](https://chromium.googlesource.com/chromium/src/%2B/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)
  同样展示私有接口与初始化，不证明所有 macOS 版本能原位切换任意 mode。
  超过 `maxPixelsWide/High`、对象消失、或 apply/readback 不成功时，只重建本 key 对象。
  同一 serial 不并存两个 display；先保留 presentation/窗口映射并排空对应 capture，再 release/create，
  更新 incarnation、displayID、SCK/filter 和 native input mapping；不重启其他 serial/clipboard/HID。
- 初期保留当前 HiDPI 2x 能力。peer scale 为 1.25/1.5 时按 logical viewport + captureScale 适配，
  如实报告 native 2x 与 requested scale 的区别；不得声称原生 CG display 能表示任意分数 backing scale。
- 用 `CGDisplayRegisterReconfigurationCallback` 标记 dirty，结束配置通知后在串行队列枚举，
  以 vendor/product/serial 重新找 live ID；
  [Apple callback 文档](https://developer.apple.com/documentation/coregraphics/cgdisplayreconfigurationcallback)
  明确不得在回调内改 display configuration。退出注销 callback。
- `PairingController.start()` 改为 physical screen observer。订阅
  `NSApplication.didChangeScreenParametersNotification` 与 workspace wake/session 通知，
  经 `pairing_helper.py` 的新 `updateDisplay` action 发布快照，保留 pairing helper。
- `AppModel.reconcileGroup()/worker()/tick()` 将 parking 与其他 link worker 分开比较；
  原点变化仅更新依赖方。`DisplayTopology.applying()` 和 `platform/display-topology/main.swift`
  改为向 manager 提交 `legacy_selector` 需求；外部 Sidecar 只枚举，不由 generic adapter 创建/删除。

### 5.3 Linux/Hyprland：统一 writer 和实例恢复

- 新增 `tools/virtual_display_hyprland.py` 的 `inventory/plan/apply/watch` adapter。
  `desktop-drag-linux.sh start/cleanup`、`multiscreen-input-linux.prepare()`、
  `display_topology.Supervisor.reconcile()` 改成 acquire/update/release 同一 manager 引用。
  采用固定 `VF-...` 名字；旧 `HEADLESS-N` 必须凭旧 state + 当前 instance 显式迁移为 borrowed/managed，
  不能删除所有以 HEADLESS 开头的 monitor。
- 创建调用现有 `hyprctl output create headless NAME`，resize/reposition/scale 使用
  当前项目已有的 `hyprctl eval 'hl.monitor({...})'`。应用后用 `hyprctl -j monitors all` 比较实际模式、
  transform、位置、scale、enabled；只在有差异时写。保留专用 special workspace 的明确 `type=special`
  与 `follow=false` 逻辑，不用 focus dispatch 维护输出。测试使用与 bundle 对应的 Lua ABI。
- 监听 `$XDG_RUNTIME_DIR/hypr/<instance>/.socket2.sock` 的 `monitoradded`、`monitorremoved`、
  `monitoraddedv2/monitorremovedv2`（实例支持时）、`configreloaded`，见
  [Hyprland IPC](https://wiki.hypr.land/IPC/)。事件仅作为重新枚举提示，名称变化/scale 变化不能仅靠事件 payload。
  实际事件集合依当前 fork；漏事件由 10 s 检查补齐。
- socket EOF、instance/PID 变化时重新发现当前用户 compositor，重建 command/event socket 与插件 route。
  重算 `compositor_pid`、`cursor_monitor_id`、physical geometry 和 native control 路径；
  不复用上一个实例的 monitor 数字 ID。插件不匹配时报告该 adapter 不可用，不能自动重载用户 compositor。
- `desktop-autostart.prepare()` 的纯配置生成与运行期 reconcile 分离；
  `paired-linux-session.py` 不再永久缓存选中 physical monitor。
  Sidecar config 变化必须重新读取/增量提交，不能每秒用旧内存配置“修复”回旧值。
  `display_topology.ensure_primary_output()` 的 enabled 路径也必须比较实际几何。
- 现有 Rust `HyprlandBackend` 可以继续作为 inventory 与 headless IPC 原语，
  不再另启一个资源所有者。其 mutation opt-in 是调用 API 的约定，不增加产品配对/焦点限制。
  capture、cursor、media 若无原位更新入口，由每 route 的子进程替换承接新 snapshot。

### 5.4 桌面应用与协议编排

- 新建 `platform/desktop-app/display_management.py`：纯 desired/observed schema、planner、
  所有权账本、引用计数、去抖/退避和 dependency diff。native adapter 通过 JSON 契约与它交互。
  manager 在本机 GUI 或同用户 service 中择一拥有锁；第二入口连接现有 manager，不另起 writer。
- 新建 `display_observer.py`，在 `ApplicationModel.__init__()` 绑定
  [QGuiApplication](https://doc.qt.io/qt-6/qguiapplication.html) 的 `screenAdded/screenRemoved/primaryScreenChanged`，
  为每个 [QScreen](https://doc.qt.io/qt-6/qscreen.html) 绑定 `geometryChanged`、
  `logicalDotsPerInchChanged`、`physicalDotsPerInchChanged`、`orientationChanged`、`refreshRateChanged`。
  Qt 无独立通用 `devicePixelRatioChanged` screen signal，收到通知后重读 DPR；低频检查兜底。
  removed screen 先解绑；不保留失效 QScreen 引用。Wayland native monitor data 优先用于输出实际几何。
- `PairingService.update_local_display()` 更新全部派生 device，不改变 link ports、密钥和 identity。
  `_connect/_serve/_resume_loop` 协商并传播扩展；`pairing_protocol.validate_device()` 保留旧 schema，
  新扩展单独验证。`pairing_helper.py` 加更新 action，Swift 使用相同协议。
- `pairing_profiles.build_profile/build_group_profile()` 从成功读回的 snapshot 派生几何；
  desired 可预先存在但资源未就绪时仅等待该 component，不使 profile 变成 None 而清空全部组。
  UI 同时显示 requested/actual/error；不要求用户手动重启来刷新元数据。
- `runtime.materialize()` 保持原子文件写入，新增按内容 diff；`Worker` 增加局部 update/restart 接口。
  `qt_app.link_signature()/paired_connection()` 保留无关 component；禁止配置准备失败调用全局 stop。
  生成配置必须在对应消费者切换时提交，防止活跃 worker 读到别的 revision。

## 6. 四个独立工作包

本阶段仅定义工作包，不启动实施代理。公共 JSON 契约与上述单位/版本规则作为并行实现的冻结边界。
各包先用 fake adapter/channel 开发，最终由 P1 集成。文件所有权如下，跨包需求通过接口提交，
不得由多个包同时改 `pairing_profiles.py`、bundle manifest 或协议文件。

| 包 | 独占文件/入口 | 输出与边界 | 无 live input 的验收 |
|---|---|---|---|
| P1 公共模型、配对与 Qt 编排 | 新 `platform/desktop-app/display_management.py`、`display_observer.py`；`pairing_protocol.py`、`pairing_service.py`、`pairing_profiles.py`、`pairing_helper.py`、`runtime.py`、`qt_app.py`、对应 Python tests；最终统一修改 `tools/build-desktop-app.py` 打包各 adapter | desired/observed planner、账本、引用计数、revision、双端兼容、Qt observer、按依赖局部 worker 更新。提供 fake adapter/JSON fixtures 给 P2–P4；不写平台 OS setter | fake clock/channel/process：重复 desired 零写入；100 次事件合并；丢通知由 slow check 收敛；过期 revision 不回退；借用输出永不 remove；一条失败不停止另一 link/clipboard；geometry 不重置证书/ports；host/client 都刷新 device 副本；新旧端四组合；坏扩展/NaN/超限仅拒绝更新；missing output 不产生全组 None；Qt screen remove 正确解绑 |
| P2 Linux adapter 与现有脚本迁移 | 新 `tools/virtual_display_hyprland.py`；`desktop-autostart-linux.py`、`desktop-drag-linux.sh`、`multiscreen-input-linux.py`、`paired-linux-session.py`、`display_topology.py`、`install-display-topology.py`、`macos-window-share-linux.py`、对应 tools tests；必要时 `crates/viewflow-hyprland` 的 inventory/IPC helper | 一宿主 writer、named output、socket2 observer、compositor incarnation、legacy selector adapter；不改 P1 pairing/schema、Windows/mac native。向 P1 交付 packaging 清单 | fake hyprctl/socket2/systemctl：create/resize/reposition/remove 幂等；输出丢失重建；enabled 错模式修复；Sidecar 出入只改对应 route；compositor 重启更换 socket/ID；借用输出保留；同名外部输出保留；旧 template 不覆盖新 revision；一个 SSH probe 失败保持 Windows 路由；所有命令无 focus/input；现有 launcher/topology 测试回归 |
| P3 Windows adapter、inventory、driver 能力边界 | 新 `platform/windows-reverse/virtual_display_manager.*` 与 portable planner/checks；`virtual_display.cpp`、`virtual_display_transient.hpp`、对应 C++ tests/CMake；`platform/desktop-app/pairing_display.py` 与解析测试；`tools/windows_virtual_display_scale.py` 及测试；Windows producer 的 output lease/geometry 接口（确有需要时） | JSON inventory、交互会话 observer、transient setter、实际身份映射、DPI 能力；driver control 独立 backend。缺驱动源先交付 unsupported backend，不冒充完整自动 hotplug；不改 P1 Python 协议、不改 P2 launcher | portable C++ fake DisplayConfig/driver：同名身份替换、不支持模式、hotplug 写前/写后竞争、外部改动不被 rollback、部分成功重枚举；borrowed 永不删除；重复 add/remove 幂等；driver 无能力不重复 install；text suffix 与 JSON 解析；fake DPI 不支持不舍入；非目标输出快照不变；DD lease 在用时局部等待/回退 |
| P4 macOS adapter 与 Swift 编排 | `platform/macos/window_parking.mm/.hpp`、`window_main.mm`、新 portable parking planner/checks 与 C++ tests；`platform/macos-app/Sources/PairingController.swift`、`AppModel.swift`、`Processes.swift`、`DisplayTopology.swift`、必要 Configuration 字段和 Swift tests；`platform/display-topology/main.swift` | parking 对象控制接口、apply/recreate 判定、CG observer、Swift physical observer、每 serial 局部更新、selector 需求接口。调用 P1 `updateDisplay` JSON action；不改 Python helper/profiles | portable fake CG 与 Swift fake worker：容量内先 apply、超容量/对象消失只重建一 serial；callback 仅排队；重复通知不循环；release 不作用于外部 serial/Sidecar；重建更新 displayID、保持 connection/window identity；原点变化不重启 clipboard/HID/其他 serial；sleep 后重枚举；CG begin 阶段不读最终几何；apply/readback 失败保留 last snapshot |

### 6.1 并行与集成顺序

1. P1 先交付仅包含 schema、fake fixtures 与 adapter 接口的最小提交；P2–P4 可基于本文立即写 pure planner/fakes。
2. 各平台 native 实现只接受类型化 JSON desired，不接收任意命令；发布同一 shape 的 observed/result。
3. P1 最后接入各包模块和 bundle 清单，运行双端兼容、两连接失败隔离与连续几何变更场景。
4. native geometry 热更新暂缺时，验收局部组件替换；不得把这个实现状态写成无中断原位更新。

每包均须运行八类事件：本地 scale/resolution、hotplug、输出被移除、图形实例重启、
peer 不同屏重连、UI arrangement、sleep/resume、logout/new login。
参数化测试还必须覆盖乱序、重复、事件丢失、并发 desired、延迟完成、错误 inventory 不等于空列表。
这些测试验证规划、恢复与调用边界；不能代替显示驱动、GPU、WindowServer 或实际视觉验收。

### 6.2 实机人工验收门槛（未来，由用户操作）

| 平台 | 用户手动操作 | 读取与通过条件 |
|---|---|---|
| Windows | 改本地/peer 分辨率与 scale；拔插屏幕；禁用/恢复 VDD；睡眠唤醒、注销登录；同时保留另一连接 | 读回 DisplayConfig/实际 DPI、稳定身份与每 key revision；验证新模式、位置和输入映射；其他输出/连接持续。超出 mode list 时明确 unsupported；具备签名 driver backend 后再验证真实 monitor add/remove，不把 pool 分配当 hotplug |
| macOS | 改 peer 屏幕；改变显示缩放；Sidecar 连接/断开；睡眠唤醒与重新登录；同时运行两个 serial | 读回 CG mode points/pixels、origin、serial/displayID；确认原位 apply 支持范围与超容量局部重建；窗口恢复、SCK 持续和映射正确；另一 serial、clipboard/HID 不重启。私有 API 要记录 OS build |
| Linux | 用户会话真实 scale/分辨率/热插拔/重登；UI 改 arrangement | 读回 named output 与 special workspace、capture/input snapshot 一致、丢失后收敛、其他 route 保留。任何鼠标键盘交互和视觉结果由用户执行/判断 |

Linux 自动测试默认 fakes。只有独立 runtime dir、独立 Wayland socket、独立 compositor process、
清空继承的 host Hyprland/DBus 环境且不连接真实会话时，未来测试才可以启动 nested/headless Hyprland。
隔离证明缺失时仅运行 fakes。本次没有启动 nested compositor。

## 7. 本阶段验证与决策记录

- 已验证（源码检查）：搜索 `headless/IddCx/VDD/CGVirtualDisplay/Sidecar/display_arrangement`，
  覆盖平台代码、Rust 原语、Python/Swift 编排、生成配置与安装脚本；发现 §2 所列多所有者和格式差距。
- 已验证（无原生调用的既有测试）：`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -p 'test_display_topology.py'`，10 项通过；
  同命令改用 `test_windows_virtual_display_scale.py`，4 项通过。两者以 fake/mock 检查 planning/脚本生成，不调用系统显示设置。
- 已验证（本次临时 Python fixture）：mock `pairing_display.subprocess.run`，旧文本返回正确 bounds，
  添加工具当前输出的 `refresh_hz=60` 后返回 None；没有执行 display 程序，支持 §2.1 的格式结论。
- 已验证（既有 portable C++）：`virtual_display_transient_checks_test.cpp` 用
  `c++ -std=c++20 -Wall -Wextra -Werror` 编译并执行通过；临时产物在本 worktree 内创建并清理。
  覆盖身份替换、备份大小/溢出和 restore field mask，不调用 Windows API。
- 已验证（文档检查）：相对链接、代码块和必需主题检查通过；源码行号复核。
  提交前另执行 `git diff --cached --check`。
- 未验证：真实 Windows driver 的 monitor lifecycle/control ABI、macOS 运行期 `applySettings`、
  真实模式/输入/视觉效果。任务明确只读，不运行任何原生显示工具或现有 service。
- 决定：第一版用已有认证 pairing resume 传管理状态，保留约 3 秒传播周期；不引入未实现的推送保证。
- 决定：外部 Sidecar/物理屏默认只读；特例 selector 的原行为通过独立策略保留，避免通用管理器双写。
- 决定：模式不支持与 driver 控制缺失属于技术能力差距，不是额外安全限制；不据此关闭其他连接。
- 决定：本阶段仅提交本设计文档，不修改或部署实现；完整自动化必须在后续工作包与实机门槛通过后声明。
