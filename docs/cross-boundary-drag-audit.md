# 跨设备窗口拖动审计（2026-10-30）

本记录补充 [桌面拖动契约](desktop-drag-contract.md)，遵循
[安全与可用性原则](security-and-availability-policy.md)。

已完成：源码审计、下列修复、离线测试与 Mac 隔离编译。
未验证：真实鼠标连续交接、系统菜单栏/窗口吸附行为与 Windows 原生构建。
矩阵表示代码职责，不表示 24 种现场交互都通过。

## 坐标与当前拓扑

坐标统一按左上角原点、向右/向下增加描述。矩形采用半开区间。
设备的显示器原点与窗口的停车位置不是同一个坐标系。

2026-10-30 只读检查：

| 对象 | 原生像素 | 逻辑矩形 `(x,y,w,h)` | 来源 |
| --- | --- | --- | --- |
| Linux `DP-4` | 6144×3456，scale 2 | `(0,0,3072,1728)` | 当前 Hyprland `monitors all` |
| Linux `HEADLESS-3`，代表 Mac | 3840×2400，scale 2 | `(3072,299,1920,1200)` | 同上；当前生成组配置 |
| Mac HDMI，display 2 | 3840×2400 | Mac 坐标 `(0,0,1920,1200)` | `viewflow-display-topology --probe` |
| Mac 停车显示器，display 17，serial 1 | 6144×3456 | Mac 坐标 `(-3072,-299,3072,1728)` | 同上；`window-parking.log` |
| Sidecar | 未确认 | 当前枚举没有 Sidecar | 同上；不推断历史连接状态 |
| Windows | 未确认 | 旧模板指定 Linux 坐标 `(3072,390,1920,1200)` | `desktop-source.json`；不是当前显示器读数 |

当前公共边是 Linux 右边/Mac 左边，公共纵向区间为 `[299,1499)`。
Mac 原生点到 Linux 全局逻辑点的变换是 `(x+3072,y+299)`。
反向变换是 `(x-3072,y-299)`。源端的 scale 2 仅乘窗口数据的传输坐标。
Linux 接收器的参数 `3072 299 2` 是反向呈现偏移与传输缩放。

Linux 当前实例为
`e5a03b6a5ce64ec4c85954649bad4df083627574_1792607222_1754160417`。
终端环境中的旧实例连接失败；使用当前实例只读查询成功。
本次没有改实例环境、显示器、运行配置或服务。

配置位置与漂移：

- `~/.config/viewflow/app/groups/5f36b8d50fbe23b994a88e1f7984b50e/`
  的生成配置使用 y=299。Mac 当前 `connection.json` 使用对应的 -299。
- `~/.config/viewflow/topology/right-macos.json` 与旧源端模板仍使用 y=390。
  不得把旧模板当作当前拓扑；本次保留这些非运行任务所属的配置。
- `macos-multiscreen-source.json` 保存 `(3072,1590)`、3078×2310、scale 2
  的旧多屏矩形。当前枚举不支持将其当作在线 Sidecar。
- 当前组成员只有 Linux 和 Mac。Windows 旧发现配置指定
  `WindowsVM`/`WindowsVM.local`/`WindowsVM.lan`；本次没有连接 Windows。
  `tools/windows_session_route.py:7` 只选择已有输入/媒体端点，不负责窗口边界。
- `platform/desktop-app/display_arrangement.py:9` 检查水平与垂直公共边。
  `:16`、`:39` 保持显示器相接且不重叠；角点不是公共边。
  布局整理采用至少 64 逻辑点的接边长度，不是输入授权规则。
  底层几何仍按实际公共区间检查，不用整个桌面的外接矩形填补空隙。

## 所有者与状态机

“窗口源端 → 窗口呈现端”与“光标当前控制权”分别记录。
窗口保留原应用、PID 和原生身份；跨边不是迁移应用进程。

