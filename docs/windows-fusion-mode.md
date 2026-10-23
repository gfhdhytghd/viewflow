# Windows 融合模式

本机的 Windows KVM 虚拟机使用虚拟显示器和直通 Intel GPU，无需打开
RDP/虚拟机查看器。Windows 自动登录后，Viewflow 将应用窗口通过 IVSHMEM
呈现在 Hyprland；Linux 的 NVIDIA GPU 负责呈现。

## 使用

- bar 左侧 Windows 图标：左键请求 Windows 开始菜单，并在对应菜单代理出现后
  聚焦该窗口；右键打开融合设置菜单。
- 右键菜单可切换融合模式，以及 Home / 临时目录文件入口。
- Windows 应用首次出现时默认 **floating**。用户可用原有 Hyprland 快捷键
  切换 tiling；同步逻辑保持平铺窗口的 Hyprland 几何所有权，不强制切回 floating。
- 融合模式禁用捕获窗口的标准 Windows 最小化按钮和系统菜单。应用用自定义按钮
  或 API 绕过菜单自行最小化时，下一次窗口清单更新将其非激活恢复，保留代理身份。
  这是跨进程恢复，不能声称拦截了应用内部的每一次最小化调用。
- 关闭融合模式恢复原最小化样式，不关闭共享内存会话。工作区、平铺和隐藏由
  Hyprland 管理，Windows 桌面和任务栏不作为背景传输。
- Dolphin 文件右键提供“用 Windows 应用打开”和“选择 Windows 应用”。
  前者使用 Windows 默认关联，后者在 Windows 侧打开应用选择器。
  不修改 Linux 的默认文件关联。

```sh
viewflow-windows start
viewflow-windows on
viewflow-windows off
viewflow-windows share home
viewflow-windows share temporary
viewflow-windows open '/home/wilf/Documents/example.docx'
viewflow-windows open --choose '/home/wilf/Documents/example.docx'
viewflow-windows open --dry-run '/home/wilf/Documents/example.docx'
viewflow-windows ping
```

配置文件：`~/.config/viewflow/fusion.json`。`shares.home` 和 `shares.temporary`
分别配置本地根目录与对应 UNC 根目录；默认选择 Home。临时目录为
`~/.local/share/viewflow/shared`，不会自动删除其中的文件。选中临时目录时，
文件必须在该目录内；需要打开其他文件可切回 Home，或显式复制到共享目录。
不会偷偷复制文档再让用户误以为保存修改了原文件。

Home 模式直接打开 `\\172.16.105.62\Home\...`，临时目录模式打开
`\\172.16.105.62\ViewflowTemp\...`，Windows 保存直接写回所选共享内的文件。
模式选择控制此文件入口的路径范围，并不撤销机器原有的 Home SMB 共享和 Z: 映射。
SMB 共享权限由服务器配置管理。跨出所选根目录的符号链接会明确报错；Windows
无法表示的文件名也报错，不会静默改名或打开其他文件。

## 部署与自动启动

- Linux：用户服务 `viewflow-ivshmem-windows.service`，动态发现 Hyprland 会话。
- Windows：`Viewflow-Windows-Linux-IVSHMEM` 交互登录任务运行画面源；
  `Viewflow-Fusion-Agent` 在普通用户交互会话运行开始菜单、文件打开和配置控制。
  该代理不能放到 SSH 的 session 0 或提升的登录令牌下：此次实测提升令牌写
  Credential Manager 返回 1312，普通交互令牌成功。
- Windows 原生程序：`C:\Users\wilf\Viewflow\fusion-20261007\build-final\Release`。
  控制目录为该版本目录下的 `control`，融合开关 `control\mode` 取 `on/off`。
- `viewflow_autologon enable USER DOMAIN` 从 stdin 读取密码，写入 Windows
  `DefaultPassword` LSA secret，再配置 Winlogon；不把密码写入明文注册表值、
  命令行或脚本。管理员可将 `AutoAdminLogon` 改为 `0` 关闭自动登录。
- SMB 使用已有 Samba，加独立 `ViewflowTemp` 共享和 `viewflowvm` 账户。
  该账户的随机密码通过 stdin 和代理临时 RSA 公钥传递，保存在 Windows
  Credential Manager；控制收件箱只有密文，不保存明文密码。
- Samba 等待 network-online，绑定 `lo br0`。`smb3 directory leases = no`
  修复了本机实测 Linux 新建文件在 Windows Home 根目录不可见的问题。
  文件租约本身未禁用。
