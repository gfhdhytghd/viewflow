# Viewflow：校准、火焰图与 GPU 排队归因

最新对照：[独立 alpha 遮罩，完整毛玻璃保留](stable-alpha-mask/README.md)。图像正/负例完成；两轮性能没有稳定收益，未接入产品。[完整 4K 链路复测](full-glass-retest/README.md)已完成两轮：捕获→所见桌面上界中位 38.98 / 38.61 ms，完整绘制→桌面上界中位 41.49 / 53.46 ms，仍未达标。

最新毛玻璃研究：[完整保留背景的 Windows 模糊 GPU 实测](full-glass-kernel/README.md)。相同 sigma 下 SPEED 仅减少约 0.30 ms 且产生画面差异，未采用；[此前二值背景静音已撤回](binary-alpha-backdrop/README.md)。4K60 与两帧内完整显示仍未验证。

2026-09-08 · 面向 Viewflow 开发决策 · Linux → Windows 原生接收端

**当前最有证据支持的优化方向是减少透明度数据的重复复制、展开与比较。此前围绕提交 API 的尝试优先级应降低。尚未证明 4K 60 fps、延迟不超过两帧；本轮完成的是定位与测量基础，不是性能达标。**

后续进展：已完成[源端 alpha 输出所有权优化](alpha-output-ownership/README.md)与[Windows alpha 复用](native-alpha-reuse/README.md)，并新增[长停顿分段诊断](longtail-diagnostics/README.md)、[显存 scratch 复用](scratch-tile-borrow/README.md)、[实际 socket 边界证据](socket-boundary/README.md)、[源端 alpha 快照复用](source-alpha-snapshots/README.md)、[GPU 精确 alpha 比较](gpu-alpha-diff/README.md)、[接收调用、唤醒与内核网络追踪](deep-socket/README.md)及[Windows 网卡入口与 UDP 交付对照](ndis-ingress/README.md)、[并行普通 UDP 复现](active-udp-controls/README.md)、[已撤回的发送平滑实验](udp-pacing-rejected/README.md)、[NDIS 接收调度与遥测线程优先级对照](ndis-receive-scheduling/README.md)、[桌面观察器异步读取对照](async-desktop-observer/README.md)、[未采用的 GPU 优先级对照](gpu-priority-rejected/README.md)、[观察器等待精度与窗口端点对照](observer-timing/README.md)、[未采用的绘图表面原位更新](inplace-surface-rejected/README.md)、[AV1 窗口支持与六轮编码对照](av1-window-codec/README.md)、[未采用的无帧槽等待交换链](nowait-swapchain/README.md)、[GPU 查询与日志开销六轮对照](trace-controls/README.md)、[捕获帧到达唤醒优化](capture-readiness/README.md)、[未采用的窗口提交采集调度](capture-commit-cadence/README.md)、[Windows 合成路径与背景效果对照](composition-path-probe/README.md)。以下火焰图与阶段数据保留为优化前研究基线；常规配置的隔离测试约 49–58 次原生 commit/s；调低冲突的遥测线程优先级后约 59.5–59.6 次/s，原设置已恢复。物理 4K60 与两帧内显示延迟仍未验证。

## 1. 时间已经校准，几十毫秒差异不是时钟偏差

最终轮保存了 768 次原始四时间戳交换，逐条复算通过，形成 96 个校准映射。校准不确定度中位 ±0.115 ms，最大 ±0.225 ms；Windows 单调钟与 QPC 的锚点采样区间为 10.96 μs。帧使用捕获时刻之前的有效映射；没有有效映射、重复身份或倒序区间的记录不能用于归因。

四时间戳计算为 `RTT=(t3-t0)-(t2-t1)`，`offset=((t1-t0)+(t2-t3))/2`；有符号除法按运行时代码向零截断。不确定度取往返网络时间的一半向上取整，不能把最小 RTT 估计当作精确单向延迟。观测到的 offset 变化 0.173 ms 包含路径不对称；拟合斜率不能命名为独立测得的晶振漂移。[校准和阶段原始统计](profile-gpu-timestamps/clock-and-stages.json)

源内容是 3840 × 2400，捕获含边框为 3848 × 2408；透明度 atlas 每帧 9,650,176 字节。接收端是 Windows QEMU 环境、Intel GPU 与 6K 虚拟输出，blur=12。这组结果不能直接外推到物理 4K 屏幕或 macOS。

## 2. Linux：复制热点有独立计时验证

轻量轮 perf 以 199 Hz 采样用户 CPU，保留实际帧运行区间 1,688 个样本，lost=0。libc build ID 与本机符号匹配后，叶节点复制别名 `__memmove_avx_unaligned_erms` 占约 39.2%，`memcmp` 占约 12.3%。memcpy/memmove 在该 libc 共享实现地址；不完整调用栈不能用于编造调用者。CUDA 驱动约 22.0%，另有约 14.0% 样本无用户栈。**这些比例是采样 CPU 权重，不是整条流水线耗时。** [可搜索 Linux 火焰图](profile-light/linux-cpu-live.svg)