| 路径 | 窗口边界与几何所有者（file:line） | 状态与变换 | 夹边来源及失败方式 |
| --- | --- | --- | --- |
| A：Linux→Mac | `tools/macos-window-share-linux.py:12` 按视口交集选源；`platform/macos/window_presenter.mm:284` 回传几何，`:770` 决定原生约束；Linux `platform/linux-window-input/main.cpp:229` 执行窗口几何 | 源端窗口→视频代理→本地移动→顺序几何回传→捕获确认。Mac `x=origin_x+wire_x/scale`；`AppKit_y=main_height-origin_y-(wire_y+height)/scale` | Hyprland 原生移动/工作区、AppKit 菜单栏与可见屏幕约束、旧捕获几何回写。本次放开代理本地移动的 AppKit 约束并补原生标题栏的几何所有权 |
| B：Mac→Linux | `platform/macos-app/Sources/Configuration.swift:266` 选择越界窗口，`:109` 选择目的地；`platform/macos-app/Sources/AppModel.swift:321` 启动源；`platform/reverse-common/window_scope.hpp:43` 决定捕获；`platform/linux-reverse/main.cpp:387` 接管原生标题栏 | 原生移动观测→一次性拖动种子→带锚点的帧→Linux 代理→几何回传→AX/捕获确认。Linux `host=origin+wire/scale` | 旧中心门槛、原生 macOS 窗口约束、停车夹取、锚点单位错误。停车由 `platform/macos/window_parking.mm:59` 保留逻辑/原生位置差，不把实际停车位置回写成远端拖动位置 |
| C：Linux→Windows | `crates/viewflowd/src/desktop_source.rs:1381` 视口交集；`platform/windows-composition-preview/desktop_move_gesture.h:122` 抓取偏移；`crates/viewflowd/src/atlas_source_input.rs:1386` 接受请求矩形；`platform/hyprland-plugin/src/desktop_window_controller.cpp:223` 执行移动 | Enroll→Begin→Update→End/Cancel→捕获确认；逻辑毫点与 Windows 原生视口相互变换。接收状态机为 `crates/viewflowd/src/desktop_receiver_state.rs:262` | Windows Snap、Hyprland 工作区归属、等待旧几何确认。源端保留部分越界矩形；旧文档“释放后夹回本地视口”不是当前 `desktop_return_bounds` 的行为 |
| D：Windows→Linux | `platform/windows-reverse/main.cpp:1049` 观测原生移动与锚点；`platform/linux-reverse/main.cpp:387` 确认应用移动后接管；`:1323` 发布本地代理锚点 | Windows 原生移动→帧提示→代理身份绑定→Linux 原生移动→有序几何更新。Windows 坐标为源端物理像素，除接收 scale 后加原点 | Windows 原生移动循环/屏幕夹取、错误的按下锚点、Linux 浮动/平铺几何所有权。本次修复非 Mac 按下锚点；平铺仍由本地布局拥有几何 |
| E：Mac→Windows | Mac 与 B 共用选源/目的地/捕获；`platform/windows-window-presenter/main.cpp:288` 接管源端拖动，`:304` 保留跨网络到达的释放位置 | 原生移动提示→pending takeover→Windows move→geometry→源端确认。原生帧锚点乘 `pixel_scale/receiver_scale`，旧帧锚点除 `receiver_scale` | 旧中心门槛、Snap、未收到 held-left 或源端几何。Windows 呈现端现有单位变换正确；本次保持该协议兼容 |
| F：Windows→Mac | Windows 与 D 共用选源；`platform/macos/window_presenter.mm:472` 接管带锚点的源端移动，`:675` 确认点击引起的源端移动，`:770`/`:994` 持有本地几何 | 源端移动提示/应用输入→确认原生移动→Mac 本地跟随→几何回传→源端确认；坐标同 A | AppKit 菜单栏/可见屏幕约束、原生 Windows 移动循环。本次补齐无需代理先收到 mouseDown 的源端提示接管；真实系统移动循环与按住按钮的交接仍未验证 |