- 配对证书与原输入路由保持不变。控制操作使用既有 SSH 身份，经 JSON 文件队列
  交给交互代理；没有新增对外控制监听器。接口等待超时只报告请求可能仍在等待，
  不关闭视频会话。

开始菜单使用 Windows 的 `WM_SYSCOMMAND/SC_TASKLIST`，不是模拟 Win 键。
开始菜单/搜索 CoreWindow 的归属从进程和窗口清单确定，必要时使用其 owning
ApplicationFrameWindow 捕获。原生记录的 `2048` 标记独立于图标资源，Linux
用它生成 `ViewflowReverse-WindowsStart-*` 类名；点击按钮后只聚焦这一类窗口。
两端需同时更新；旧的非融合模式不发送这个标记。

参考：[Windows 开始菜单系统命令](https://learn.microsoft.com/en-us/windows/win32/menurc/wm-syscommand)、
[自动登录与 LSA 存储](https://learn.microsoft.com/en-us/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon)、
[Samba 目录租约](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html#SMB3DIRECTORYLEASES)、
[上游讨论的宿主机文件变更失效问题](https://lists.samba.org/archive/samba-technical/2026-August/141008.html)、
[Dolphin 文件菜单](https://develop.kde.org/docs/apps/dolphin/service-menus/)。

## 验证范围与回退

见 [现场记录](evidence/fusion-20261007/report.md)。项目要求真人操作鼠标键盘，
因此没有自动点击开始菜单、应用选择器或切换窗口平铺来冒充交互验收。

关闭融合策略：`viewflow-windows off`；停止传输：
`systemctl --user stop viewflow-ivshmem-windows.service`。
移除 bar 按钮只需移除 `shell.qml` 中 `Viewflow Windows fusion button` 对应的
TextModule。原始 bar 备份为 `shell.qml.before-viewflow-fusion`，回退时注意保留
之后其他修改。两个 Windows 计划任务可分别禁用。
Samba 原配置备份为 `/etc/samba/smb.conf.before-viewflow-fusion-20261007`。

### 控制代理与菜单定位修正

融合代理计划任务通过 `viewflow_fusion_launcher.exe`（GUI 子系统）启动，
使用 `CREATE_NO_WINDOW` 防止 Windows Terminal 接管 PowerShell 控制台。
代理日志保存在 guest `control/agent.log`。Win 按钮传递屏幕坐标，菜单定位
使用 bar 所在的 Hyprland 会话，在对应工作区的按钮下方显示。

2026-10-08：其余 Viewflow 登录任务（传输、音频、壁纸、Peer、Mac 链路）
和启动前输入任务也已改用该 GUI supervisor；只设置 PowerShell
`-WindowStyle Hidden` 无法阻止 Windows Terminal 控制台委派。
传输和音频脚本的子进程使用 `-NoNewWindow` 继承无控制台环境。
原任务 XML 保存在 guest `%LOCALAPPDATA%\Viewflow\startup-backup-*`。

### 16K shared-memory capacity

The shared BGRA route accepts up to 16384 × 16384 (1 GiB/frame), with four
independent pixel banks and a small control BAR. The deployed signed Windows
IVSHMEM driver maps five devices: control at PCI 0:5 and four 1 GiB slots at
0:6..0:9. The control file reserves 1 MiB; the protocol uses 4096 bytes.

The VM-specific QEMU 11.1.1 build applies
[`viewflow-cpu-only-ivshmem.patch`](../platform/qemu/viewflow-cpu-only-ivshmem.patch).
The CPU-only shared buffers are excluded from VFIO DMA mapping, so sparse
pages are committed by actual frame writes rather than pinned at VM startup.
This does not change guest RAM DMA mappings or GPU ownership. See the
[build and deployment notes](../platform/qemu/README.md). The earlier single
8 GiB BAR configuration was rejected by the Windows driver and is superseded.

After boot all five devices report OK. Before pixel publication, the four
slots use 0 physical bytes and the control uses 4 KiB. Four 16384×2 frames
use 512 KiB total. Four full 16384×16384 frames were transferred and validated
byte-for-byte on the Linux CPU, with RGB/alpha samples checked after GPU upload.
The full-size test pages were released afterward. Pages grow to the amount
written during the session; the sparse address reservation alone uses no
pixel RAM. A full 1 GiB frame is a capacity limit, not a 33 ms performance
claim. GPU atlases and readback textures follow actual dimensions; encoded
transport retains its separate codec limits.

Windows Fast Startup (`HiberbootEnabled`) is disabled: resuming old hardware
state after changing PCI devices caused overlapping BAR assignments and a
stalled boot. A cold boot restored normal device initialization.

### Start popup behavior

The Start popup is GPU-cropped to nontransparent bounds. Before requesting
Start, the button controller installs a Hyprland initial-position rule from
its bar coordinates. The receiver never applies the Windows source rectangle
to shell proxy placement, including the first frame. It restores pin after
workspace changes, preventing Stage from covering the popup.

The user control path uses `viewflow-fusion-control.service`, a private Unix
socket and a persistent authenticated SSH channel to `viewflow_fusion_relay.exe`.
The relay submits atomic inbox files to the interactive agent. It does not
replay an action after a missing reply. Direct SSH remains a fallback when the
local service is unavailable. Twelve consecutive health calls succeeded;
warm requests measured approximately 30–49 ms. This is control round-trip
latency, not full button-to-photon latency.

`tools/windows-fusion-dismiss.lua` observes non-consuming button presses.
Clicks outside all visible shell proxies request an idempotent `dismiss-start`
action; pointer motion alone does not close the menu. Cropped shell pointer
motion uses Windows absolute virtual-desktop mouse input for XAML hover.

Windows proxies retain one/two-finger remote touchpad input. Three or more
contacts release the remote touchpad and keep the remainder of that gesture
local until all fingers lift. The Hyprland plugin likewise keeps three-or-more
finger proxy gestures on the compositor route. Ordinary pointer input and
user-controlled floating/tiling are unchanged.

The user confirmed first-map placement, hover, outside-click closure, and
three-finger routing on 2026-10-08. Opening now uses the plugin's
`focus_without_warp` keyboard-focus operation. Start/Search handoff retains one
Wayland surface and updates its guest input ID. Shell-owned IME candidates use
the owner's host position plus their guest-relative offset, are pinned, and do
not take keyboard focus; clicks on IME candidates do not dismiss Start.
These follow-up input fixes still require user-operated acceptance. A reported
residual taskbar “Start” tooltip is still under diagnosis; source enrollment now
logs its window class and root owner when reproduced.

Office Open With entries: install `deploy/linux/viewflow-windows-{word,excel,powerpoint}.desktop`
into `~/.local/share/applications` and run `update-desktop-database` there.
Each calls `viewflow-windows open --app word|excel|powerpoint %F`; `--app`
and `--choose` are mutually exclusive. The guest resolves the installed Office
executable through App Paths (user/machine, 64/32 bit) and opens the quoted UNC
original directly. Existing default file associations are retained.

The user subsequently confirmed the follow-up input behavior was normal.

### FUSE-backed Home directories

This host's Downloads is a symlink into Lazycat's user-only rclone mount.
Samba root path checks receive EACCES there, despite `force user = wilf`.
`viewflow-smb-lazycat.service` runs a user-owned bindfs view of the existing
mount at `~/.local/share/viewflow/smb-lazycat`, exported as `ViewflowCloud`.
The original rclone mount and its cache remain untouched. bindfs is built from
https://github.com/mpartel/bindfs commit `51d00ea70772c0d84a9e2e6d80a3290a9783bcc2` into
`~/.local/lib/viewflow/bindfs` (`autogen.sh`, configure with that prefix, make,
make install). See the [bindfs manual](https://bindfs.org/docs/bindfs.1.html).
The unit uses `--no-allow-other -o allow_root`; libfuse implements the root/user
restriction in userspace over its kernel allow_other mount flag.
`/etc/fuse.conf` enables `user_allow_other` for this user-owned mount.

Home configuration supports `mounts: [{"root": "/home/wilf/lazycat_automount/wilfmeo",
"unc": "\\\\172.16.105.62\\ViewflowCloud"}]`. The original resolved path must
still lie inside the selected share before a mount-specific route is applied.
Only the UNC route changes; no document copy or save-back synchronization is
introduced. The cloud SMB share uses the same authenticated users and force
user/group as Home. Root configs have `.before-viewflow-office` backups.

Windows transient/tool surfaces carry a dedicated popup shadow flag. Tight
opaque perimeters with a validated corner contour get a compact attached
shadow; unknown/padded/translucent popup boundaries retain their captured
appearance without another synthetic rectangle. This preserves native pixels
instead of threshold-cropping potentially translucent content. The producer
and receiver must be upgraded together for the added 4096 flag.

Resource-saving resident updates retain a per-window last-picture cache on
Linux. Missing regions keep their last received color and alpha; only pixels
present in a new update replace them, including real transparent pixels. Input
regions use the same retained alpha. Resizing preserves overlapping source
pixels, while never-received new areas remain unknown/transparent. Cache
storage follows actual window dimensions and is released when its proxy closes.
