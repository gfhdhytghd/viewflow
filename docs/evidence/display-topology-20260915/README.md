# HDMI / Sidecar 自动拓扑部署记录

2026-09-15 已部署 Linux 监督服务、Mac 显示器 helper、Mac 主应用的动态窗口路由支持，以及支持原生坐标偏移的 Linux cursor peer。

实际观测：右侧选择 macOS，Sidecar 未连接。Windows desktop/input 服务均 inactive；Mac 主输入、单 HID 转发、双向窗口服务运行。QUIC 配置 endpoint 为 Mac，ready 文件与 cursor peer PID 一致，插件 remote 为 `[1,3072,390,1920,1200]`。`HEADLESS-2` 在 monitors-all 中保留但 disabled。Mac 主屏是 HDMI（ID 2），Linux 停放屏为 `(-3072,-390,3072,1728)`，接收窗口原点 `(-3072,-390)` 与 Linux 反向接收偏移 `(3072,390)` 一致。

Mac 部署基于当前应用对应的独立源快照，仅增加 DisplayTopology/AppModel 路由逻辑；没有部署工作树中的 activity 或 recall 改动。既有捕获/呈现 helper SHA-256 保持 `ff2af363de29c8549e654700c2630262f714cc129b861daad01bfc1ff04e6406`。应用 codesign 深度严格校验通过。

验证：6 项拓扑规划测试、3 项 HDMI 按钮编排测试、12 项 HID 测试、窗口区域筛选测试（含 HDMI/Sidecar 跨区）、既有启动配置和源窗口测试通过。Rust 原生坐标参数测试与 cursor peer 构建通过；Mac helper、隔离应用构建和拓扑 profile 测试通过。Swift 构建仅有既有 Permissions 的 Swift 6 actor-conformance 警告。未注入鼠标/键盘，没有自动切换 HDMI、连接或断开 Sidecar。

含 Sidecar 的真实切换、鼠标、手势和窗口拖动仍需用户验收；离线四态测试与单态运行证据不代表所有硬件状态已经验收。

Linux 回退目录：`/home/wilf/.local/state/viewflow/topology-backup-20260915-222050`。
Mac 原应用：`/Users/linhaikuo/viewflow-display-topology-20260915/Viewflow-before-topology.app`，同目录保留 `preferences-before.plist`。