独立窗口媒体支持 A/B/D/E/F；Linux→Windows 默认还存在 C 的桌面 atlas 路径。
当前配对组是主机星形拓扑。没有当前 Mac↔Windows 直连光标配置。
E/F 的独立媒体路径存在，但自动光标交接依赖另外的匹配输入连接。
本次没有增加一条未经配置的设备间路由，也没有伪造缺失的 held-button。
F 的源端提示接管包含本次修复；没有当前 Windows 实机证据，不能报告为四边交接通过。

Linux 控制的光标交接由以下代码共用：

- `platform/hyprland-plugin/src/input_capture_core.cpp:88`、`:217`：
  `LOCAL→EDGE_ARMED→CAPTURE_PENDING→REMOTE_CAPTURED`。
  `platform/hyprland-plugin/src/input_capture.cpp:382` 激活控制权。
- `crates/viewflowd/src/atlas_cursor_handoff.rs:1348` 用运动线段检查四条接缝。
  `:432` 检查 Mac 原生光标反馈，`:350` 为返回拖动预留 8 个远端物理像素。
  这些是交互几何，不是安全期限。
- `crates/viewflowd/src/atlas_cursor_handoff.rs:1042` 先退役远端几何所有权，
  再按序撤销远端输入；`platform/hyprland-plugin/src/input_capture.cpp:434`
  释放光标控制权，`:510` 用原抓取偏移继续 Hyprland 拖动。
- `crates/viewflowd/src/cursor_native_drag.rs:12`、`:129` 从按下后真实移动绑定
  Mac 代理。`crates/viewflowd/src/reverse_bridge.rs:430` 另外接收代理拖动锚点。
  普通内容点击与改变尺寸不会因此变成窗口移动。
- 初始 Linux 本地按住左键的拖动仍由本地合成器拥有；
  `InputCaptureCore::continuingHeldLeft()` 只承接已有返回拖动。
  原生标题栏/Super 移动跨虚拟输出与控制权交接不能当作同一个状态。
  源端仍可以拥有原生拖动并持续更新代理；是否全程跟随必须由真实交互验收。

## 方向 × 四边矩阵

边名以出发屏幕为准。A～F 的完整文件、状态机、变换与夹边原因见上表。
G 表示上述 Linux 光标状态机；N 表示另配输入路由，当前组没有这条直连。
每格都只在对应公共区间内成立；本次没有移动在线拓扑来逐格测试。

| 窗口方向 | 左边 | 右边 | 上边 | 下边 |
| --- | --- | --- | --- | --- |
| Linux→Mac | A+G，左交集/左候选 | A+G，右交集/右候选；当前接边 | A+G，上交集/上候选 | A+G，下交集/下候选 |
| Mac→Linux | B+G，左交集/返回；当前接边 | B+G，右交集/返回 | B+G，上交集/返回 | B+G，下交集/返回 |
| Linux→Windows | C+G，左交集/左候选 | C+G，右交集/右候选 | C+G，上交集/上候选 | C+G，下交集/下候选 |
| Windows→Linux | D+G，左交集/返回 | D+G，右交集/返回 | D+G，上交集/返回 | D+G，下交集/返回 |
| Mac→Windows | E+N，左交集 | E+N，右交集 | E+N，上交集 | E+N，下交集 |
| Windows→Mac | F+N，左交集/提示接管 | F+N，右交集/提示接管 | F+N，上交集/提示接管 | F+N，下交集/提示接管 |

所有 G 格子的边界条件均为：

| 出发边 | 邻接条件 | 平行坐标条件 |
| --- | --- | --- |
| 左 | `source.left == target.right` | `y ∈ [max(top),min(bottom))` |
| 右 | `source.right == target.left` | 同上 |
| 上 | `source.top == target.bottom` | `x ∈ [max(left),min(right))` |
| 下 | `source.bottom == target.top` | 同上 |

