# Native MT v4 签名安装结果

时间：2026-09-08 02:28 America/New_York。

## 结论

DEXT4 与宿主均通过 Xcode GUI 正常签名构建；版本3宿主已备份，版本4已通过正常安装请求完成更新，系统显示 activated enabled。当前旧版本3进程尚未退出，系统明确安排下次重启卸载，因此 ABI2/submitted0 与原生多指挂载验收尚未通过。遵照要求未自动重启。

## 构建、配置与签名

- CUA 打开 VFTrackpadProbe.xcodeproj，目的地 My Mac (DriverKit)，Cmd+B，GUI 显示 Build Succeeded，02:24 AM。DEXT CFBundleVersion=4。
- 将完整已签名 DEXT 从 `/Users/linhaikuo/Library/Developer/Xcode/DerivedData/VFTrackpadProbe-agrwnfsoljsdclgxgitmuwktavsg/Build/Products/Debug-driverkit/org.viewflow.trackpad-probe.dext` 复制到既有 `build-signed/Build/Products/Debug-driverkit/org.viewflow.trackpad-probe.dext` 嵌入来源。旧来源可恢复备份为 `installation-backups/DEXT-before-native-v4.dext`。
- CUA 打开宿主工程，目的地 My Mac，Cmd+B，GUI 显示 Build Succeeded，02:25 AM。无本轮 C++/Swift 编译错误；未修改任何 C++/Swift。
- 宿主产物：`/Users/linhaikuo/Library/Developer/Xcode/DerivedData/VFTrackpadHost-davqtyvgeqxwnoeamjkqbadngztq/Build/Products/Debug/VFTrackpadHost.app`。
- 保留既有 Automatic signing / Team 9887KU7FN7 与 development 权限，没有提交分发申请。
- 宿主深度严格 codesign 验证通过，DEXT 独立严格验证通过。
- 已安装的 v4 DEXT 实际签名读回包含 driverkit=true、driverkit.allow-any-userclient-access=true、driverkit.family.hid.device=true、development get-task-allow=true。
- profile 本机匹配复验：宿主 `e5eff746-99b1-442c-8788-aeaa3229a446`、DEXT `b935fc60-a890-4161-a7df-db559f4f5db9`，verify-profile-device.py 均返回 PASS authorizes this Mac。本机 provisioning UDID 为 `00008132-000161422E38801C`。
- 源码只读确认 native_protocol.h ABI=2；VFTrackpad.cpp Product 为 Viewflow Native MT Protocol Experiment，VendorID=0x5ac、ProductID=2。
- 初始 shell git status 因系统默认 CommandLineTools 路径失效返回 xcrun 错误；不影响 GUI Xcode 构建，未更改全局开发目录。

## 备份与安装

- 安装前确认当前宿主嵌入 DEXT 为版本3，正常退出宿主后，将旧应用完整移至 `installation-backups/VFTrackpadHost-v3-before-native-v4.app`；备份签名验证通过。
- 新应用复制至 `/Applications/VFTrackpadHost.app`，再次严格深度签名验证通过。
- CUA 点击 Request Driver Installation，GUI 返回 `Activation completed. Device enumeration and gestures have NOT been verified.`。未出现需要处理的新审批弹窗或工具拒绝。
- 系统安装 v4 路径：`/Library/SystemExtensions/70F3ACEE-EB0F-41AC-86E7-CEF8D70E8BF3/org.viewflow.trackpad-probe.dext`。

## 只读验收原文

只运行 `/Applications/VFTrackpadHost.app/Contents/MacOS/VFTrackpadHost --driver-status`，退出码1：

```text
Driver status/ABI check failed: 0xe00002c2
```

系统扩展状态：

```text
    9887KU7FN7 org.viewflow.trackpad-probe (0.1/3) [terminating for upgrade via delegate]
* * 9887KU7FN7 org.viewflow.trackpad-probe (0.1/4) [activated enabled]
```

运行进程仍是 PID307，来自旧 v3 `/Library/SystemExtensions/343B53E3-9F80-4229-8E7A-366961426524/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe`。

02:26:54 系统日志明确：

```text
Dext org.viewflow.trackpad-probe v3 in executable dext bundle org.viewflow.trackpad-probe at /Library/SystemExtensions/343B53E3-9F80-4229-8E7A-366961426524/org.viewflow.trackpad-probe.dext is being replaced and cannot be terminated right away
turning the responsibility for termination of org.viewflow.trackpad-probe, version 3 over to delegate (with uninstallation at the next reboot)
```

当前 `ioreg -r -n VFTrackpad` 子树：

```text
VFTrackpad (AppleUserHIDDevice), Product = Viewflow Trackpad Enumeration Probe
  IOHIDInterface
    AppleUserHIDEventDriver (AppleUserHIDEventService)
      IOHIDEventServiceUserClient
```

当前 VFTrackpad 子树没有 AppleMultitouchTrackpadHIDEventDriver / AppleMultitouchDevice；由于仍为 v3，该结果不是 v4 协议匹配失败的证据。

feature_gets、feature_sets、unknown_features：本轮不可取得（ABI查询失败），不可记为0。最近3分钟按驱动进程筛选的日志只有表头，无 v4 feature get/set 日志。ABI2/submitted0 尚未取得。

## 安全与下一步

`csrutil status` 返回 `System Integrity Protection status: enabled.`。未执行 receive-stdin、触控报告注入、键鼠焦点测试、强制终止驱动或自动重启。

待正常重启后，由主任务再次仅执行 --driver-status、systemextensionsctl、限定 VFTrackpad 子树的 ioreg 与日志读取，确认实际运行 v4、ABI2、submitted0、feature counters 以及原生多指驱动挂载。
