# Linux → Windows 多指触控板

2026-09-07：接入 Magic Trackpad 的多触点转发，覆盖跨屏控制 Windows
桌面和 Linux 上的 Windows 代理窗口。实现双指滚动、捏合缩放及三／四指
滑动的原生触控板输入；具体系统手势动作由 Windows 的触控板设置决定。

## 输入路径

Linux 读取 evdev 的 type-B 多触点槽位，在每个 `SYN_REPORT` 边界发送完整
触点快照。坐标根据设备轴的 resolution 换算成 1/100 mm，保留 tracking ID，
不会把多指移动先转换成快捷键。当前选取一个主触控板，最多同时发送五指。

桌面路径为 Hyprland 输入插件 → native tag 37 → 当前输入租约的有序 QUIC
控制流 → Windows 输入后端。触点、按钮和键盘保持发送顺序；触点帧不要求
额外的时钟同步或逐帧网络回执。

代理窗口路径由 Linux Wayland presenter 读取同一类触点快照，使用现有
reverse 输入流的 contact/commit 记录发送，Windows 按窗口身份组装后注入。
离开代理、切换目标、交还控制和断开连接时释放旧目标触点。

Windows 使用 `CreateSyntheticPointerDevice2(PT_TOUCHPAD)` 和
`InjectSyntheticPointerInput`。设备使用 physical-size 和 gesture-only 选项；
普通鼠标移动、点击仍由现有路由处理，Linux 同一触控板的派生滚轮不会重复
发送。该模式处理手势移动；三／四指轻点、按压目前仍沿用 Linux 的按钮映射，
尚未转换为 Windows 的 `InjectTouchpadAction` 全局动作。

原生 API 的设备参数、五触点上限及 gesture-only 行为参见
[Microsoft 设备参数](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-synthetic_device_creation_params)、
[创建选项](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ne-winuser-synthetic_device_creation_options)和
[触控板注入示例](https://learn.microsoft.com/en-us/windows/win32/input-precisiontouchpad/precision-touchpad-guide)。
接收机 Windows 11 24H2，build 26100.9168，已只读确认相关 API 导出存在。

## Linux 本地手势归属

控制在 Windows 桌面或指针位于 Windows 代理窗口时，插件在 Hyprland 的
gesture 入口拦住本地 swipe/pinch，因此本地三指及以上手势不会同时执行。
这覆盖 Hyprland 的工作区手势以及通过其 trackpad gesture manager 注册的
本机 hymission 手势。判断使用实际指针归属，不要求代理获得键盘焦点。

远程开始的手势返回 Linux 后，其剩余 update/end 仍被吞掉，防止孤立事件
触发本地动作；下一组本地手势正常工作。本地开始后进入远端的手势会先向
本地手势管理器发送取消结束，再交给远端归属。相关处理不关闭串流。

evdev 不使用 `EVIOCGRAB`，不会抢占整台设备。`SYN_DROPPED` 先释放远端
触点，再用 `EVIOCGMTSLOTS` 重同步；超过五指发送空快照，恢复到支持的
触点数量后继续。注入失败保留尚未成功释放的触点状态，以便后续清理重试。

## 独立提交验证

从暂存区导出的独立源码快照：Linux 平台 56 项通过；主程序
`native-gpu-nvenc` 库 585 项通过、8 项环境相关测试跳过；Hyprland
插件 10 项及 Linux reverse 2 项通过。Windows 平台后端交叉编译通过。

## 集成工作区的验证和部署

以下结果来自包含独立 Windows 输入服务等并行改动的集成工作区。
服务路径需配套 VFI2 触点消息支持；服务实现不属于本次触控板核心提交。

- Linux 平台测试：67 项通过；Windows 平台测试：52 项通过。
- Linux native-gpu 库：589 项通过，9 项已有环境相关测试跳过。
- 五指快照和空快照通过真实 QUIC 的模拟接收端验证；未执行物理输入。
- Hyprland 插件：10 项通过，含槽位复用、掉包、五指上限及跨屏手势归属。
- reverse 原生测试：Linux 2 项、Windows 4 项通过。
- 两端 release 程序、Windows 输入服务、Linux 插件及 reverse 程序构建成功。

已更新当前 Linux 用户服务和 Windows `ViewflowMain-Active`／`ViewflowInput`。
运行时确认双端连接与 reverse bridge ready；插件显示 `raw_touchpad=1`，
Hyprland 无配置错误。Linux 备份在 `build/touchpad-backup-20260907`，Windows
备份在 `C:\Users\wilf\Viewflow\desktop-test\backup-touchpad-20260907`。

只读诊断：`hyprctl repl 'return hl.plugin.viewflow.capture_status()'`。
`touchpad_frames` 统计桌面路由发送的快照；`suppressed_gesture_events` 统计
被拦截的本地 swipe/pinch 事件，两者不记录触点位置。

实际缩放、三／四指滑动、Windows 自定义动作以及返回 Linux 后恢复手势，
仍需用户手动验收。此次没有自动注入鼠标、键盘、触点或执行焦点测试。