窗口选源用正面积交集；光标跨越用真实相接的边。
隔着空隙的窗口可以与远端矩形相交，但光标不能因此穿过不存在的公共边。

## 修复与决定

1. Mac 的 Swift 选源、Swift 目的地筛选和 C++ 捕获启停原来要求窗口中心越界。
   Python 监督器原来按部分越界选源。现在全部按远端正面积交集选源，
   并从该交集中扣除真实物理显示器的并集。只触边不启动。
   窗口另一处的空隙不再误触发已由物理屏幕覆盖的远端区域。
2. Hyprland 原来逐事件要求至少 1 DIP 向外运动。
   光标夹在接缝且每次只移动 0.25 DIP 时，持续移动也不会交接。
   现在按同一屏幕/同一边累计净向外位移。向内运动抵消累计值。
   离开接边或更换边后重置。没有新增期限。
3. Linux 原来把全部拖动锚点除以接收 scale。
   Mac 原生帧的锚点却是逻辑点，必须先乘帧 `pixel_scale`。
   `platform/reverse-common/window_surface.hpp:62` 现在统一换算。
   Mac 无原生帧元数据的旧路径在源端乘传输 scale。
   保留原生帧的旧协议；Windows 呈现端已有的正确换算不变。
   Retina 场景必须使用包含本修复的 Linux 接收器。
4. Mac 代理类有两种拼写：
   `ViewflowReverse-Mac-PID-ID`、`ViewflowReverse-MacNative-PID-ID`。
   旧观察器把 `PID-ID` 整段解析为整数，并漏掉 Native 类。
   现在分别读取 PID 与 ID，并核对窗口所有者 PID。
5. 采用任务附带 `stray-begin-drag.patch` 的修复。
   `platform/linux-reverse/main.cpp:324` 在非 Mac 按下时记录实际桌面光标。
   原来 Windows 标题栏接管使用默认/上次按下锚点，会按错误偏移放置窗口。
   记录不改变按住期间的 Windows 绝对桌面输入路径。
6. Mac 反馈的第一条样本也与激活位置比较。
   原来跳过首条样本；快速返回后若光标一直夹在边上，后续样本没有向外差值。
   现在四边都保留这次返回机会；静止与向内运动仍不会触发返回。
7. Mac 代理本地移动原来仍调用 AppKit `constrainFrameRect:toScreen:`。
   现在本地移动与应用远端几何都保留请求矩形。
   `windowWillMove:` 为原生标题栏声明本地几何所有权，防止旧帧回写。
   调整尺寸与全屏继续使用各自的原生路径。
8. Mac 原来只从代理自己的按下事件确认源端移动。
   新增 `platform/reverse-common/source_drag.hpp` 状态机与 Mac 定时跟随路径。
   带锚点的源端移动在物理左键仍按住时接管；没有伪造新的按下。
   源端有序释放清除提示后，本地仍跟随到物理释放并发送最终几何。
   源端提示尚未消失时，取消或释放不会重复接管同一提示。
   输出队列繁忙时保留本地重试；静止跟随不重复发送几何。

没有引入 33 ms 退出条件。已有断线释放与顺序按钮协议保持原职责。
本次没有修改 Windows 原生代码，也没有把暂时的几何失败升级为会话销毁。

## 被动日志证据及边界

- Linux 组 `logs/ddc2fb324f0f0a8fe241c3f82acefaa3-windows-receive.log:12530`
  记录 `Remote titlebar local requested id=1`；`:12537` 记录
  `Remote titlebar local active id=1`。说明接管路径确实运行过，不能证明四边都成功。
- 同一文件 `:4227` 记录 `reverse geometry inventory retry` 与空 JSON。
  这是几何枚举失败的证据，不是窗口已到达目标屏幕的证据。
- Linux `ddc2fb324f0f0a8fe241c3f82acefaa3-desktop-share.log:3745`
  记录 `Fatal Python error: libshiboken/signature: could not initialize part 2`。
  这是服务历史失败；没有逐手势关联，不能把它定为本次卡边原因。
