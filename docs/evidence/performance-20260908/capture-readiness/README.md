# 捕获帧到达唤醒：减少源端轮询等待

2026-09-08，Linux GPU atlas → Windows H.264 窗口路径。

**保留这项优化并默认启用。四轮对照中，捕获到套接字读取的中位间隔从 1.28–1.32 ms 降为 0.21–0.22 ms，P95 从 2.21–2.39 ms 降为 0.37–0.39 ms。capture→desktop 上界中位数从 48.62–50.19 ms 降为 47.48–47.56 ms，但没有证明 4K60 或两帧内显示。**

这是源端实际处理路径的改动。它缩短的是已有捕获完成后的等待；原生提交率的范围仍重叠，提交后到桌面记录的中位间隔仍约 34 ms。不能据此声称持续 60 fps 或端到端延迟已经达标。

## 改动与控制

原来 `AtlasDevicePoll::Waiting` 后只等待一次 Tokio 1 ms timer。现在同时等候 capture socket 可读，帧到达即可继续。`VIEWFLOW_CAPTURE_EVENTS=0` 保留原来的定时轮询路径，用于同一二进制内的对照；未设置变量时开启帧到达唤醒。

每个 receiver 延迟创建一个带 CLOEXEC 的 socket duplicate 并注册 READABLE，随 receiver 在采集器与编码批次之间移动，释放 receiver 时撤销注册并关闭描述符。原有 `recvmsg(MSG_DONTWAIT)` 仍负责读取、接收 FD、鉴别与解析；只有真实 EAGAIN 才清除缓存 readiness。已持有帧的 slot 不参与等待，也不会重复接收、提前 HCGR 或改写捕获时间。取消等待不消费数据、不关闭 producer、不派生后台 reader。注册或 readiness 故障只对该 receiver 回退定时轮询，保留会话；这个异常回退分支经代码审查，真实四轮未触发，未注入 FD 耗尽。

原 1 ms timer 保留，用于输入、enrollment、反馈等周期处理；没有增加等待上限或会话退出条件。其实际周期取决于 Tokio 调度，不能把配置的 1 ms 当作精确观测值。空池或部分持有帧的集合仍会通过定时回退继续维护。

