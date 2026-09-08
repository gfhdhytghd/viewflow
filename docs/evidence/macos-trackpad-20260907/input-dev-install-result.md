# Post-reboot verification: 2026-09-08

SSH live checks after the user rebooted the Mac:

```text
kern.boottime: Tue Sep 8 01:50:23 2026
org.viewflow.trackpad-probe (0.1/3) [activated enabled]
No version 2 entry remains.
Driver PID 307, system-extension directory 343B53E3-9F80-4229-8E7A-366961426524
{"abi":1,"submitted":0,"releases":0,"errors":0,"active_contacts":false,"input_injected":false}
System Integrity Protection status: enabled.
```

The development UserClient access path now passes the read-only ABI check.
No contact reports were sent. Native gestures and physical forwarding remain
user-operated acceptance work, not verified by this status result.
Linux read-only inspection also confirmed /dev/input/event17 is Apple Inc.
Magic Trackpad with 16 slots; events_read=false.

The earlier reboot-pending and build records below are historical.

---

# Latest verification: 2026-09-08 00:40 EDT

Version 3 installation completed after the user-authorized development permission change.
A separate SSH read-only verification returned:

```text
(0.1/3) [activated enabled]
(0.1/2) [terminating for upgrade via delegate]
IOServiceOpen failed: 0xe00002bc
PID 9799 /Library/SystemExtensions/F7572EDA-5DFD-4E53-B2C3-1F43615DD2D3/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe
```

The running process is still the previously verified version 2 path. The Mac
desktop installation task reports that sysextd deferred removal until reboot.
A normal reboot is pending. ABI=1 and zero-submission status are not yet verified;
this result must not be presented as a functioning input channel. No input was
injected and no reboot was initiated. The following build record was captured
before installation and is retained as historical evidence.

---

# DriverKit Allow Any UserClient development 签名与安装结果

更新：2026-09-08 00:40 America/New_York。

## 当前结论

两目标均已通过当前桌面 CUA 操作 Xcode GUI 的正常 Debug 构建。实际 DEXT 签名和嵌入的 development profile 均包含 `com.apple.developer.driverkit.allow-any-userclient-access=true`，两份 profile 均包含当前 Mac。用户确认后已备份并替换宿主，通过 CUA 点击正常 Request Driver Installation，GUI 返回 Activation completed，系统显示版本3 activated enabled。但旧版本2仍运行，系统日志明确安排下次重启卸载；两次只读 `--driver-status` 均失败，不能宣称 ABI1/submitted0 验收成功。下一步是用户正常重启 Mac 后再次只读验收，本轮未重启电脑。

## Developer 后台与签名配置

- 在当前桌面 Chrome 的 Apple Developer 后台打开驱动 App ID `org.viewflow.trackpad-probe`（页面标识 C69FM7X9JU）。
- 首次读回该页面时，DriverKit (development)、DriverKit Allow Any UserClient (development)、DriverKit Family HID Device (development) 均已经勾选，Save 禁用。因此本轮未反复切换能力，也未声称从未启用改成启用。
- 未提交任何分发权限申请。
- 两项目保留 Automatic signing，Team `9887KU7FN7`（Haikuo Lin），Apple Development: Haikuo Lin (5843T48V3V)。宿主 GUI 显示 Xcode Managed Profile，无签名错误。
- DEXT 已同步的 allow-any entitlement 保留；宿主未请求精确 userclient-access，实际签名保留 system-extension.install、app-sandbox、IOUserUserClient IOKit 沙盒例外。
- 未编辑任何 C++ / Swift 实现文件。未出现本轮代码编译错误。

## GUI 构建与产品

- DEXT：Xcode 显示 `VFTrackpadProbe Build Succeeded • Today at 12:34 AM`，目的地 My Mac (DriverKit)，CFBundleVersion=3。
- DEXT 产品：`/Users/linhaikuo/Library/Developer/Xcode/DerivedData/VFTrackpadProbe-agrwnfsoljsdclgxgitmuwktavsg/Build/Products/Debug-driverkit/org.viewflow.trackpad-probe.dext`。
- 将该完整签名 DEXT 复制到项目既有宿主嵌入来源 `build-signed/Build/Products/Debug-driverkit/org.viewflow.trackpad-probe.dext`，再 GUI 构建宿主。
- 宿主：Xcode 显示 `VFTrackpadHost Build Succeeded • Today at 12:35 AM`，目的地 My Mac。
- 宿主产品：`/Users/linhaikuo/Library/Developer/Xcode/DerivedData/VFTrackpadHost-davqtyvgeqxwnoeamjkqbadngztq/Build/Products/Debug/VFTrackpadHost.app`。
- 宿主自身原有 CFBundleVersion=1 未修改；嵌入 DEXT 为所请求的版本3。
- `codesign --verify --deep --strict` 宿主通过；DEXT 独立 `codesign --verify --strict` 通过。
- 宿主内嵌 DEXT 实际签名再次读回，确认 allow-any=true、driverkit=true、driverkit.family.hid.device=true、development get-task-allow=true。

