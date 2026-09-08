# Windows 锁屏输入与 Linux 登录自启动

Windows 锁屏输入由 `ViewflowInput` 系统服务提供。服务以 LocalSystem 身份运行，
在当前控制台会话中启动一个只负责输入的 `vf-input-service.exe worker`。
普通 `vf-media-peer` 接收端继续负责原有网络认证、控制权和事件顺序；
画面和代理窗口进程不提升为 SYSTEM。

辅助进程通过同一 Windows 会话的本地命名管道接受输入。管道只允许配置的
接收端账户和 SYSTEM 访问，拒绝网络管道连接；接收端确认服务端的 SYSTEM
身份和会话，辅助进程确认客户端会话。锁屏和解锁时，输入线程重新绑定当前
输入桌面，释放跨桌面遗留的按键状态，保持网络连接。

桌面接收任务仍用于已登录会话。登录前键鼠可使用独立的 `viewflowd serve
--input-backend native` 接收端，无需启动视频或代理窗口。2026-09-08 本机部署了
`ViewflowInput-Prelogin` 用户 S4U 任务，开机在 session 0 启动，使用原配对证书。
设置 `VIEWFLOW_WINDOWS_INPUT_SERVICE=1` 和 `VIEWFLOW_WINDOWS_CONSOLE_INPUT=1`，
使 session 0 客户端连接当前控制台的输入工作进程。客户端仍验证服务端 SYSTEM
身份和目标控制台会话；管道仍只接受配置的接收账户或 SYSTEM，拒绝网络客户端。
工作进程接受同会话或 session 0 的这些已授权本地客户端。控制台改变时由现有
服务生命周期关闭旧工作进程，客户端随后重连当前控制台。

当前 Linux `viewflow-windows-input.service` 使用 `vf-cursor-peer` 连接 Windows
44149 端口；Windows 防火墙该规则仅接受已配对 Linux 地址。Quickshell 的 Windows
目标现在使用这条独立键鼠通道，HDMI 独立切换。桌面视频服务仍保留，但不随这个
键鼠按钮启动。没有修改 Linux 锁屏行为。

验证：Windows 原生构建通过，Windows 输入相关 26 项测试通过；session 0 的
`probe` 返回 `secure-desktop-access=ok input-injected=false`；Linux 和 Windows
双向 mTLS 连接及周期时钟探测通过。鼠标移动、密码输入和登录仍由用户操作验收。

## 安装与启动

构建：

```powershell
cargo build --release --locked -p viewflowd --bin vf-media-peer --bin vf-input-service
```

在管理员 PowerShell 中安装；`ReceiverAccount` 是运行接收端的账户：

```powershell
.\tools\install-windows-input-service.ps1 -Binary .\target\release\vf-input-service.exe -ReceiverAccount 'WINDOWSVM\wilf'
```

安装目录默认 `C:\Program Files\ViewflowInput`，系统和管理员可以写入，普通
账户只有读取执行权限。服务设为自动启动，并在服务进程意外退出后重启。
服务停止或控制台会话改变时，先通知输入进程释放状态并退出；服务意外退出
也由输入进程监测。5 秒是本地无响应操作的恢复看门狗，不是帧期限或会话期限。
失败的键鼠操作不会被自动重放。

在接收端启动环境设置 `VIEWFLOW_WINDOWS_INPUT_SERVICE=1`，或使用：

```powershell
.\tools\desktop-drag-windows.ps1 -Config C:\Users\wilf\Viewflow\desktop-test\receive.json -LockScreenInput
```

不设置此环境变量时保留原来的进程内输入模式。本地消息格式变化时须同时更新输入服务和接收端。仅调整辅助进程内部的输入
实现且消息格式不变时，可以单独更新输入服务。

## 不发送输入的诊断

在与接收端相同的交互会话中运行：

```powershell
& 'C:\Program Files\ViewflowInput\vf-input-service.exe' probe
```

成功输出 `input-service-ready session=1 secure-desktop-access=ok input-injected=false`。
诊断验证本地通道和 Winlogon 桌面访问权限，不切换桌面，也不发送键鼠事件。
服务诊断日志为安装目录的 `input-service.log`，不记录键鼠内容。

锁屏、输入密码、解锁后的键鼠操作仍需用户手动验收；只读诊断成功不能替代
这些实机结果。需要 Ctrl+Alt+Delete 的系统策略所涉及的安全注意序列不由普通
`SendInput` 实现，本次没有新增 SAS 策略配置。

## Linux 用户自启动

当前用户安装的是 `viewflow-desktop.service`，与旧的 `viewflow-peer.service`
分别管理桌面串流和旧协议服务。桌面服务随用户管理器启动，等待 Hyprland
就绪，因此实际串流在登录图形桌面后启动。

模板配置是 `~/.config/viewflow/desktop-source.json`，每次会话重新读取 Hyprland
PID、Wayland socket、显示器信息；窗口地址和候选列表从现场重新发现。
无窗口时也可启动自动发现流程。守护器会在源进程退出后重试，并校验手动
启动进程的 PID、启动时间和可执行文件，避免重复启动。

```sh
systemctl --user status viewflow-desktop.service
systemctl --user restart viewflow-desktop.service
systemctl --user disable --now viewflow-desktop.service
journalctl --user -u viewflow-desktop.service
```

有效运行配置和源日志保留在 `$XDG_RUNTIME_DIR/viewflow/desktop-drag/`。
本机服务单元包含 NVIDIA EGL 环境变量，监视器为 DP-4；迁移硬件时应同步调整。
服务使用已有配对证书，不重新配对。实际 Hyprland 插件仍须与当前合成器 ABI 匹配。

## 光标被系统抑制时的鼠标移动

2026-09-07 只读检查显示 Windows `GetCursorInfo.flags == 2`，即
`CURSOR_SUPPRESSED`。停止 Deskflow 后该状态仍在；不能因此归因于 Deskflow。
[Microsoft 的定义](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-cursorinfo)
说明这是触摸/笔输入下的系统光标抑制状态。

原实现仅使用 `SetCursorPos` 更新位置。现在每次收到用户实际的远程绝对移动时，
在同步设置物理像素位置后，再发送带 `MOVE | ABSOLUTE | VIRTUALDESK` 的鼠标
移动事件，让此操作也进入 Windows 鼠标输入流。坐标按完整虚拟桌面归一化，
保留 Viewflow 防回环标记；该事件不附带按钮或滚轮。

新增纯结构测试验证负坐标、多显示器范围、像素往返、事件类型和标记；
连同现有 Windows 输入测试共 26 项通过。没有自动发送输入来验收光标显示，
最终显示结果由用户实际移动鼠标确认。

## 接管时关闭光标抑制

按用户要求，输入服务在每条连接的新鼠标 lease 首次收到 DesktopPointerPosition
时，将 HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\EnableCursorSuppression
写为 DWORD 0。相同 lease 后续移动不重复写入；ReleaseAll 或管道重连重置记忆。
这是系统级持久设置，切回 Mac 时不恢复为 1。注册表写入失败仅记录
`cursor suppression disable on handoff: win32_status=...`，不阻断正常输入。
现有实际鼠标移动事件处理保留；写入成功不等同于已验证当前桌面的光标可见，
实际切换后的显示仍由用户验收。诊断 probe 不触发此设置，也不发送输入。
