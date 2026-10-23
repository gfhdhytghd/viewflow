**40% 收敛版本已应用：** 默认导入缓存、帧率／延迟优先捕获和Viewflow自身MMCSS调度已安装，默认延迟优先。最终两轮桌面更新约59.4／59.07次/秒、中位35.42／26.56ms、最大46.05／44.28ms，仍未达标。原未运行的主服务保持关闭，新主程序下次开启时使用。已转入Windows→Linux 6K30／60ms优化。见[安装与恢复记录](production-deployment/README.md)、[最终调度对照](mmcss-canonical/README.md)。

以下为按阶段保存的历史记录，涉及“待部署”的文字描述当时状态。

**正式双端候选已测量并暂存：** 34 项原生测试、四阶段背景像素验证和四轮真实流全部通过。帧率优先桌面更新约 59.3–59.4/s、延迟上界中位 43–48 ms；延迟优先约 56.7–58.4/s、中位 25–33 ms，仍有超过两帧的长尾。剩余额度 41% 时尚未替换生产文件，按用户要求准备在 40% 应用。见[正式组合](production-pair/README.md)、[部署准备](production-deployment/README.md)。

**默认导入缓存已接入待部署版本：** 约 1 ms 的编码节省已集成，默认开启时通过 GPU／完整 4K 检查及四轮真实流；当前桌面服务的安装版本尚未切换。两档组合中延迟优先完整中位 24.18 / 27.17 ms，固定节奏 37.42 / 39.58 ms，帧率有交叉且长尾仍超两帧。见[集成状态](import-cache-production/README.md)、[两档对照](performance-mode-import-integration/README.md)。

**共享 blur 实验：** 实际复用路径及像素对照通过，但帧率与完整延迟没有稳定改善，保持关闭。见[原生像素及完整链路](shared-blur-brush/README.md)。

**当前导入缓存复测：** 在计时与 DDC 修复后，缓存仍节省约 1 ms 编码时间；开启组观测 58.3 / 56.2 次不同 marker/秒，关闭组 51.43 / 54.6。完整延迟未稳定下降，且有约 158 ms 长尾，暂不替换生产默认。见[当前条件下的四轮对照](import-cache-hyperv-ddc/README.md)。

**当前调度复测：** 保留计时与 DDC 修复，普通遥测优先级两轮达到约 59.8–59.9 次原生提交/秒、慢回执减少；完整桌面更新与延迟未稳定改善，测试后已恢复原设置。见[完整对照与恢复](esrv-hyperv-ddc-control/README.md)。

**已修复并应用周期性编码停顿：** 四轮恢复对照确认，后台 DDC/CI 亮度读取触发每十秒一次 225–246 ms 停顿。改为现有的面板打开／亮度调整后按需读取，两轮长停顿均消失，原生提交率升至约 59.4–59.5 次/秒。完整延迟仍未达标；第一／第二候选绘制前→桌面中位 46.89 / 38.30 ms，未省略较差一轮。见[修改、原始数据与部署](periodic-ddc-stall/README.md)。

**GPU 分段诊断：** 1 ms 查询缩小了 GPU 完成范围，但未稳定改善完整延迟，诊断未部署。见[四轮对照](gpu-poll-cadence-hyperv/README.md)。

**两档模式已接线并复测：** 真实源配置分别选择固定节奏 / 提交唤醒，stream ID 与原生入口对应；切换工具事务测试和 QML 静态校验通过。两轮延迟优先的绘制前→桌面中位 28.26 / 39.98 ms，仍不稳定，生产默认及界面尚未替换。见[完整接线与证据](performance-mode-integration/README.md)。

**提交唤醒复测：** 延后首次静态补采后，两轮采集前等待中位降到 0.45 / 0.37 ms，保留完整毛玻璃的绘制前→桌面中位为 37.70 / 35.68 ms，P95 为 38.98 / 40.90 ms，观测约 56.7–57.6 次不同标记/秒；仍未达两帧内目标，候选尚未部署。见[四轮数据](commit-wakeup-grace-hyperv/README.md)、[首版对照](commit-wakeup-hyperv/README.md)。

**捕获频率对照：** 60 / 90 / 90 / 60 Hz 四轮保持完整毛玻璃和相同接收二进制。90 Hz 没有稳定改善完整延迟与桌面更新率，继续保持 60 Hz 默认；提交唤醒复测见顶部。见[完整对照](capture-rate-hyperv/README.md)。

**计时补丁登录后复测完成：** 同一 2048 样本探针的 1 ms 等待中位从 4.70–5.47 ms 降至 1.39–1.52 ms。完整毛玻璃普通路径最后一轮观测 57.87 次不同标记/秒，捕获→所见桌面上界中位 / P95 为 30.79 / 31.53 ms；绘制前→桌面仍为 55.23 / 56.10 ms。前一普通轮为 44.77 次/秒、绘制前中位 28.37 ms，不能拼接两轮最佳值。直接绘制候选出现标记失效，未采用；4K60、两帧内端到端仍未证明。见[应用、复测和保真检查](hyperv-timer-enabled/README.md)。

**直接绘制 4K 对照：** 七组完整像素、偏移和故障恢复校验通过；四轮完整链路减少了 UI 工作，但捕获→所见桌面上界中位仍约 48.6–52.6 ms，没有稳定改善。候选不接入默认路径。见[实现与原始证据](direct-composition-output/README.md)。

