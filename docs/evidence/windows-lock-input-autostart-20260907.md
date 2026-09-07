# Windows 锁屏输入服务与 Linux 自启动部署（2026-09-07）

范围：只增加 Windows 锁屏界面的远程键鼠支持，不改变 Linux 锁屏行为；
按用户追加要求安装 Linux 用户桌面串流自启动。

已部署 Windows `ViewflowInput` 服务：Auto / LocalSystem，主服务在 session 0，
输入 worker 在 session 1。接收端 `main-session.ps1` 已设置
`VIEWFLOW_WINDOWS_INPUT_SERVICE=1`，现有任务 `ViewflowMain-Active` 已启动。
安装器重复更新路径经过验证；旧接收端和启动脚本保存在原目录带
`before-lock-input` 时间戳的备份中。

Windows 部署哈希（SHA256）：

- `C:\Program Files\ViewflowInput\vf-input-service.exe`：
  `c48082d82901294f0e6d0dd5f016ec385925ed2f5d2154373e05ed99eee4af24`
- `C:\Users\wilf\Viewflow\desktop-test\vf-media-peer.exe`：
  `fea86533f8b418af0aee76e78f5a4e962c3d25aaea3c1b2ff11a5791aba2d732`

在用户交互会话通过临时任务执行只读 `probe`，结果：

```text
input-service-ready session=1 secure-desktop-access=ok input-injected=false
```

临时 `ViewflowInput-Probe` 任务已删除。该结果确认服务端身份、会话、本地消息
往返和 Winlogon 桌面访问权限；不证明用户已经完成锁屏输入密码测试。

验证时发现 `std::fs::File::read` 会把 Windows 非阻塞管道的 `ERROR_NO_DATA`
归类为 BrokenPipe 并转成 EOF。辅助通道改用 `ReadFile` 保留原生状态；
新增 Windows 本地管道测试覆盖空闲、读写、取消、真实断开，不发送 OS 输入。
Windows 原生输入相关测试共 24 项通过。Linux 配置刷新测试和包含无窗口自动
发现模式的 hermetic launcher 测试通过，Linux native-gpu-nvenc Release 构建通过。

Linux 已安装并启用 `~/.config/systemd/user/viewflow-desktop.service`，验证为
`enabled` / `active`。配置模板为 `~/.config/viewflow/desktop-source.json`（0600）。
服务补齐本机 NVIDIA EGL 环境，等待 Hyprland 后重建运行时 PID、socket、候选
窗口信息。旧 `viewflow-peer.service` 保持运行。

检查时现有源 PID 642393、Windows 接收端 PID 16656 已持续连接，Windows
呈现帧号超过 3480；这里只观察日志，没有自动移动鼠标、按键或改变焦点。
当时 Linux 运行中源二进制哈希为
`36807331d6326f55dfa2cc1649fbb2d0868b264fdd5ff613b67ff28f9059b85f`；
本次构建后的目标文件哈希为
`4575c4e7facd17a85a91766016e4d8623990b4c775a1fa782a52461b976af878`，
已运行进程尚持有旧 inode，下一次服务启动使用新目标文件。PID 仅为此次观察值，
后续管理进程必须重新验证身份。

共享工作区同期还有触控板、macOS 等修改；未回退这些工作。本地输入服务与
接收端同步编译部署，避免本地消息格式版本不一致。

使用和维护说明见 [windows-lock-input.md](../windows-lock-input.md)。

## 光标抑制修正部署

用户确认坐标能够跨屏，但 Windows 光标始终不可见。只读 `GetCursorInfo`
返回 flags=2；按用户要求停止并禁用 Deskflow 后，仍为 flags=2。
因此没有把问题归因于 Deskflow。

2026-09-07 16:00（Windows 本地时间）更新输入辅助服务，鼠标绝对移动路径
增加真正的带 Viewflow 标记的 `SendInput` 鼠标事件，同时保留同步像素定位。
本地消息格式仍为 VFI2，不需要替换运行中的网络接收端。

新安装 `vf-input-service.exe` SHA256：
`abdc6e0b4ac420b4a132e56382f714da890c2250fdc7d4501a4c6f14df9e70a8`。
检查服务为 Running，worker 位于 session 1，Windows 接收端与 Linux 用户服务
均保持运行，Deskflow 为 Stopped。Windows 输入相关测试 26 项通过。
未自动发送输入，光标是否恢复显示留待用户真实鼠标操作验证。

## 接收端版本被覆盖后的对齐

用户再次报告光标隐藏时，Windows Deskflow 仍为 Stopped / Disabled，没有
Deskflow 进程或计划任务；Linux `deskflow.service` 却正在运行，现已按用户
禁用 Deskflow 的要求执行 `systemctl --user disable --now deskflow.service`，
验证 disabled / inactive，进程退出。

同时发现运行中 Windows 接收端 SHA256 为
`d5ef113c7347a918cd2c1f1bd8f3fbf31c5edb83ea79d2921827ea184878738f`，
其二进制既不包含 `VIEWFLOW_WINDOWS_INPUT_SERVICE`，也不包含输入服务客户端
的错误字符串。启动脚本虽然仍设置环境变量，但该接收端没有对应功能，因而
绕过了已安装的输入服务与光标修正。

重新从当前完整工作区构建，保留已经修复的动态画布路径，Windows 输入测试
26 项通过。对齐后部署的接收端 SHA256：
`4a3ff6f267ee977f8964754624b0225a53a3ac3c37dfb5be02c0613800776e7f`。
部署前检查其包含输入服务环境变量支持，备份被替换文件；启动脚本继续设置
`VIEWFLOW_WINDOWS_INPUT_SERVICE=1`。两端重连后，接收端 PID 3192 位于
session 1，呈现帧号已超过 480。输入辅助服务保持光标修正版，不改消息格式。

后续构建接收端时须保留输入服务和动态画布两部分现有改动，避免使用缺少
这些改动的旧快照覆盖当前部署。光标显示仍以用户真实移动后的结果为准，
未通过自动输入进行测试。

对齐后用户手动跨屏测试回复“已经显示”。同期输入服务记录新的 session 1
客户端连接，接收端收到 generation=2 的桌面位置事件；确认这次真实用户输入
已经使用输入服务，光标显示恢复。
