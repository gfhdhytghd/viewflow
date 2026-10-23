# 接收队列环境复查与观察器相邻时段检查

2026-09-09。当前实际发送路线为 Linux `172.16.105.62` 经 br0 到 Windows `172.16.105.70`。QEMU PID 687589 使用 tap-windows、模拟 e1000、10 个 vCPU；已应用的 Hyper-V 计时选项仍在启动参数中。Windows 当前网卡为 Intel PRO/1000 MT #2，驱动 8.4.13.0 / NDIS 6.0，自适应中断合并开启、接收缓冲 256，RSS / RSC 查询未返回支持项。这些配置是排查条件，**不能单凭配置证明慢回执的原因**。

这是对 [早期接收路径取证](../ndis-receive-scheduling/README.md) 和 [长尾环境记录](../longtail-diagnostics/README.md) 的实时复查，没有改网卡、注册表、优先级或 QEMU 配置。已安装 QEMU 的 `-device e1000,help` 没有暴露运行时中断合并开关；[QEMU 当前 e1000 源码](https://gitlab.com/qemu-project/qemu/-/blob/master/hw/net/e1000.c) 的设备属性表也不支持先前猜测的 mitigation 属性，因此没有尝试未验证的 QOM 写入。

另从正式组合的已有原始记录，比较观察期末尾十秒（末次 DD 时间前 11 至 1 秒）与后续十秒（末次 DD 时间后 2 至 12 秒）的原生提交次数。窗口长度均固定十秒，排除开始和关闭附近的边缘；基准记录有足够后续覆盖。

| 轮次 | 观察期内提交/s | 后续提交/s |
|---|---:|---:|
| 帧率 A1 | 60.0 | 60.0 |
| 帧率 A2 | 60.0 | 60.0 |
| 延迟 B1 | 59.4 | 59.5 |
| 延迟 B2 | 59.1 | 60.0 |

这组相邻样本没有显示原生提交的明显整体退步，但并非随机或交叉对照，不能证明观察器无开销。后续时段没有桌面标记观测，不能由其原生提交率宣称实际显示 60 FPS。观察器源码本来就只读标记中心扫描线，并使用异步非阻塞 Map；日志中约 8 ms 的 copy-map 跨度包含排队和下次轮询，不是整张 4K 图像的 CPU 复制耗时。

当前改为检验仅在 Viewflow 测试线程上注册 MMCSS Playback 的 [进程内调度对照](../mmcss-canonical/README.md)。接口按 [Microsoft 调用线程注册约定](https://learn.microsoft.com/en-us/windows/win32/api/avrt/nf-avrt-avsetmmthreadcharacteristicsw) 使用，线程退出时释放；不修改上述机器配置。该实验结果与是否采用需另行测量。

`analyze-adjacent.py` 从已归档日志复算四对窗口；原环境输出和源码检查保存于本目录。所有统计均为诊断线索，不是 4K60／两帧内首次显示证明。
