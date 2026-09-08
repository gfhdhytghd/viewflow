# Version 3 installation result

## 最新：Apple Developer 后台实际核验

通过当前桌面 `mcp__cua_repl.js` 的 CUA 浏览器入口，进入已登录的 Apple Developer 后台，核实团队 Haikuo Lin / 9887KU7FN7、explicit bundle ID org.viewflow.trackpad-probe.host。页面：

https://developer.apple.com/account/resources/identifiers/bundleId/edit/WHM874SAHK

### 普通 Capabilities 列表

已读取完整可见能力控件。DriverKit 相关可直接勾选项目包括：

- DriverKit (development)
- DriverKit Allow Any UserClient (development)（未勾选，未使用）
- DriverKit Allow Third Party UserClients
- DriverKit Communicates with Drivers（未勾选，未拿它替代 macOS userclient-access）
- DriverKit Family Audio/HID Device/HID EventService/MIDI/Networking/SCSIController/Serial (development)
- DriverKit PCI/Transport HID/USB Transport (development)

System Extension 已选中。此列表没有 DriverKit UserClient Access 或其 development 版本的可勾选项。

### Capability Requests 列表与截图

切换 Capability Requests 后，实际看到：

- 名称：DriverKit UserClient Access
- 能力标识：DRIVERKIT_USERCLIENTACCESS
- 状态：No Requests
- 左侧为 Request capability 链接（加号），目标 https://developer.apple.com/contact/request/system-extension/
- Save 为禁用状态，没有直接启用此能力的复选框。

已用页面搜索筛选 DriverKit UserClient，并通过 CUA 截图确认上述整行、团队和 explicit bundle ID 同屏。浏览器标签保留为交接页。未点击申请链接、未填写或提交申请，也未保存任何能力变更。

因此，本次结论基于真实后台，而非只依据 Xcode 错误：**该团队当前宿主 App ID 的后台把 UserClient Access 放在申请能力列表，状态为 No Requests，普通开发能力列表未提供可直接启用入口。** 按用户明确的“后台确实要求申请则停下”要求停止 provisioning，不把此结果泛化为所有 DriverKit 开发 entitlement 均需申请。

### WWDC22 110373 对照

已实际读取 https://developer.apple.com/videos/play/wwdc2022/110373/ 的 transcript。它分别描述 macOS 的 userclient-access（限定 driver bundle 数组）及 iPadOS 新增的 Communicates With Drivers；不能仅因后者在后台可选就替换前者。保留用户指出的 development 公开背景，但以当前该 App ID 实际可操作界面作为本轮操作边界。

### 当前结果

没有生成不匹配或缺权的 profile，没有更改精确 bundle 限定，没有添加 allow-any-userclient-access，没有执行版本3安装或 --driver-status，没有运行 --receive-stdin 或注入输入。SIP 实时再次检查为 enabled。此前已成功的 DEXT v3 构建仍保留，宿主 provisioning 阻碍仍未解决。

下方为上一轮构建核验记录。

状态：阻塞于宿主 DriverKit UserClient Access provisioning；DEXT v3 已签名构建成功，版本3未安装，未进行 status ABI 验收。

## 本轮执行

- 已完整读取 input-install-task.txt；使用新版 mcp__cua_repl.js 操作 Xcode。未创建其他任务，未修改并行开发的 C++/Swift 实现或删除 entitlement。
- Xcode 的 DEXT destination 为 My Mac (DriverKit)，Cmd+B 实际显示 Build Succeeded（23:41）。产物 CFBundleVersion 为 3，codesign --verify --strict 验证通过。
- DEXT 实际产物：`/Users/linhaikuo/Library/Developer/Xcode/DerivedData/VFTrackpadProbe-agrwnfsoljsdclgxgitmuwktavsg/Build/Products/Debug-driverkit/org.viewflow.trackpad-probe.dext`。
- profile UUID 为 `8d6796ec-9ed8-44de-983c-157892e0f8f6`，verify-profile-device.py 确认包含本机。最终签名包含 driverkit、driverkit.family.hid.device，未加 allow-any-userclient-access。
- 本机 GUI 的 DEXT 构建未复现 SSH 中的 errSecInternalComponent；未修改钥匙串安全或处理密码。

## 宿主具体阻碍

通过 Xcode Signing & Capabilities 核验：自动签名已开启，团队 Haikuo Lin / 9887KU7FN7，bundle ID org.viewflow.trackpad-probe.host。界面报：

> Provisioning profile "Mac Team Provisioning Profile: org.viewflow.trackpad-probe.host" doesn't include the DriverKit UserClient Access capability.

> Entitlement com.apple.developer.driverkit.userclient-access requires approval from Apple to include in a profile.

使用 Xcode Try Again 重试自动 provisioning 后错误仍存在。本机 xcodebuild 复核同样 exit 65 / BUILD FAILED，完整日志：`input-install-host-build.log`。构建在 provisioning 校验阶段失败，不能判定宿主 Swift 代码已通过本轮编译。

已打开能力选择器并搜索 Driver，当前 macOS 可见项没有 Communicates with Drivers。Apple 文档将 Communicates with Drivers 描述为 iPadOS entitlement，macOS 使用 userclient-access：

- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.communicates-with-drivers
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.userclient-access

现有宿主 entitlement 请求仍完整保留：userclient-access 数组指定 org.viewflow.trackpad-probe，sandbox 临时 IOKit 例外 IOUserUserClient，以及 system-extension.install。没有按 Xcode 提示删除权限，也未以更宽泛的驱动访问权限替代。

后续桌面 CUA 核查（2026-09-07 23:48 EDT）确认：普通 Capabilities 列表没有可直接启用的 DriverKit UserClient Access；该项位于 Capability Requests，显示 No Requests 并提供申请入口。未提交申请。该结论只针对本账号当前宿主权限，不代表基础 DriverKit/HID 开发权限也需要审批。

## 安装与无输入验收

- 因宿主未成功签名构建，未覆盖 /Applications/VFTrackpadHost.app，未安装不完整版本3组合。
- systemextensionsctl list 仍显示既有 org.viewflow.trackpad-probe (0.1/2) activated enabled。
- 未执行 --driver-status：已安装的是旧版，无法提供版本3 ABI=1/submitted=0 的有效验收；不能把旧版或仅构建的 DEXT 当作安装成功。
- 未执行 --receive-stdin、输入转发、合成触控或手势测试。
- csrutil status 实时为 enabled。未撤销证书/profile，未改变 SIP 或系统保护。

## 继续所需

需要取得可给宿主 org.viewflow.trackpad-probe.host 授予 userclient-access=[org.viewflow.trackpad-probe] 的匹配开发 profile，或由开发者后台核实/解决当前 capability 授权。Xcode 已停在具体错误页面并提供 Request Access 入口；本轮未代用户提交 Apple 申请。

取得授权后：经 Xcode 重新 provision → 本机构建并核验两个 profile 与最终 entitlement → 备份旧宿主并正常更新安装 v3 → 仅运行 /Applications/VFTrackpadHost.app/Contents/MacOS/VFTrackpadHost --driver-status，验证 abi=1、submitted=0 并记录实际输出。