随后在具体调用点加入 frame ID、字节数、单调时间和线程 CPU 时间；只对三个阶段身份齐全且唯一的同一帧求和。最终轮 1,276 帧的结果如下。

| 操作 | 线程 CPU 中位 ms | 壁钟中位 ms |
|---|---:|---:|
| pinned alpha → C++ vector | 1.180 | 1.197 |
| C ABI → Rust buffer | 1.102 | 1.118 |
| alpha cache 全量比较 | 0.765 | 0.770 |
| 同帧三操作总计 | **3.219** | **3.254** |

总计来自同帧求和后的分布，不能用三个独立中位数相加代替。另一轮同帧 CPU 总计 4.170 ms，说明具体值存在运行变化；稳妥结论是这一链路约消耗 **3.2–4.2 ms CPU/帧**。这尚不包括 GPU readback 或编码。[逐操作统计](profile-gpu-timestamps/alpha-copy-summary.json)、[另一轮统计](profile-gpu-narrow/alpha-copy-summary.json)

代码路径位于 `gpu_dmabuf_encoder.cu` 的 pinned→vector、`gpu_dmabuf_encoder_cabi.cpp` 的输出复制及 `gpu_compatible_encoder.rs` 的 cache 比较。网络 alpha 引用命中省下 RLE 发送，但没有消除这些源端处理。CUDA host span 含同步与等待，不能命名为纯 GPU kernel 时间。[NVIDIA 同步语义](https://docs.nvidia.com/cuda/cuda-runtime-api/api-sync-behavior.html)

## 3. Windows：反复展开 alpha，且 ETW 放大了缺页成本

用 Release 优化加 PDB 获取原生符号。CPU 轮共 8,210 个样本，缺栈 229；其中原生 presenter 6,340，Rust receiver 1,870。以下比例以原生 presenter 为分母。

| 栈或叶节点 | 占比 | 含义 |
|---|---:|---|
| `DecodeVfar` inclusive | 32.6% | 包含后代调用、缺页及其 tracing 开销 |
| `memcmp` leaf | 11.1% | CPU 实际比较热点 |
| `memset` leaf | 10.4% | CPU 实际写入热点 |
| `AtlasFrameBindings::Stage` leaf | 8.5% | 帧绑定记账也有成本 |
| `HalpHpetQueryCounter` leaf | 22.1% | 混有 ETW 自身和系统计时成本 |

`platform/windows-composition-preview/vfgp_parser.cpp` 每条压缩帧调用 `DecodeVfar`，通过 `vector::insert` 反复填充展开 alpha。已有网络引用及后面的 R8 cache 不等于原生 pipe 解析也复用展开数据。[Windows native 火焰图](profile-gpu-timestamps/windows-native.svg)、[receiver 火焰图](profile-gpu-timestamps/windows-receiver.svg)、[精确计数](profile-gpu-timestamps/cpu-summary.json)

**不能把 32.6% 直接当作可消除的正常运行成本。** 单条最重栈占 705 个原生样本：`DecodeVfar → vector::insert → memset → KiPageFault → EtwTracePageFault → EtwpGetLoggerTimeStamp → HalpHpetQueryCounter`。这是透明度写入和 ETW 记录缺页事件的耦合。即使自定义 WPR 只请求 CPU 样本，所见样本仍包含这些事件记录成本；不能声称这一轮完全无 tracing 干扰。此处的结论是优先验证展开缓冲区与引用复用，而不是承诺 32.6% 加速。

## 4. GPU：区分命令提交、排队和 GPU 时间戳

CPU 上调用 surface copy 的中位跨度只有 0.017 ms，但这仅是提交调用。最终轮使用异步回读的 D3D11 timestamp/disjoint 查询，125 个有效区间、无 disjoint：

| GPU 时间戳区间 | 样本 | 中位 ms | P95 ms |
|---|---:|---:|---:|
| composition surface copy | 63 | 0.948 | 7.569 |
| NV12 + alpha shader | 62 | 1.195 | 8.438 |

这些是两枚 GPU timestamp 之间的经过时间，仍可能包含调度或抢占，并非独占执行时间；也未测 DWM 内部 shader。只有频率有效且 disjoint 为 false 的数据才保留。[GPU 统计](profile-gpu-timestamps/gpu-timestamp-summary.json)、[Microsoft 查询契约](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ne-d3d11-d3d11_query)

另做约 10 秒窄 GPU ETW，按 adapter、context、submission identity 关联，拒绝抢占、多次提交及不完整记录，lost events=0。同一 Intel adapter 的 node metadata 确认 node 0 为 3D，node 1 为 VIDEO_DECODE。

| 进程 / engine | 配对包数 | CPU queue 中位 ms | hardware residence 中位 ms |
|---|---:|---:|---:|
| 原生 presenter / 3D | 2,157 | 7.199 | 1.199 |
| DWM / 3D | 1,118 | 0.128 | 5.982 |
| 原生 presenter / video decode | 583 | 0.088 | 8.363 |

Hardware residence 是提交至完成，包含硬件队列等待。各包区间存在重叠，累加后除以时长不能称作 GPU 利用率。这些包没有建立到应用帧的确定对应，因此不能将它们拼成某一帧的延迟分解。[包配对统计](profile-gpu-narrow/gpu-queue-summary.json)、[Microsoft hardware queue 定义](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/gpu-hardware-queue)

## 5. 桌面观察的限制决定了还不能宣布达标

重型 CPU+GPU+DesktopComposition ETW 轮仅观察到约 13.5 次不同 marker/秒，capture→所见桌面时间中位约 152 ms；关闭重型 ETW 后约 37.7 次/秒、64.3 ms。重型 trace 显著扰动了工作负载，不能作为正常性能基准。后续窄 GPU 轮为 35.1 次/秒、64.0 ms，最终 CPU+GPU timestamp 轮为 38.0 次/秒、65.0 ms。[轻量轮](profile-light/desktop-summary.json)、[最终轮](profile-gpu-timestamps/desktop-summary.json)

最终轮分阶段中位：capture→encode 1.34 ms；encode host（含等待）11.48 ms；encoded→pipe admission 6.87 ms（传输、receiver 和 pipe 解析合计）；pipe→decoded 4.69 ms；decoded→proxy-ready 0.76 ms；应用 committed→所见桌面 36.61 ms。流水线重叠，样本集合不同，**不得累加这些独立中位数，也不能把最后一段称为 DWM CPU 耗时**。[逐帧时间线 JSON](profile-gpu-timestamps/timeline.json)

观察器只读 marker scanline，Copy/Map 中位仍为 9.39 ms，且 `AccumulatedFrames` P95=2。它会漏观更新并向同一 GPU 添加工作。结束时间使用系统 `LastPresentTime`，不是 Map 返回时刻，所以不能从 65 ms 中直接减去 9.39 ms。若 marker 首次出现时没有被读到，当前配对结束点可能是后来仍含该 marker 的桌面更新时间。

因此这里的“上界”只处理了时钟不确定度，且结束点为**所见桌面**，不是准确的首次显示或光子时间；JSON 中基于该端点的 two-frame 计数不能作为真实显示通过/失败判据。约 38 次 marker/秒也不是已经证明的实际显示 FPS。[Microsoft desktop frame info](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/ns-dxgi1_2-dxgi_outdupl_frame_info)

## 6. 下一轮应验证什么

1. **先减少源端两次全量 alpha ownership copy。** 保留生产与消费生命周期，避免删除必要 CUDA 同步；对照同帧 CPU 成本、encode span 和完整输出正确性。预期降低 CPU 开销，收益尚待实验。
2. **将 alpha 引用复用延伸到 Windows 原生解析。** 对相同 alpha 保留展开缓冲区与明确身份，减少重复展开、分配和比较；新尺寸、变化、乱序或失效引用必须正确恢复。比较不开 ETW 的交错对照，再用短 CPU trace 验证热点变化。
3. **保留队列证据，完善最终呈现测量。** 用异步 observer staging ring 或可靠 surface→present 关联减少读回干扰，并验证它没有错误配帧。当前还不能断言换一个 composition API 能解决剩余延迟。

已完成 Linux release/native GPU 构建、Windows 原生 Release+PDB 构建、Rust alpha 14 项测试及 clock 4 项测试。另补充分析器的错误时钟、重复帧、缺阶段、抢占、错误 DMA 身份、owner 错配、倒序拒绝测试。仅以构建和测试通过不构成 4K60 达标。

## 证据与复现

每轮日志压缩保存在对应 profile 目录；独立 ETL 和 perf 原始文件保留于本机 `/tmp/viewflow-profile-*.etl`、`/tmp/viewflow-source-profile-*.data`。`cpu-only.wprp`、`gpu-narrow.wprp`、`etw-reader.cs` 与 `.csproj` 保存本轮采集和解析实现。源代码中的 timestamp 记录保持帧身份，CPU 和 GPU 数据分开采集；没有通过改动断连阈值制造性能改善。

分析入口：`tools/profile_atlas_timeline.py`、`tools/summarize_alpha_profile.py`、`tools/summarize_gpu_queues.py`、`tools/symbolize_perf_libc.py`。`python3 -m unittest discover -s tools -p test_profile_analysis.py -v` 可运行关联正确性检查。火焰图由 Brendan Gregg FlameGraph 工具生成；Linux 按 CPU 纳秒加权，Windows 按采样事件加权，不能横向比较两图总宽度。

研究停止点：足以把下一步选择从“再换提交 API”转向“先减少已量出的重复 alpha 处理”，且关键测量语义已明确。尚缺真实首呈现关联、无观察器的端到端对照，以及优化后的完整性能验证。这些属于后续实验，不能由本报告的统计推导替代。