- Mac `windows-receive-a4834581f2f870e013ee2802762a5160.log:3524`
  记录 `macos-local-native-drag fallback=posted-events window=1`。
  `:2327` 的按下记录还包含 pointer/body/pending/ack。
  这些记录支持检查 AppKit 与 posted-events 分支；没有完整卡边轨迹。
- Mac `window-parking.log` 最后一条是 display 17、origin `-3072,-299`。
  只读 probe 与该记录一致。没有截图或真实交互证据。

上列源码缺陷可重现于离线测试。它们与用户现场每次卡边的对应关系未确认。
缺少逐手势坐标、按钮及控制权轨迹时，不把编译成功写成现场修复通过。

## 验证

- 已验证：`cargo test --workspace`，1024 项通过，6 项按现有标记忽略。
  包含四边首样本返回、代理类/PID 解析、原有几何所有权与顺序输入测试。
- 已验证：`cargo clippy --workspace --all-targets -- -D clippy::unwrap_used`。
  该 lint 没有错误；其他已有 lint 警告保留。
- 已验证：`cd platform/desktop-app && QT_QPA_PLATFORM=offscreen /tmp/viewflow-hid-ui-venv/bin/python -m unittest discover -p "test_*.py"`，76 项，跳过 2 项。
- 已验证：逐个执行 `tools/tests/*.py` 的 13 个 Python 脚本；
  `bash tools/tests/desktop-drag-launchers-test.sh` 通过。
  修改 Swift 后另跑 `python tools/tests/macos-distribution-test.py` 通过。
- 已验证：`cmake -S platform/linux-reverse -B /tmp/viewflow-edgedrag-build -DCMAKE_BUILD_TYPE=Release`、
  `cmake --build /tmp/viewflow-edgedrag-build -j 8`、
  `ctest --test-dir /tmp/viewflow-edgedrag-build --output-on-failure`，17 项通过。
- 已验证：`cmake -S platform/hyprland-plugin -B /tmp/viewflow-edgedrag-plugin -DCMAKE_BUILD_TYPE=Release`、
  `cmake --build /tmp/viewflow-edgedrag-plugin --target viewflow-hyprland-input-core-test -j 4`、
  `ctest --test-dir /tmp/viewflow-edgedrag-plugin -R '^viewflow-hyprland-input-core-test$' --output-on-failure`。
  四边慢速、反向抵消、静止、原有输入生命周期测试通过。
- 已验证：Mac 隔离目录 `/Volumes/MoveDATA/viewflow-wifi-test/codex-edgedrag`。
  Mac 没有 CMake，改用 `xcrun clang++ -std=c++20 -mmacosx-version-min=13.0 -fobjc-arc -Wall -Wextra -Werror`
  编译并链接 CMake 原生窗口目标的全部 9 个 `.mm`，框架列表同 `platform/macos/CMakeLists.txt`。
  `compile.log` 保存编译输出；没有运行生成的窗口程序。
- 已验证：Mac 用 `xcrun swiftc -parse-as-library` 编译并运行
  `Configuration.swift` 与 `ConfigurationTests.swift`；`swift.log` 记录通过。
  另外用 `xcrun clang++ -std=c++20 -Wall -Wextra -Werror -UNDEBUG` 编译并运行
  `window_frame_geometry`、`window_gesture`、`window_placement`、`window_parking`
  四个测试和共享 `window_mapping_test.cpp`。这些都是纯几何/状态测试。
- 未验证：Windows 原生编译、Windows 输入与 Snap；没有 Windows 实机访问。
- 未验证：真实 AppKit 菜单栏、Hyprland 抓取交接、源端原生窗口夹边和全程按钮状态。
  本次没有输入注入、焦点切换、屏幕捕获、服务停止/重启、部署或推送。

## 用户手工验收清单

