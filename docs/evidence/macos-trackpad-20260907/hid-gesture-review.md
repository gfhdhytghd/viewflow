# HID 多指失败：联网研究与代码审查

日期：2026-09-08。目标平台：本机 Linux → macOS 27 M4，SIP 开启。
本轮仅做源码、系统配置和离线测试审查，没有注入输入或部署驱动修改。

## 结论

当前最有力的解释是缺少 Apple 原生多点触控协议/手势消费者，而非开发签名或 SSH 完全失败。
这是结合现场挂接链和参考实现的高置信判断，不是 Apple 对所有通用触控板的官方不支持声明。
仍需记录实际多指报告内容，排除报告格式和联系人生命周期问题。

## 已确认的问题

1. **P1：通用报告路径未实现原生手势接入。** `descriptor.h:13-17` 仅声明 0x0D/0x05 和五个 Finger 集合；`VFTrackpad.cpp` 只把这些报告交给 handleReport，没有 Apple 专用协议或用户态手势识别器。现场挂接的是 AppleUserHIDEventDriver。已有报告成功进入 HID 系统，不能证明 Apple 手势引擎消费了这些触点。
2. **P1：实体点击完全丢失。** `linux_forward.py:118-130` 只处理 EV_SYN 和 EV_ABS，未处理 EV_KEY/BTN_LEFT；`report:24-31` 和 descriptor 均无按钮字段。因此这条试验链路不能传递触控板实体按压点击。此问题不等同于多指失败的唯一根因。
3. **P2：几何和触点信息被简化。** `linux_forward.py:65-69,104-116` 只留下 ID、XY、按下标志，两个轴分别归一化到相同范围。descriptor 没有 Physical Max、Unit、Unit Exponent；还缺压力、面积/方向、扫描时间及功能报告。真实宽高比无法从输出恢复。根据所选接收协议补充这些数据；不要宣称单加某个字段就能解决原生识别。
4. **P2：验收观测不足。** `VFTrackpadRoot.cpp:93-95` 只有报告总数和是否存在触点，没有每帧指头数、峰值指头数或 ID 生命周期证据。`TrackpadBridge.swift:63` 固定输出 input_injected=false，只表示本次 status 调用不发送报告，容易被误读为整段历史未发送输入；宜改名为 status_call_submits_input=false。此前实测 submitted 从 2235 到 2681，errors=0，最后 active_contacts=false，不能推出五指完整送达。

## 在线证据及适用范围

- [Apple Developer Forums 768586](https://developer.apple.com/forums/thread/768586)：设备作者在 macOS 14.7 描述了通用 Touch Pad 报告进入 HID 栈却没有手势的现象；其公开描述符比我们的更完整。另有用户复现。页面没有给出 Apple DTS 的最终根因或正式支持结论，不能将用户报告包装为官方保证。
- [VoodooInput](https://github.com/acidanthera/VoodooInput)：项目提供 Magic Trackpad 2 软件模拟。其 [SimulatorDevice 源码](https://github.com/acidanthera/VoodooInput/blob/master/VoodooInput/VoodooInputSimulator/VoodooInputSimulatorDevice.cpp) 包含专用报告、时间戳、触点状态、面积/压力及设备行为。这支持研究完整协议模拟；它是内核扩展实现，并不证明可以原样移植到 M4 DriverKit。
- [VoodooPS2](https://github.com/acidanthera/VoodooPS2)：项目说明通过上述模拟使用 macOS 原生驱动处理手势。不是当前机器的验证证据。
- [macos-trackpad-companion](https://github.com/scottlamb/macos-trackpad-companion)：用户态自行识别手势，再发布 CGEvent；部分手势使用私有事件。其作者标注为原型。可作为另一路径的参考，不能称为 Apple 原生触点识别，也不能直接拿来连接我们的当前格式：它要求的 flags 顺序、物理单位、Scan Time 和按钮布局与我们不同。

## 本机系统证据

只读检查 `/System/Library/Extensions/AppleMultitouchDriver.kext/Contents/Info.plist`：

- AppleMultitouchHIDService personality：IOProviderClass=IOHIDInterface，usage=0x0D/0x04，Manufacturer=Apple，parser-type=1。
- MTUserDevice personality：IOProviderClass=IOHIDInterface，usage=0xFF60/0x07。
- AppleBluetoothMultitouch 另含专用设备和事件驱动匹配。

我们是 0x0D/0x05，现场未挂接上述服务。以上只是匹配与解析入口线索，不能通过改 Usage/Manufacturer 或 VID/PID 就断言完成协议。需要研究相应输入/feature 报告和生命周期；本轮未修改这些身份或系统文件。

## 已执行验证

- 现有五项 Python 编码/重同步测试通过。
- C++ ReportState 测试通过（-Wall -Wextra -Werror）。
- 这些测试证明部分编码和清理逻辑的内部一致性，未证明 Apple 手势协议兼容性。
- 未发现依据可以将 Tip/Confidence 位顺序直接判为现有格式的错误：现有编码与自己的 descriptor 顺序一致。
- 不将缺少物理单位、feature 或额外字段中的任意一项武断指定为已证实唯一根因。

## 建议实施顺序

1. 保留已经验证的 SSH/UserClient 传输；添加可观察的发送/接收指头数、ID 生命周期和点击状态，物理采样由用户操作，不使用 grab。
2. 用户目标仍为原生手势：优先研究本机 Apple 多点服务与真实 Magic Trackpad 的协议适配，借鉴 VoodooInput 协议行为；先离线验证报告，再在 M4 检查挂接。必须以真实系统手势/连续动画验收，不能以模拟快捷键代替。
3. 用户态手势识别加 CGEvent 是单独的替代路线，涉及私有手势事件与自定义识别行为；不默默切换用户目标。
4. 原型接入成功后再合入 Viewflow 的生产传输。当前只读审查没有提供足够依据承诺某个简单 descriptor 补丁即可成功。
