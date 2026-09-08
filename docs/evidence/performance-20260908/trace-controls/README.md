# GPU 查询与日志开销：六轮对照

2026-09-08，Linux → Windows；H.264 窗口路径。

**单独关闭 native GPU 查询没有带来稳定的显示延迟下降。进一步减少 socket/source 诊断后，capture→desktop 上界中位数仍为 48.40–49.00 ms，P95 为 65.81–67.08 ms。没有证明 4K60 或两帧内显示。**

本轮新增独立开关 `VIEWFLOW_ATLAS_GPU_QUERIES=0`，在 `VIEWFLOW_ATLAS_TIMINGS=all` 下关闭 native timestamp/disjoint 和 surface-copy completion EVENT 查询，保留 QPC、帧身份和 mutation 记录。不设置新变量时维持原行为；原本不启用 all 的常规路径仍不开这些查询。现有 context Flush 保留，未新增等待、超时退出或输入限制。保留这项诊断能力；不把诊断开销下降当成默认产品性能提升。

## 同一流水线的三种控制

| 模式 | native GPU queries | 两端 socket trace | 源 GPU 分段计时 / alpha-copy profile | QPC、身份、时钟校准 |
|---|---:|---:|---:|---:|
| full A | 开 | 开 | 开 | 开 |
| noquery B | 关 | 开 | 开 | 开 |
| minimal C | 关 | 关 | 关 | 开 |

按 A1、B1、C1、C2、B2、A2 顺序执行，每轮源 25 秒、桌面观察器 20 秒。B 只改变 GPU 查询；C 同时减少三种诊断，不能把 B→C 差异唯一归因于其中一项。minimal 仍有 QPC/identity、原始四时间戳校准、atlas source/wire 记录及 GPU fixture marker 提取，**不是完全无诊断的生产配置**。

使用相同的 Windows native EXE、原 Rust receiver、H.264、FFmpeg 8.1 SDK 构建，以及同一个 DD 异步观察器（timer=1 ms，readback ring 不变）。仅试验 runner 的环境不同；无 ETW/WPR。源自有 headless output 为 3840×2400@60，捕获含边框为 3848×2408、atlas 3968×2432，接收端 Intel GPU 输出 6144×3456@60，窗口按 1:1 放置且 NOACTIVATE。它覆盖约 4K 内容的实际 Linux→Windows 路径，不能外推为物理 3840×2160 屏幕验收，也未测试 macOS。

## 结果

端点沿用[测量基础](../../performance-20260907/README.md)：源捕获时间经此前有效时钟映射转换，与含该唯一 marker 的桌面 LastPresentTime 对齐。表中延迟为含校准不确定度的上界。DD 不是光子端点，也没有证明每帧首次可见时间。native commit/s 和 DD 观测 marker/s 分开列示，不能互相替代。

| 轮次 | native commit/s | DD marker/s | capture→DD 中位 ms | P95 ms | 最大 ms | capture→mutation 中位 ms | mutation→DD 中位 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| 4k-trace-full-a1 | 55.819 | 37.890 | 52.475 | 70.322 | 170.236 | 15.819 | 34.712 |
| 4k-trace-noquery-b1 | 57.742 | 39.060 | 49.820 | 68.718 | 118.879 | 15.449 | 33.653 |
| 4k-trace-minimal-c1 | 57.984 | 40.915 | 49.002 | 67.076 | 118.905 | 14.261 | 34.389 |
| 4k-trace-minimal-c2 | 57.525 | 40.352 | 48.396 | 65.806 | 129.548 | 14.162 | 33.942 |
| 4k-trace-noquery-b2 | 57.445 | 40.816 | 50.595 | 67.230 | 205.562 | 15.308 | 34.650 |
| 4k-trace-full-a2 | 58.235 | 40.837 | 49.257 | 66.027 | 113.712 | 15.095 | 33.435 |

A1 比 A2 慢，因此不能用 A1 与 B1 的差值声称稳定收益。B1/B2 的中位延迟落在 A1/A2 的范围内，且最大值仍有长尾。C1/C2 的 capture→mutation 约 14.2 ms，较其余轮次约 15.1–15.8 ms 小；但 mutation→DD 仍约 34 ms，没有消失。六轮为成对反序的有限样本，没有统计显著性结论。

| 轮次 | encode host 中位 ms | encoded→pipe admission 中位 ms | pipe→decoded 中位 ms | source 日志 MB | receiver 日志 MB | timestamp / completion 条数 |
|---|---:|---:|---:|---:|---:|---:|
| 4k-trace-full-a1 | 7.260 | 3.739 | 1.537 | 19.01 | 24.68 | 124 / 1335 |
| 4k-trace-noquery-b1 | 7.244 | 3.635 | 1.561 | 19.49 | 25.30 | 0 / 0 |
| 4k-trace-minimal-c1 | 7.007 | 2.806 | 1.585 | 2.91 | 2.83 | 0 / 0 |
| 4k-trace-minimal-c2 | 6.944 | 2.699 | 1.574 | 2.90 | 2.81 | 0 / 0 |
| 4k-trace-noquery-b2 | 7.018 | 3.664 | 1.563 | 18.08 | 25.05 | 0 / 0 |
| 4k-trace-full-a2 | 7.019 | 3.641 | 1.559 | 18.61 | 25.40 | 141 / 1406 |