每个矩阵格独立记录结果，不因一条右边路径通过就勾选四边。
只有配置实际公共边时才执行；测试布局由用户调整。

| 出发→目标 | 左 | 右 | 上 | 下 |
| --- | --- | --- | --- | --- |
| Linux→Mac | □ | □ | □ | □ |
| Mac→Linux | □ | □ | □ | □ |
| Linux→Windows | □ | □ | □ | □ |
| Windows→Linux | □ | □ | □ | □ |
| Mac→Windows（独立媒体与匹配输入路由） | □ | □ | □ | □ |
| Windows→Mac（含源端提示接管） | □ | □ | □ | □ |

每格执行以下检查：

1. 选普通可移动窗口，记录源/目标逻辑矩形、原点与 scale。
2. 用原生标题栏慢速拖到公共边；保持左键，连续跨越并继续移动。
   检查窗口与光标保留原抓取偏移。记录卡边、回跳或停住的准确位置。
3. 在目标屏幕释放。检查窗口留在释放位置。点击窗口验证左键没有滞留。
4. 用相同按住手势拖回。检查源端与代理没有同时争夺几何。
5. 重复快速越界、只露出一条窄边、边界处立即释放和原地反向拖动。
6. 分别覆盖公共区间中间、两端附近和区间外。
   区间外检查原生边界行为，不要求穿越没有邻屏的空隙。
7. 覆盖负原点、scale 1/2、不同高度、上下布局与大于视口的窗口。
   在 Mac 上另外检查菜单栏附近与原生标题栏、Command 移动。
   在 Linux 上另外检查浮动、Super 移动与平铺后再浮动。
   在 Windows 上另外检查原生标题栏、已有快捷手势与 Snap。
8. 由用户中断一次连接后重新连接。检查按键/按钮释放，其他窗口继续运行。
   记录该窗口的重连结果。不得用强制退出全会话代替局部恢复。

初始 Linux 原生按住拖动与返回拖动分别记录。F 路径同时检查源端提示接管。
若任何一项不能保持同一次按住手势，整体连续交接验收仍是未完成。

## Super/Command drag（2026-11-01）

已完成：双向代理优先移动、几何合并、旧回执保护与隔离构建。
未验证：真实鼠标拖动的流畅度、源端应用的 AX 行为与现场网络时延。
没有运行输入注入、窗口移动、焦点切换、在线 Hyprland 查询、插件加载、
服务重启或部署。Mac 的编译和离线测试只使用新建的
`/Volumes/MoveDATA/viewflow-wifi-test/codex-superdrag-20261101-01/`。

### 源码追踪与原因

任务描述中的“每次先移动源端再回传代理”不适用于全部现有路径。
`374df8de` 后的 Command 手势已有本地移动和拖动期间的回写保护。
本次沿实际调用链修复剩余的竞争与等待。

| 方向 | 修饰键与移动所有者 | 请求、执行和回显 | 原有抖动或延迟来源 |
| --- | --- | --- | --- |
| Linux 窗口 → Mac 代理 | Linux Super 经 `atlas_cursor_handoff.rs` 转为 HID GUI usage `0xe3/0xe7`；`crates/viewflow-platform/src/macos_input.rs` 映射为 Mac keycode `55/54`，并给鼠标事件附加 Command flags。Mac 本机 Command 走相同的 AppKit 手势选择。`window_presenter.mm::mouseDown` 选 Command 移动，Command+Shift 选调整尺寸 | 代理 `geometry()` → `flush_geometry()` → kind 6、单调 sequence → `vf-hyprland-windows.rs::translate` → `InputHelper` → `linux-window-input/main.cpp` 按稳定窗口身份执行 Lua resize/move → HCGF 捕获几何 → `Tile.geometry_ack` → Mac `update` | Command 原来调用 `performWindowDragWithEvent`，同时保留 posted-event fallback；两个本地写入路径使所有权依赖原生拖动是否消费事件。几何每个事件循环都能入队。Linux 在编码结束时读取最新 ACK，能把新回执附到移动之前捕获的旧几何上 |
| Mac 窗口 → Linux 代理 | Hyprland 原生 Super+左键移动 Linux 代理。`linux-reverse/main.cpp` 暂存 Super，确认本地几何变化后释放源端输入，避免 Mac 同时解释这次拖动。`capture_status().native_drag_window` 标明原生拖动的窗口 | compositor inventory → `GeometrySync::observe` → kind 6 → Mac `window_source.mm::geometry_request` 最新请求 → `apply_geometry` 每至多 1/60 秒尝试 AX position/size → placement 与几何回执随视频返回 → Linux `GeometrySync` | Mac 代理的全部几何变化都进入 `WindowResize` 的 100 ms 稳定防抖；连续移动不断重置计时。普通 Super 移动原来按 33 ms 轮询。即使源端已有最新回执，活动原生拖动仍必须保留本地所有权 |

