# Hyper-V 计时接口应用与登录后 4K 复测

用户批准后，已将运行 VM 的 CPU 参数改为 `host,hv-vpindex=on,hv-time=on,hv-synic=on,hv-stimer=on`，并完成 Windows 系统内重启。四个 QMP 属性回读均为 true，Windows CPUID vendor 为 `Microsoft Hv`，QPC 频率由 100 MHz 变为 10 MHz。同一等待探针复测中，1 ms 等待的中位数由约 4.70–5.47 ms 降至 1.39–1.52 ms。完整毛玻璃链路的两轮普通路径均通过帧标记检查，但延迟和桌面更新率有明显轮间差异；**尚未证明稳定 4K60、两帧内端到端显示。**

## 应用与启动核对

原服务文件 SHA-256 为 `7e7df26dec0ec0e166be016ac52e4509fa17ae7aa61c208edcb24196c7379592`，修改后为 `80838e88822094bfafa735e6a4c3fcb83d772143e5c5277d26a1bc58cabf06b2`。只改动 CPU 参数一行，保留 10 vCPU、24 GiB RAM、原设备和磁盘配置。原文件以 root 所有的 `/etc/systemd/system/windows-autoshop.service.viewflow-timer-20260909.bak` 备份。修改通过 systemd 校验，daemon-reload 已完成。[应用记录](method/application.json)、[当前文件与备份核对](method/host-current.json)。

首先经 QMP 请求 ACPI powerdown。QEMU 约一分钟后以 0 正常退出，未调用 quit、kill 或强制停止；随后用新服务参数启动。但是 Windows 报告的内核启动时间和登录会话仍是旧值，QPC 仍为 100 MHz，表明这一步恢复了保存的会话，不能当作完整内核重启。接着经 SSH 执行 `shutdown.exe /r /t 0`，未使用 `/f`。之后内核启动时间更新为 `2026-09-09T01:05:35.5000000-04:00`，QPC 为 10 MHz。[恢复会话时的读回](method/guest-after-boot.json)、[系统内重启后的读回](method/guest-after-restart.json)。

旧 QEMU PID 为 1579，现为 687589。服务 active 之外，已核对实时命令行、四个 QMP 属性及客户机 CPUID。[运行参数](method/runtime-after.json)、[修改前 QMP](method/qmp-before.json)、[修改后 QMP](method/qmp-after.json)。用户随后手动登录，已回读登录会话和相同内核启动时间。全部测量保持被动鼠标穿透、无输入注入；没有修改自动登录或保存凭据。

## 等待精度

与重启前相同 SHA-256 的探针、四种方法、八个交错区块共 2048 样本。区块中位由 4.70–5.47 ms 变为 1.39–1.52 ms，降低约 68%–72%；新 P95 为 1.52–1.64 ms。[前后统计](wait-before-after.json)、[复测](wait-comparison.json)。这是等待精度测量，不能直接折算为完整流收益。

## 完整 4K、sigma=12 毛玻璃

实际 HDMI 和源内容均为 3840×2400、约 60 Hz，atlas 为 3968×2432。每轮源运行 55 秒、桌面观察 30 秒。捕获→桌面上界仅处理跨机时钟不确定度，终点为 DXGI `LastPresentTime`；不是光子时间，也未证明是该帧第一次显示。不同标记数除以完整 30 秒，不等同于物理显示 FPS。

| 轮次 | 直接绘制 | 帧标记无效 / 采集 | 不同标记/秒 | 捕获→桌面中位 / P95 ms | 绘制前→桌面中位 / P95 ms |
|---|---|---:|---:|---:|---:|
| hyperv-v2-off-a1 | 关 | 0 / 1718 | 44.77 | 27.30 / 28.37 | 28.37 / 44.66 |
| hyperv-v2-on-b1 | 开 | 270 / 1683 | 47.10 | 28.58 / 29.26 | 58.21 / 59.39 |
| hyperv-v2-on-b2 | 开 | 0 / 1680 | 55.73 | 29.36 / 30.12 | 44.95 / 46.02 |
| hyperv-v2-off-a2 | 关 | 0 / 1736 | 57.87 | 30.79 / 31.53 | 55.23 / 56.10 |

第一轮普通路径的捕获计时仅包含 946 / 1343 个不同标记：其余 397 个标记对应重复捕获，无法唯一配帧，未参与该段统计。最后一轮普通路径为 1736 / 1736 个唯一配对，捕获→桌面最大上界 34.19 ms；从绘制前计时中位 55.23 ms。前后普通路径使用同一设置，不能把一次低延迟与另一次高更新率拼成可实现的组合。

直接绘制第一轮 270 / 1683 个观测标记无效，第二轮虽无无效标记，但有约 813 ms 的捕获→桌面长尾。因此整个候选未通过采用标准，表中候选延迟只描述有效子集，**不作为被接受的优化收益**；默认继续关闭直接绘制。[逐帧统计](comparison.json)。

## 被动窗口可见性修复与保真

重启后首次完整试验 `hyperv-v1-off-a1` 的 1737 个采集全无有效标记，已保存在 `failed-runs/`，不用于性能结论。诊断确认初始被动测试窗口未出现在桌面采集中。三个窗口风格的颜色探针在创建时加 `WS_EX_TOPMOST` 后，60 个颜色样本全部精确匹配、命中自有窗口次数为零、前台保持不变。冻结的 111 个原生源文件与上轮仅有 `diagnostic_window.h` 的这一差异；它只作用于显式禁用输入的诊断模式。正常输入窗口没有因此成为置顶窗口。

新二进制的四阶段背景条纹对照均为 `verified=1 mismatched_channels=0 foreground_unchanged=1`，背景切换响应 80，模糊差异通道 110592，鼠标命中自有窗口为零。[像素检查](method/host-backdrop-result.log)、[样式探针](method/style-probe.log)、[源差异](method/change-ledger.json)。完整流保持原 sigma=12 背景效果；测试没有以去掉毛玻璃换取速度。

本次前后包含 VM 重启、Hyper-V 参数、ESRV 负载变化和诊断窗口可见性修复，不能把全部变化归因于计时参数。等待探针期间 ESRV 存在；完整四轮开始前及结束时均为空。本测试未停止 ESRV。四轮源/接收/观察器身份已记录，原观察器与 runner 沿用前次二进制，原生 presenter 按上述单一头文件改动重新构建。

## 校验、清理与回滚

111 个远端源文件与冻结源哈希一致。四轮控制器结束、测试进程/任务/端口清空，临时 Linux 输出移除，原显示几何及 VDD 配置保持一致。首轮退出后的第一张快照含三个正在退出的自有进程；下一轮启动前快照及最终审计确认已全部退出，原始快照未被改写。

`python method/verify-application.py --live` 只读核对 VM 参数应用及备份；`python method/verify-archive.py` 从压缩日志重算四轮数据，并核对像素测试、等待样本、源身份与清理记录。此前[等待基线](../wait-resolution-probe/README.md)及[重启前直接绘制对照](../direct-composition-output/README.md)作为历史保留。

要回滚计时参数，可恢复已核对的服务备份，再正常关闭/启动 VM 并执行 Windows 系统内重启，避免仅恢复保存的内核状态；本轮没有执行回滚。
