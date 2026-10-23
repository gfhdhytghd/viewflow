# 采集提交相位跟随：第二版原型暂不采用

2026-09-08，完整毛玻璃、H.264、独立嵌套 Hyprland，A/B/B/A 四轮。**候选降低了绘制到捕获的中位等待，但没有稳定的整体延迟收益，P95 比两轮基线更高，未接入生产。** 实验只存在于本目录的独立源码和临时构建；原桌面的插件和产品源码未替换。

| 轮次 | native commit/s | DD marker/s | 绘制→捕获中位 ms | P95 ms | 绘制→所见桌面上界中位 ms | P95 ms | 捕获→所见桌面上界中位 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| phase-grid-a1 | 58.405 | 36.371 | 4.993 | 7.732 | 44.882 | 50.926 | 38.471 |
| phase-follow-b1 | 58.519 | 44.001 | 0.820 | 14.701 | 44.901 | 57.669 | 40.756 |
| phase-follow-b2 | 58.521 | 36.843 | 0.657 | 14.121 | 40.034 | 57.124 | 38.473 |
| phase-grid-a2 | 58.192 | 38.171 | 1.588 | 5.204 | 41.174 | 47.609 | 38.794 |

阶段统计要求唯一 capture 身份；完整绘制→桌面统计直接用 fixture 帧号，不需要猜测重复捕获属于哪一帧。全部原始记录、排除计数、配对、时钟和分阶段数据见[完整比较](comparison.json)。没有删除长尾或只展示中位数改善。B1/B2 的完整 P95 分别为 57.67 / 57.12 ms，而 A1/A2 为 50.93 / 47.61 ms，不能据此采用新默认值。

DD LastPresentTime 是含 marker 的桌面样本时间，可能不是首次显示，更不是光子时间；DD marker/s 与 native commit/s 都不能作为已经验证的物理显示 FPS。两端时钟不确定度保留在上界中。4K60 和完整两帧内显示仍未验证。不同阶段的独立中位数不能相加重建总跨度。

## 相对上一版的改动

[上一版提交触发原型](../capture-commit-cadence/README.md)在每次尝试后把下一次准入时间设置为 now + period，会把 timer 的迟到积累进调度相位；无主 surface 提交时又额外等待 1 ms，静态尝试频率也降低。

本版保留共同 cohort 与原 renderer/HCGR ownership，名义截止时间按原时间表增加一个周期。收到内容提交时可最多提前 min(1 ms, period/8)，实际尝试时对相位做最多该范围 1/8 的修正；首次提交、超过两周期未提交后的恢复可重新建立相位。静态 fallback 仍每个名义周期执行，不让固定 grace 或 timer 迟到逐次积累；长停顿只安排未来一次，不追赶旧槽。调度可以出现少量靠近的 startup/resume 尝试，不声称所有相邻尝试都严格相隔一个 period。这些是性能调度，不是连接或安全超时。

仍只监听 main wl_surface，使用周期 fallback 覆盖装饰、popup 和没有主 surface 提交的变化。没有增加焦点、输入或帧 freshness 准入。失败处理及未释放帧不能复用的规则沿用原 renderer。候选的 P95 采集前等待仍约 14 ms，表明这版并未消除全部错过提交或后续处理等待；仅凭本轮端点不能把每个尾部样本归因于某个 timer 分支。

## 验证与环境

Release 构建成功，8 项 CTest 通过。策略测试包含 1/30/60/1000 fps、1,000 次迟到 timer 的静态相位保持、恢复、重复通知合并、长停顿、整数饱和，以及 600 次带 +/-0.35 ms 相位差的提交。首次编译因测试中混用 auto 整数类型失败，修正后才开始 GPU 运行；失败及修正日志保留。

另外将两轮 fixture swap-return 记录当作假定的提交到达时间，设置 25 us timer lateness，做纯调度模型回放。新策略模型的中位年龄约 0.025 ms，但 P95 仍约 13.7–14.1 ms。这些不是 Wayland commit 实录或 GPU 完成时间，不能作为实际性能收益；[模型和假设](method/replay.json)明确保留。

真实 GPU smoke 共 169 帧：验证 320-byte 消息、HCGF/HCGI、两枚 FD、native fence、地址/PID/几何、HCGR sequence/epoch；持有 A 时 B 继续 12 帧，停止 A 后 B 再继续 12 帧，同 ID 在空 cohort 删除后能重新创建，原 grid API 也能导出实际帧。本轮 smoke 未做像素读回；其后真实远程观测的有效 marker 验证属于另外一层证据。[smoke](nested/smoke.json)。

SO 为 `21cf0fbe8adc800c903dc847f18f9d86e0537d5245998f4e4993d93978b8dcb1`，只加载进独立嵌套 Hyprland 0.56.2。bwrap 独立 /dev，只暴露 render/NVIDIA 节点及私有 IPC 目录，不访问物理 input/seat/DRM 节点；使用 parent Wayland 分配器。内层 WAYLAND-1 为 3840×2400@60、scale 2，fixture 1920×1200，捕获 3848×2408、atlas 3968×2432。新 fixture 保留半透明边缘和全画面 GPU 动画，源码与[前置完整链路复测](../full-glass-retest/README.md)一致。

Windows 是相同 Intel GPU 和 6144×3456@60 虚拟输出、H.264、完整默认 sigma=12 毛玻璃路径、相同 receiver/native/observer/runner 二进制，逐轮哈希记录在 state.json。每轮源端 55 秒、DD 30 秒、异步 3-slot ring、timer1；关闭 GPU query 与 socket trace 等重诊断，保留帧编号、clock 和 source/wire timings。两轮候选、两轮基线始终使用同一测试 SO，仅由私有 hyprctl shim 选择 grid 或 commit API。

## 退出、清理与限制

四轮 stream 驱动均正常完成，计划 source exit=124、receiver peer close exit=1、watchdog=0，observer exit=0、ring abandoned=0；逐轮均确认 Windows 自有进程、任务和端口已清理。没有修改 ESRV 优先级、停止服务或注入鼠标键盘/焦点操作。

外层嵌套驱动最后的 monitor 列表相等断言失败，不能记为驱动 exit=0：原有隐藏侧栏窗口被分配到了自有 HEADLESS-16，保护分支因有剩余窗口而暂留输出。嵌套进程当时已退出，四轮数据均已收取。随后确认唯一剩余窗口属于 special:sidechat_hidden，再正常移除自有输出；合成器迁移窗口，读回同一地址/PID仍存在且焦点未变。[后续清理记录](nested/output-cleanup.json)。原先就存在的 HEADLESS-13 未删除，未强行恢复用户活动中改变的状态。

原插件 `f7c23f70...1c9aea`、Linux sender `ddbc806b...77aae2` 及生产 renderer/main 源码身份见[生产与二进制记录](method/binary-and-production-identity.json)。原桌面的插件列表保持相同。本轮没有产品改动可部署，旧采集默认值保持原状。

纯分析复算：把各 runs 子目录的日志解压到临时根同名子目录，并复制 state.json；运行 `python3 method/analyze-phase.py <临时根> phase-grid-a1 phase-follow-b1 phase-follow-b2 phase-grid-a2`。私钥和证书不进入本目录。构建/桌面控制脚本里的绝对路径属于当时环境，不能未经新检查直接复用。