**等待精度检查：** 2048 次交错测量中，显式尊重精度请求没有改善约 4.7 ms 的 1 ms 等待，高精度 timer 也未改善。发现当前 Windows VM 未暴露 Hyper-V 计时接口；已准备并用独立暂停实例校验启动参数补丁，该项后来已应用并完成 Windows 系统内重启；本段测量保留为修改前基线，登录后复测见本文顶部。见[测量与待验证补丁](wait-resolution-probe/README.md)。

**完整被动 4K 对照：** 四轮全链路鼠标穿透检查通过。后台 DwmFlush 开启组捕获→所见桌面上界中位约 49.0–50.6 ms，前后关闭组约 47.0–51.4 ms，没有稳定收益，候选不接入默认路径。4K60、两帧内首次显示仍未证明。见[实现、对照与复算](passive-dwm-flush/README.md)。

**被动测试修复：** Windows 测试窗口已增加鼠标穿透，Linux fixture 已验证空输入区域。实际 4K 桌面的条纹对照确认局部渲染路径具有背景模糊；完整网络流尚未按新设置复测。背景开销分解在三组后暂停，不能得出四模式结论。见[画面与输入验证](passive-blur-validation/README.md)、[暂停的对照](background-cache-ablation/README.md)。

**实际 4K 背景缓存复测：** 30 Hz、15 Hz 共八轮对照完成。开启缓存时桌面不同帧约 32–33 次/秒、捕获→所见桌面延迟上界中位约 56–57 ms；各自前后关闭组约 39–49 次/秒、44–52 ms。两种频率均未改善，缓存保持默认关闭；4K60、两帧内仍未证明。见[4K 对照与原始证据](exact4k-background-cache/README.md)。

**严格 4K 基准：** 已锁定实际 HDMI 3840×2400、约 60 Hz 输出，观察器不再回退到 6K。两轮桌面观测约 49–53 次不同画面/秒，捕获到所见桌面延迟上界中位约 50 ms，仍未证明 4K60、两帧内显示。后续以这组 4K 基准继续定位；6K 数据仅作历史参考。见[基准与原始证据](display-4k-baseline/README.md)。

**背景精确变化检测：** 在显示范围限制内跳过约 92%–97% 的重复模糊后，30 Hz、15 Hz 各两轮完整候选仍有整链路退步，缓存保持默认关闭。八轮均为完整动态观测，4K60、两帧内仍未证明。见[对照与原始证据](background-change-detection/README.md)。

**原生背景缓存：** 已按实际显示器边界限制缓存，移动、缩放、透明洞和边界像素测试通过。30 Hz 完整对照有退步；15 Hz 一轮完整动态观测也未达目标，另有测试动画停帧与观测覆盖不足的数据单独标注。实现保持默认关闭，4K60、两帧内仍未证明。见[实现与证据](native-background-cache/README.md)。

**背景缓冲更正：** 后续条纹测试发现，16×16 裁剪锚点使整张捕获纹理被填成局部颜色。此前缓冲实验不能证明保持完整背景内容；约 29 Hz 交付和原生提交率不是保真性能达标证据。见[更正及原始像素](background-buffer/README.md#纹理校验更正)。

# Viewflow：校准、火焰图与 GPU 排队归因

最新实验：[30 Hz 后台背景缓冲与 Hyprland 算法](background-buffer/README.md)。独立设备/线程版本已运行，背景实际交付约 29 Hz，原版 GLSL 与 HLSL 在有效内区的 RGB 差异不超过 1/255，浮动窗口范围计算通过测试；桌面呈现率仍有较大波动，未证明稳定 4K60。仍为隔离原型，原生浮动窗口接线与完整链路验证待完成。

此前实验：[Windows 输出纹理池](output-surface-pool/README.md)。四轮对照把资源准备中位从约 0.61 ms 降到 0.17 ms，GPU 所有权与连续解码校验通过；但捕获→桌面延迟上界中位仍为 38.5–39.8 ms，没有稳定改善。保留隔离原型，未改动生产默认值，4K60、两帧内显示仍未证明。

此前实验：[DMA-BUF 导入缓存](dmabuf-import-cache/README.md)。四轮重复测得约 1.0–1.1 ms 的编码节省，缓存命中/淘汰和逐帧颜色、alpha 验证通过；但完整桌面延迟与提交速率没有改善，保留为隔离原型，未默认启用。4K60、两帧内显示仍未验证。

此前实验：[异步提交请求 RequestCommitAsync](commit-request-probe/README.md)。独立探针与四轮完整链路对照完成；捕获→所见桌面上界中位数关闭 38.56 / 38.53 ms，开启 38.38 / 39.04 ms，没有稳定收益，未接入生产。4K60、两帧内显示仍未验证。

此前实验：[采集提交相位跟随](capture-phase-follow/README.md)。四轮中采集前等待中位下降，但总延迟收益不稳定，P95 更高，未接入生产。

此前对照：[独立 alpha 遮罩，完整毛玻璃保留](stable-alpha-mask/README.md)。图像正/负例完成；两轮性能没有稳定收益，未接入产品。[完整 4K 链路复测](full-glass-retest/README.md)已完成两轮：捕获→所见桌面上界中位 38.98 / 38.61 ms，完整绘制→桌面上界中位 41.49 / 53.46 ms，仍未达标。

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
