# Windows 等待精度与虚拟机时钟检查

更新：用户随后批准并已完成[计时补丁应用与 Windows 系统内重启](../hyperv-timer-enabled/README.md)。以下数据和“尚未应用”描述保留当时状态，收益需以后续复测为准。

请求 1 ms 的等待在测试进程中仍约 4.7 ms。四种方法交错八组、每组 256 次，共 2048 次测量，**强制尊重精度请求没有改善，高精度 waitable timer 也没有改善**。因此没有据此改动产品或观察器，也没有把此微基准当作 4K 性能结果。

| 组 | 等待对象 | 计时器精度策略 | 中位 (μs) | P95 (μs) |
|---|---|---|---:|---:|
| 0 | 未触发 event，超时 1 ms | 原策略 | 4702.61 | 5170.77 |
| 1 | 同上 | 显式尊重精度请求 | 4709.05 | 5087.23 |
| 2 | 高精度 timer，1 ms 相对到期 | 原策略 | 5472.56 | 5829.85 |
| 3 | 同上 | 显式尊重精度请求 | 5470.99 | 5805.19 |
| 4 | 同上 | 显式尊重精度请求 | 5425.15 | 5842.09 |
| 5 | 高精度 timer，1 ms 相对到期 | 原策略 | 5471.83 | 5832.76 |
| 6 | 未触发 event，超时 1 ms | 显式尊重精度请求 | 4722.78 | 5087.42 |
| 7 | 同上 | 原策略 | 4722.67 | 5129.38 |

所有组保持 `timeBeginPeriod(1)`，两种等待都使用同一进程、线程和 QPC。高精度组的计时范围包含设置单次 timer 的调用和等待；不是单独的调度器唤醒时延。策略仅修改测试进程的 `IGNORE_TIMER_RESOLUTION` 位，逐组回读核对，结束时恢复原 control/state=0/0。无窗口、无输入注入。这里的空闲进程测量不能代替满负载视频流，也不能说明接收端所有等待都会多出同样时长。

[Microsoft 策略说明](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation)指出 Windows 可忽略不可见进程的精度请求，也提供显式关闭此行为的方法；本次回读证明设置成功，但实测不支持它是当前差异的原因。[高精度 timer API](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw)的成功同样不保证这台机器的实际等待时间。

## 新发现：当前 VM 未暴露 Hyper-V 计时接口

运行中的 QEMU PID 1579 使用 `-cpu host`，未配置 `hv-*` 参数；Windows 客户机的 CPUID vendor 为 `KVMKVMKVM`，最大 hypervisor leaf 为 `0x40000001`。这两项证据一致，没有把仅有的启动文件当成运行时事实。[当前参数](method/live-qemu-selected-config.json)、[客户机 CPUID](method/guest-hypervisor.json)。

[QEMU 官方文档](https://www.qemu.org/docs/master/system/i386/hyperv.html)说明 Hyper-V enlightenments 默认关闭，`hv-time` 提供优化时钟，`hv-stimer` 提供合成计时器；部分 Windows 在缺少后者时会更多依赖 HPET/RTC。**这提示一个待检验的 VM 层候选，尚未证明 Windows 当前选择了哪种计时设备，更未证明开启后就能达到 4K60 或两帧内。**

宿主 `/proc` 的一次约 1 秒请求间隔快照中，10 个 vCPU 各自 runnable 等待累计约 0.23–1.49 ms，未显示持续的宿主 CPU 排队；它不是 Windows 微基准的同步采样，不能排除视频负载期间的抢占，也不能据此断言计时设备就是根因。[调度快照](method/qemu-scheduling-snapshot.json)。

## 已准备、尚未应用的改动

[单行补丁](method/windows-autoshop-timer.patch)将 `/etc/systemd/system/windows-autoshop.service` 的 CPU 参数改为：

```text
host,hv-vpindex=on,hv-time=on,hv-synic=on,hv-stimer=on
```

这包含合成计时器所需的三个依赖。独立 QEMU 使用该参数创建一颗暂停的 vCPU，不连接客户机磁盘或设备；QMP 回读四个属性均为 true，实例保持 paused/prelaunch，随后退出。该检查证明当前 QEMU/KVM 接受配置，不证明 Windows 启动兼容性或性能收益。[验证结果](method/paused-qemu-validation.json)。补丁 dry-run 通过，原服务文件的哈希保存在[提案](method/proposed-cpu-change.json)，当前文件未改变。

验证实际收益需要在获准的中断窗口内应用补丁并重启 VM，随后重跑相同等待测量和完整被动 4K 对照；若无收益可恢复 `-cpu host` 后重启。该服务已有关机 helper 和 90 秒停止超时，但未调用它。当前账户无法直接访问 root 所有的 QMP socket，非交互 sudo 也要求密码；未通过 QMP 停机或修改运行 VM。[访问结果](method/live-qmp-access.json)。需要管理员完成受保护的服务修改和重启，不能将用户同意本身当成已取得系统权限。

## 构建与复算

MSVC 构建成功，2048 次等待的返回值全部符合所用 API，策略恢复成功，测试任务及进程清理完成，ESRV 进程和优先级未改变。首次构建脚本含 Python 反斜杠转义错误，已改为 raw string 后重建；首次失败日志单独保留，失败时尚未运行探针。

`python method/analyze.py` 从原始 QPC 记录复算表格；`python method/verify-archive.py` 离线检查统计、二进制身份、暂停实例结果、未应用补丁及文件哈希。源码、原始记录、构建与运行方法均保存在 `method/`，没有用合成数据补足验证。