## Profile 与本机匹配

当前 Mac provisioning UDID：`00008132-000161422E38801C`。

- DEXT：DriverKit Team Provisioning Profile: org.viewflow.trackpad-probe，UUID `b935fc60-a890-4161-a7df-db559f4f5db9`。
- 宿主：Mac Team Provisioning Profile: org.viewflow.trackpad-probe.host，UUID `e5eff746-99b1-442c-8788-aeaa3229a446`。
- 对最终宿主包中两份 embedded.provisionprofile 运行 `verify-profile-device.py`，均返回 PASS authorizes this Mac。
- 用 security cms 解码 DEXT profile，确认其 Entitlements 中 allow-any-userclient-access=true，App ID 为 `9887KU7FN7.org.viewflow.trackpad-probe`。

## 备份与安装状态

- 旧宿主完整备份：`installation-backups/VFTrackpadHost-before-allow-any-20260908.app`，含版本2 DEXT，备份签名验证通过。
- 原构建用 DEXT 移至可恢复备份：`installation-backups/DEXT-before-allow-any-20260908.dext`。
- 未删除旧备份 `installation-backups/VFTrackpadHost-build1.app`。
- 用户后续明确确认安装含 allow-any 的开发版本3。未再索要重复确认。
- 退出旧宿主后，将原 `/Applications/VFTrackpadHost.app` 移至额外可恢复备份 `installation-backups/VFTrackpadHost-replaced-20260908.app`，完整复制 GUI 构建的新宿主至 `/Applications/VFTrackpadHost.app`，深度严格签名验证通过。
- CUA 启动新宿主并点击 Request Driver Installation，返回 `Activation completed. Device enumeration and gestures have NOT been verified.`。未出现新系统授权弹窗，也没有自动审批工具拒绝。
- 安装的版本3 DEXT 路径：`/Library/SystemExtensions/343B53E3-9F80-4229-8E7A-366961426524/org.viewflow.trackpad-probe.dext`。其实际签名再次读回 allow-any=true，严格签名验证通过。
- 安装后两份 profile 的本机匹配复验均 PASS。

## 只读验收与重启阻塞

`systemextensionsctl list` 的相关原文：

```text
* * 9887KU7FN7 org.viewflow.trackpad-probe (0.1/3) org.viewflow.trackpad-probe [activated enabled]
    9887KU7FN7 org.viewflow.trackpad-probe (0.1/2) org.viewflow.trackpad-probe [terminating for upgrade via delegate]
```

仅运行 `/Applications/VFTrackpadHost.app/Contents/MacOS/VFTrackpadHost --driver-status`，初次及复查返回相同原文，复查进程退出码1：

```text
IOServiceOpen failed: 0xe00002bc (check host DriverKit user-client entitlement and driver version)
```

只读进程检查显示 PID 9799 仍来自旧版本2路径 `/Library/SystemExtensions/F7572EDA-5DFD-4E53-B2C3-1F43615DD2D3/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe`。IORegistry 的 VFTrackpadRoot 仍为旧匹配 personality，不包含新 UserClientProperties。

00:38:46 的系统日志原文：

```text
Dext org.viewflow.trackpad-probe v2 in executable dext bundle org.viewflow.trackpad-probe at /Library/SystemExtensions/F7572EDA-5DFD-4E53-B2C3-1F43615DD2D3/org.viewflow.trackpad-probe.dext is being replaced and cannot be terminated right away
turning the responsibility for termination of org.viewflow.trackpad-probe, version 2 over to delegate (with uninstallation at the next reboot)
```

因此不能把当前 IOServiceOpen 错误归结为缺少开发 entitlement；已有证据表明运行中的旧驱动尚未退出。未强杀驱动、卸载扩展或绕过 SIP；等待正常重启后复查版本3实际运行以及 ABI1/submitted0。

## 安全边界

`csrutil status`：`System Integrity Protection status: enabled.`

未关闭 SIP，未注入合成输入，未运行 receive-stdin，未进行触控转发或实际手势测试。本轮仅执行安装后宿主的 `--driver-status` 及系统/profile/签名/日志只读检查；ABI1、submitted0 尚未取得。

参考用户提供并已阅读的 Apple DTS 指南：[development DriverKit entitlements](https://developer.apple.com/forums/thread/809202)、[Allow Any UserClient development-only](https://developer.apple.com/forums/thread/819362)。本轮成功签名/profile 验证与其 development 无需分发审批说明一致。