量化不是本次新增的控制机制。Mac 代理的屏幕点按 `options.scale`
转换为 wire 整数。Linux 源端再按 HCGF 的逻辑宽高与 crop 比例映射，
保留捕获边框和 content 的差值，最终转为毫 DIP。
反向路径按接收原点与 scale 映射，Mac native tile 的逻辑尺寸不再次除以 scale。
这些既有单位保持不变。整数舍入和源端原生约束仍能使最终矩形与请求不同；
拖动期间不得把这种差值反复应用到代理。
AX 调用、Hyprland IPC、捕获和网络耗时没有现场测量。
源码证据不能证明它们各自占现场延迟的比例。

### 改动与决定

1. Command 移动由 AppKit 的 `mouseDragged` 单独写代理位置。
   每次事件按当前指针和按下时的抓取偏移设置本地位置。
   此步骤没有网络等待，也不启动 WindowServer 的第二个拖动循环。
   普通原生标题栏继续使用既有 WindowServer 路径。
   Command+Shift 继续使用既有按下矩形调整尺寸路径。
   手势同时读取事件 flags 和当前 AppKit modifier flags，覆盖两种键盘来源。
2. 双向几何采用一个未确认请求，加一个可替换的最新本地目标。
   Mac 的 `geometry_queued` 保留最新原生 frame；Linux 的
   `GeometrySync.queued` 保留最新 observed 矩形。
   未确认请求期间，后续指针事件只覆盖最新目标，不继续增加几何队列。
   每个源端回执开放一次发送机会，因此发送速率跟随源端捕获和处理能力。
   长 RTT 下源端更新率会下降；代理本地移动不等待这个速率。
   这是本次明确采用的有界流量决定，不增加延迟退出条件。
3. 复用既有单调 input sequence 作为每次几何编辑的代次标记。
   没有扩展 wire 协议，也没有要求同时升级额外的 drag-ID 字段。
   活动本地拖动忽略所有源端位置回写。
   释放后继续保护最新待发目标和最后一个未确认请求。
   最后回执到达后，按源端返回矩形核对一次。
   下一次拖动可以在旧回执尚未到达时开始；旧回执只开放最新目标的发送，
   不取得新拖动的位置所有权。之后独立发生的源端原生移动仍正常传播。
4. Linux 源端把 helper 完成时刻与 sequence 存成同一份回执。
   `window_renderer.cpp` 与 Rust `now()` 都使用 `CLOCK_MONOTONIC`。
   只有捕获时间不早于完成时刻的帧才携带新回执。
   编码较慢的旧帧继续携带上一份已发布回执。
   这个规则表示因果顺序，不是帧新鲜度门槛，也不丢弃或中断视频。
5. Linux 接收器只给尺寸变化保留 100 ms AX 防抖。
   只有位置变化时，最新目标立即取得发送资格。
   Super 移动采用与标题栏相同的 16 ms 几何采样间隔；
   回执仍限制实际发送速率，迟到采样不会累积补发。