这些阶段是重叠流水线的独立分布，不能相加中位数来复原同帧总耗时。encoded→pipe admission 包含传输、接收调度和 pipe parse；它的下降不能全部命名为网络改善。日志体积为整轮 UTF-8 字节数/1,000,000，不代表 CPU 时间。

实际日志验证：full 两轮记录 GPU queries enabled=1 且两类查询记录均存在；其余四轮 enabled=0 且两类记录均为 0。只有 minimal 两轮两端 socket anchor 均为 0、源 GPU encode timing 和 alpha-copy-profile 均不存在。所有轮次保留 native mutation、源帧 marker 和校准信息。因此缺少 GPU completion 的 B/C 行是预期的控制结果，不补造 GPU 完成时间。

## 数据完整性与范围

唯一 marker 配对分别为 745/772/806/800/806/797；重复捕获造成的歧义分别为 0/1/0/0/2/11，原始数据全部保留，只排除不唯一的配对。没有 missing capture marker。六轮全部四时间戳交换逐条复算通过（768/768/768/776/768/773），时钟映射有效期覆盖桌面端点。marker、正 LastPresentTime、readback sequence 严格递增；全部 ring abandoned=0、pending_peak=2。capture→DD 上界以及 mutation/commit→DD 无负数。

A2 有一条被并发日志打断的编码计时行，解析后的原始字段保存在 summary 的 malformed_encoder_rows，整行仅从编码分段统计排除；未删除有效延迟长尾。minimal 的编码分段集合为空是明确关闭诊断的结果；encode host 全阶段仍由 QPC source timeline 得到。

[上一轮无等待交换链](../nowait-swapchain/README.md)的负 commit→DD 样本发生在先 Present、后 CPU 提交记录的路径。本轮全部使用原 DrawingSurface，既不能用本轮无负数否定该样本，也不能据本轮控制数据推断上一轮单帧约 60 ms CPU 间隙的具体原因。没有重新测试交换链或改变之前撤回该实现的状态。

## 构建、恢复与复算

Windows 原生 Release 构建及 frame bindings 可执行测试成功。实际六轮驱动均 exit=0；源按计划结束、receiver 随 peer 关闭、watchdog=0、桌面观察器 exit=0，逐轮清理验证 isolated_processes=0。此改动仅控制诊断查询，未新增像素算法，所以没有重跑与之无关的像素/鼠标/键盘验收。

每轮前后 ESRV 进程与当前两条 TimeCritical 线程均读回 Normal/base8，且无其他 TimeCritical；不把前后读回说成连续采样。独立 10 分钟 SYSTEM 恢复任务先于控制创建，finally 恢复配置和原来的 High/TimeCritical 再删除任务。服务没有被停止、禁用或重启。

最终现场检查：ESRV Running/Auto、PID 2344、High、两条 TimeCritical，实验进程和任务均为 0。发送/接收本地配置及 Windows 隔离配置均与原备份字节一致。自有 headless output 已移除，前后完整 monitor 与焦点读回一致；没有注入鼠标键盘或切换用户焦点。

独立新 native EXE SHA256 为 `DF6EB3FAD88B8DADEC5EC0C0427DE395428E3731D36DF0658AA8C071324A6F2B`，用于上述六轮；源代码保留新查询开关。常规配置已恢复，原 native EXE `81CB49DD9269A50B7FB6124539F8034EDB094BD54700707E2BDF0F2E1442E0B4`、Rust receiver `A39CB1F4BD003EC3EE1237AF05D9915316E86119DC21FBE1C9F626CE61B3C30A` 及其原 PDB 未被替换。DD observer 仍为 `D57C7377AEFCD603D01626948805949EB78BB9B7C7C8C52CB0604A471841AAEA`。[最终核验](method/trace-controls-final-state.json)、[控制记录](method/trace-controls-state.json)、[构建输入快照](method/trace-controls-presenter-source.tar.gz)。

目录保存六轮 source/receiver/desktop/producer/runner/cleanup/driver 压缩原始日志、fixture、全部唯一配对与 summary。method 含完整 native configure/build 日志、构建输入哈希与归档、三个 runner 源码、运行/分析/恢复脚本。脚本中的绝对路径、进程身份和环境对应当时隔离现场，重新做有状态试验前需要重新核对，不应直接照搬。

纯分析复算：将 source/receiver/desktop 解压为 `/tmp/viewflow-integrated-pair/{kind}-{label}.log`，producer 解压为 `/tmp/viewflow-frame-fixture-first/{label}-source.log`；以 source/tools 两个依赖作为工作目录中的 tools，运行 `method/summarize-trace-controls.py` 并依次传入表中六个 label。本目录 sha256.json 覆盖全部文件，清单自身除外。

下一步仍需降低实际流水线和显示等待：本轮证据不支持把关掉 GPU 查询当成主要优化。可使用 minimal 诊断作为后续对照之一，但完整 4K60、两帧内显示目标仍未达到。