[Tokio 1.53.1 AsyncFd 文档](https://docs.rs/tokio/1.53.1/tokio/io/unix/struct.AsyncFd.html)要求非阻塞 FD、稳定 FD 身份，并在实际 WouldBlock 时清除 readiness；实现据此保留单独注册的 OwnedFd 和原始 recvmsg 错误。新增 net feature 为直接使用该 API 声明依赖。

## 实测环境

A1、B1、B2、A2 顺序，四轮均为同一个新 Linux Release 二进制，A 设置 events=0、B 设置 events=1。均使用[上一轮 minimal 诊断](../trace-controls/README.md)：native GPU queries=0、两端 socket trace=0、source GPU 分段及 alpha-copy profile=0；QPC、帧身份、原始时钟交换、source/wire timing 与 GPU fixture marker 仍保留。它不是完全无诊断的生产测量。

源自有 headless output 3840×2400@60，实际含边框捕获 3848×2408、atlas 3968×2432；capture_provider=viewflow、fps=60，未更改 capture plugin。Windows Intel GPU 输出 6144×3456@60、1:1 自有 NOACTIVATE 窗口，H.264，native-trace-controls-build 与原 Rust receiver 相同，DD observer、异步读取 ring 和 1 ms observer timer 均相同。没有 ETW/WPR、输入注入或焦点切换。源每轮计划 25 秒、DD 观察 20 秒；整轮驱动还包含配置、启动、传回日志与清理。

这些证据覆盖当前 Linux→Windows 的约 4K 内容路径，不等同于物理 3840×2160 显示器验收，也不证明 macOS 或 Windows 原生采集路径获得了同样收益。

## 采集等待与桌面结果

| 轮次 | capture→recv 中位 ms | P95 ms | native commit/s | DD marker/s | capture→DD 上界中位 ms | P95 ms | 最大 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| 4k-capture-ready0-minimal-a1 | 1.316 | 2.387 | 57.963 | 39.580 | 50.191 | 68.517 | 110.974 |
| 4k-capture-ready1-minimal-b1 | 0.219 | 0.389 | 59.091 | 42.437 | 47.556 | 63.963 | 121.000 |
| 4k-capture-ready1-minimal-b2 | 0.211 | 0.372 | 58.491 | 41.168 | 47.476 | 64.137 | 105.702 |
| 4k-capture-ready0-minimal-a2 | 1.280 | 2.205 | 58.703 | 41.848 | 48.625 | 64.303 | 131.776 |

capture→recv 包括 producer 完成捕获后的导出/发送与本地读取，不是独立测得的纯 sleep 耗时。collector→encode 四轮中位数均约 0.032–0.033 ms。B 两轮把前一项降低约 1.1 ms，结果可重复；native commit/s 的 A/B 区间仍重叠，不报告稳定 FPS 提升。四轮样本量有限，没有统计显著性结论。

| 轮次 | capture→mutation 上界中位 ms | mutation→DD 中位 ms | fixture pre-draw→capture 中位 ms | fixture pre-draw→DD 上界中位 ms |
|---|---:|---:|---:|---:|
| 4k-capture-ready0-minimal-a1 | 14.755 | 33.995 | 4.716 | 54.832 |
| 4k-capture-ready1-minimal-b1 | 12.834 | 34.045 | 3.149 | 50.689 |
| 4k-capture-ready1-minimal-b2 | 12.719 | 34.065 | 16.327 | 63.791 |
| 4k-capture-ready0-minimal-a2 | 13.872 | 34.121 | 10.329 | 59.017 |

fixture 的绘制与 capture timer 相位在四轮间不同，pre-draw→capture 中位数约 3.15–16.33 ms。B2 的完整 pre-draw→DD 中位数反而比 A2 高，因此不能只展示 capture 后的改善并声称整个交互端到端已经变快。上表列出原始总跨度，不能用独立阶段中位数相加重建它；也没有把相位差全部归因于单个调度器。

DD LastPresentTime 属于含目标 marker 的桌面样本，尚不能证明每帧首次可见或光子时间。native commit/s 也不是物理 FPS。[原始端点与方法](../../performance-20260907/README.md)。以 fixture pre-draw 为起点，四轮所有观测样本的延迟下界都超过两次 60 Hz 刷新；不存在可以据此证明达标的样本。

## 唤醒、恢复及样本完整性

| 轮次 | 等待次数 | 帧到达唤醒 | 定时回退唤醒 | expired_clean | enqueued |
|---|---:|---:|---:|---:|---:|
| 4k-capture-ready0-minimal-a1 | 6008 | 0 | 6008 | 5 | 1377 |
| 4k-capture-ready1-minimal-b1 | 7196 | 1172 | 6024 | 0 | 1434 |
| 4k-capture-ready1-minimal-b2 | 7193 | 1172 | 6021 | 6 | 1420 |
| 4k-capture-ready0-minimal-a2 | 6583 | 0 | 6583 | 2 | 1425 |

这些是整轮计数，不是 CPU 占用或无丢帧证明。B 每轮额外约 1172 次帧唤醒，定时回退仍在；不是忙等循环。独立 CPU 占用未在本轮测量。expired_clean 仍可发生，原有局部恢复继续运行，不能宣称消除了全部超时。

唯一捕获身份配对 775/831/809/829；歧义 marker 分别 0/9/7/0，仅从需要唯一捕获帧的阶段配对中排除，原始日志保留。pre-draw 总跨度直接使用 fixture marker，对应样本数 775/840/816/829；它不需要猜测重复 marker 属于哪次捕获。全部四时间戳交换复算有效（768/776/776/776），所用映射有效期覆盖桌面端点；无 missing capture marker。marker、正 LastPresentTime、readback sequence 严格递增，ring abandoned=0、pending_peak=2，capture 上界及 mutation/commit→DD 无负数。四轮没有 malformed encoder/wire 记录；GPU encode 分段统计为空是 minimal 模式的预期结果。

## 验证和最终状态

Linux native-gpu-nvenc：13 项 socket 测试、5 项 atlas 测试通过；新增三项测试覆盖 64 次到达/重置且不提前 HCGR、等待取消后断开、双源部分收齐及四次 ownership restore。未启用 native GPU feature 的 socket 测试另有 9 项通过。Release 构建成功。Windows 本轮使用之前已构建的相同 native/receiver，未改动或重新编译 Windows 原生采集代码；未做新的鼠标键盘验收。

实测冻结的 Linux EXE 为 `d6f4760fe52fee45e85738ede6070aafd67b2f406f6d543b07a34cde59281a30`。四轮结束后给仅测试用的多源测试补充 `cfg(native-gpu-nvenc)`，以支持非 GPU feature 的测试构建；它在 cfg(test) 内，不修改 Release 控制逻辑。随后测试和 Release 重建通过，当前 Linux EXE 为 `ddbc806b581037ee64abf084a8c8c77ec14c5f437e079edc44bad5b92277aae2`。这两个构建哈希分开保存，不声称四轮测量来自后一个哈希；完整 tested/source 快照能核对唯一的后续测试属性差异。

保留源端事件唤醒代码和当前 Linux Release。原 Linux 二进制备份哈希为 `6688c92299475f3ad86b7e50dad27bc3853fd76df3ed56eb8d03c31185233d7e`。Windows 默认 native 仍为 `81CB49DD9269A50B7FB6124539F8034EDB094BD54700707E2BDF0F2E1442E0B4`，Rust receiver 仍为 `A39CB1F4BD003EC3EE1237AF05D9915316E86119DC21FBE1C9F626CE61B3C30A`，两个原 PDB 未变。试验使用的独立 native `DF6EB3FAD88B8DADEC5EC0C0427DE395428E3731D36DF0658AA8C071324A6F2B` 和 DD observer `D57C7377AEFCD603D01626948805949EB78BB9B7C7C8C52CB0604A471841AAEA` 未变。

每轮前后读回 ESRV 进程和两条特定线程为 Normal/base8、无其他 TimeCritical，不声称连续采样。独立 10 分钟 SYSTEM 恢复任务先于控制创建；finally 恢复原 High/TimeCritical 并删除任务。最终现场读取 Running/Auto、PID 2344、High、两条 TimeCritical，实验进程/任务均为 0；服务未停止、重启或禁用。两端临时配置逐字节恢复，源自有 headless output 已移除，前后 monitor 与焦点读取一致。

四轮驱动 exit=0，源按计划 source_exit=124，receiver_exit=1 对应 peer 关闭且 watchdog=0，DD exit=0、自有 fixture 已终止；逐轮孤立进程清理为 0。[最终状态](method/capture-ready-final-state.json)、[控制记录](method/capture-ready-state.json)、[完整比较](comparison.json)。

每轮 source/receiver/desktop/producer/runner/cleanup/driver 均以 gzip 保存，另有 fixture、唯一配对和摘要。method 保存构建、测试、运行、分析、恢复及源码哈希；source-before、source-tested、source 保留改动前、实测版、最终版。没有把大型二进制写入仓库，保留实际 SHA256 与本机冻结路径。脚本绝对路径、进程及线程身份对应当时现场，重新运行状态修改前必须重新核对。

纯分析：将 source/receiver/desktop 解压为 `/tmp/viewflow-integrated-pair/{kind}-{label}.log`，producer 解压为 `/tmp/viewflow-frame-fixture-first/{label}-source.log`；把 source/tools 两个依赖放在工作目录 tools，运行 `method/summarize-capture-ready.py` 并依次传入上表四个 label。sha256.json 覆盖本目录全部文件，清单自身除外。

后续仍需处理捕获前的相位等待与 Windows 提交后到桌面的约 34 ms 跨度。此次保留的收益约在 1 ms 量级，完整 4K60、两帧内显示目标仍未达成。