6. 保留局部恢复。Mac 输出繁忙时保留最新几何；
   Linux helper 不可用时继续媒体并回传处理后的观测几何；
   Mac AX 暂时失败时保留请求供重试。没有新增全会话关闭条件。
   没有修改 Hyprland 插件、本机 Linux 窗口手势、卸载或兼容构建代码。

既有八项跨边修复的代码保持原路径：正面积选源、四边累计位移、
锚点单位换算、两种 Mac 代理身份、非 Mac 按下锚点、首样本返回、
AppKit 跨边约束与源端拖动提示接管。
`source_drag.hpp` 和 `window_mapping_test.cpp` 的离线检查仍覆盖提示接管与单位映射。
这不代替四边连续按住拖动的现场验收。

### 验证

- 已验证：`cmake -S platform/linux-reverse -B /tmp/viewflow-superdrag-build -DCMAKE_BUILD_TYPE=Release`、
  `cmake --build /tmp/viewflow-superdrag-build -j 6`、
  `ctest --test-dir /tmp/viewflow-superdrag-build --output-on-failure`：17 项通过。
  `reverse_geometry` 增加 10000 次突发变化、旧回执、释放后的最终目标、
  本地发送失败重试与最终矩形核对检查。
  `window_mapping` 增加 1000 次连续位置更新不重启尺寸防抖的检查。
- 已验证：Mac 在上述隔离目录运行
  `cmake -S platform/macos -B build -DCMAKE_BUILD_TYPE=Release`、
  `cmake --build build -j 6`、
  `ctest --test-dir build --output-on-failure -LE hardware-codec`。
  原生窗口目标编译并链接成功。29 项离线测试通过。
  新增 `windows-geometry-sync`，在 Apple 编译器下检查同一份回执状态机。
  排除的 `windows-codec` 不属于本次几何验证。
- 已验证：`cargo test -p viewflowd --bin vf-hyprland-windows`：
  旧捕获帧不得携带新几何回执的 Rust 测试通过。
- 已验证：`cargo test -p viewflowd --bin vf-hyprland-windows --features native-gpu-nvenc`：
  2 项通过，包括 scale、负原点、边框映射与旧帧回执。
- 已验证：`cargo check -p viewflowd --bin vf-hyprland-windows --features native-gpu-nvenc`：
  原生 GPU 功能代码编译检查通过。库输出 18 条 warning；没有编译错误。
- 未验证：真实 AppKit/Hyprland 交互、实际网络下的帧率与抖动幅度。
  所有现场鼠标和键盘验收由用户执行。

### 用户手工验收清单

1. 在 Mac 上按本机 Command 拖动 Linux 代理的内容区域。
   检查代理立即跟随指针，源端异步跟随。
2. 用 Linux 键盘把 Super 路由到 Mac，再重复相同拖动。
   分别检查左右 Super/Command。检查抓取偏移与本机键盘一致。
3. 在 Linux 上用 Super 拖动 Mac 代理。
   检查代理保持 Hyprland 原生移动，Mac 源端在连续移动期间跟随。
   不得只在静止满 100 ms 后移动。
4. 每个方向覆盖慢速、快速、停顿、反向、释放后立即再拖动。
   检查拖动期间无旧位置回跳，释放后源端和代理停止争夺位置。
5. 在既有负原点、scale 2 拓扑上跨接缝往返。
   检查按下锚点、按钮释放与原有连续交接。
   其他边和 scale 1 仅在用户实际配置对应拓扑后检查。
6. 覆盖原生标题栏、Command+Shift 调整尺寸、平铺后再浮动。
   检查这三条既有路径没有退化。
7. 用一个普通 Linux 原生窗口执行 Super 拖动。
   检查 Hyprland 原生行为不变。
8. 用户自行制造短暂网络拥塞或源端不可移动的条件。
   检查代理本地拖动继续，旧几何不排队回放，媒体和其他代理继续运行。
   恢复后检查最后目标与源端原生约束下的最终矩形。
