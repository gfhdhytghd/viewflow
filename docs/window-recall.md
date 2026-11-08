# 收回本机浮动窗口

默认快捷键是 **Ctrl+Alt+Shift+H**。macOS 上 Alt 对应 Option。

它把本机应用位于 Viewflow 虚拟屏或全部物理屏范围之外的浮动窗口收回本机物理屏。窗口中心已经在任一物理屏上的窗口保持原位。其他系统传来的代理窗口不参与收回；最小化、全屏窗口不参与，Windows 最大化窗口也不参与。

Linux（Hyprland）只收回在其他系统中的窗口：位于 Viewflow 输出（非物理屏）上的窗口、位于 `viewflow-` 开头的 Viewflow 工作区（例如输出底层工作区）上的窗口，以及在当前可见工作区里被推出本屏范围的窗口。本机其他普通工作区和特殊工作区上的窗口不参与收回。

目标优先使用最近操作过的本机物理屏，无法确定时使用主物理屏（Hyprland 使用首个物理输出）。窗口按工作区排列并尽量保留原尺寸，超过工作区的窗口缩小到可见范围。原有层级与焦点保持；原生附属弹窗跟随父窗口。应用自身的尺寸约束可能限制缩放。

该操作只修改本机窗口位置，不需要远端在线。已连接时，源端现有窗口范围筛选负责移除远端代理。收回不关闭连接，也不销毁其他来源的窗口。

## 设置

Viewflow 设置提供快捷键输入框、应用按钮和“立即收回”按钮。支持 Ctrl、Alt、Shift、Super 加一个 A–Z 字母；Option、Cmd、Win 等别名也可使用。设置成功后持久保存。Windows/macOS 注册冲突会显示错误并尝试恢复原快捷键。

Linux 在 Viewflow Hyprland 插件加载后即可使用默认快捷键，且在物理键盘事件向远端转发之前识别。Windows/macOS 由 Viewflow 应用管理本地常驻 helper；停止远端连接不会停止快捷键，退出应用会停止 helper。macOS 移动其他应用窗口需要系统辅助功能权限。

## 构建与检查

独立 helper：`cmake -S platform/window-recall -B build/window-recall`，随后构建并运行 CTest。Windows/macOS 产物为 `viewflow-window-recall`（Windows 带 `.exe`）。统一安装包构建已包含 helper。

- `--check`：只列出统计，不移动窗口。
- `--validate-shortcut --shortcut Ctrl+Alt+Shift+H`：检查快捷键格式。
- `--watch`：注册并等待用户按键。
- `--once`：执行收回；已有 watcher 时交给它处理以保留物理屏选择记录。

Linux 对应 Lua API 为 `viewflow.recall_windows(true)`（只读检查）、`viewflow.recall_windows(false)`（执行）及 `viewflow.set_recall_shortcut("Ctrl+Alt+Shift+H")`。

自动化测试覆盖按键锁存、释放顺序、左右修饰键、屏幕筛选、越界和超大窗口位置计算。真实快捷键、应用尺寸约束和远端代理退场由用户操作验收。更新 Linux 插件后需要用户重新加载；构建通过不表示当前会话已加载新功能。

## 强制脱离远端输入

固定快捷键 **Ctrl+Alt+Shift+D** 在 Linux 物理键盘事件进入远端转发之前识别。按下后释放所有 Viewflow 输入路由的远端按键/按钮占用，取消等待中的捕获和拖动返回，把鼠标放回最近使用的 Linux 物理屏内部。远端离线或迟到的捕获确认不会阻止本地退出；各显示、窗口与网络连接继续保留，之后仍可正常从边缘进入远端。

快捷键的 D 按下、重复和释放事件均被消费，左右 Ctrl/Alt/Shift 都支持。D 组合保留给强制脱离，不能配置为 Linux 窗口收回键。
