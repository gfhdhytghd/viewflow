# 已撤回：不等待帧槽的 Composition 交换链

2026-09-08。在同一台 Windows 接收机完成四轮开关对照。**去掉显式帧槽等待后，capture→所见桌面延迟中位数仍从约 50–52 ms 增到约 69 ms，因此撤回本次实验代码。** 原生提交率没有稳定提高；4K60、两帧内最终显示仍未验证。

这次与[此前交换链实验](../../performance-20260907/README.md)的区别是：没有等待帧槽、没有 deferred-present 队列或定时重试。它也不同于[绘图表面原位更新](../inplace-surface-rejected/README.md)：实际采用 DXGI flip sequential 交换链，并记录每次 Present 的返回值与 QPC。

## 实现与退出方式

试验开关为 `VIEWFLOW_ATLAS_NOWAIT_SWAPCHAIN=0/1`，默认关闭。交换链采用两张 BGRA premultiplied buffer、FLIP_SEQUENTIAL、FRAME_LATENCY_WAITABLE_OBJECT，SetMaximumFrameLatency(1)。只保留并关闭其 event handle，从不等待或消费该 handle；直接复制后调用 `Present(0, DXGI_PRESENT_DO_NOT_WAIT)`。

普通布局变化在未绑定的候选表面上完成。布局、身份路由字段、patch/opaque 分类及实际窗口尺寸/位置等全部相同，并确认现有 sparse visual 可复用时，才在所有场景准备之后更新当前绑定的交换链；不再次绑定 Surface。帧序号和源时间戳正常前进不阻止复用。任一复用条件不满足就走普通候选路径，没有增加帧准入或会话限制。

若 Present 返回 WAS_STILL_DRAWING，代码准备同一帧的普通 DrawingSurface 并重建 sparse 候选，继续完成原有提交，不把繁忙当作过期或终止会话。这个回退已实现，但 **本轮性能测试及像素测试都没有遇到该返回值，因此没有把回退分支记为已覆盖**。创建交换链失败会关闭这项可选路径并尝试原有绘图表面；真正的设备/复制错误仍由已有错误路径报告。

改动先在本地和隔离 Windows 源码中实现，编译到独立 native-nowait-build。测试完毕后，五个源文件逐字节恢复，新增 stable_surface_layout.h 从两端构建路径移除；原 native-build EXE、默认 Rust receiver 及其 PDB 从未被替换。完整候选代码在 [source-experiment](source-experiment/)。

## 像素与实际路径验证

- Windows MSVC Release 构建与 atlas frame binding 测试通过。独立 GPU visual oracle 使用 84 个阶段，覆盖透明洞、多区域背景模糊、1/.75/.5 缩放、整数/.25 偏移、布局变化与连续更新；参考侧每次用独立 DrawingSurface。84 次交换链更新中有 48 次更新当前已绑定交换链，全部 mismatches=0、verified=1。
- 真实桌面 HostBackdrop oracle 使用自己创建的非激活窗口。四个阶段全部参考/候选像素一致，包含背景颜色变化、条纹模糊响应和 repack；共四次交换链更新、两次当前链更新。背景响应=80，模糊与无模糊对照差异为 110,592 个通道，foreground_unchanged=1。
- 两个 oracle 的进程均 exit=0，自己的计划任务已删除；没有注入键鼠或改变焦点。本次不包含 macOS 或其他 Windows GPU 的验证。

[84 阶段日志](method/nowait-pixels.log.gz)、[真实桌面背景日志](method/nowait-host.log.gz)、[构建日志](method/nowait-presenter-build.log.gz)。这些测试验证所覆盖的像素与路径，不替代下面的真实流性能测量。

## 四轮完整链路对照

H.264、3840×2400 源内容，实际捕获 3848×2408、atlas 3968×2432；Windows 实际输出 6144×3456@60、Intel GPU，proxy 1:1 像素放置。不是物理 4K 输出验证。每轮 25 秒源视频与 20 秒桌面观察，顺序 off/on/on/off。每轮使用同一源端、Rust receiver、原生候选 EXE、timer1 桌面观察器和 GPU/socket tracing 配置。

| 轮次 | 原生 commit/s | 所见 marker/s | capture→所见桌面上界中位 ms | P95 ms | capture→mutation 上界中位 ms | mutation→所见桌面中位 ms |
|---|---:|---:|---:|---:|---:|---:|
| 4k-nowait0-a1 | 56.65 | 39.21 | 52.25 | 70.22 | 15.43 | 34.80 |
| 4k-nowait1-b1 | 56.19 | 47.44 | 68.74 | 156.72 | 18.71 | 49.44 |
| 4k-nowait1-b2 | 56.40 | 47.49 | 68.78 | 116.51 | 18.47 | 49.45 |
| 4k-nowait0-a2 | 58.32 | 40.58 | 49.91 | 67.22 | 15.31 | 34.35 |

启用后，所见 marker/s 增加，但帧变得更旧，延迟中位数及 P95 都增加。不能把“读到了更多不同帧”当作低延迟目标已实现。两轮 on 的 mutation→桌面跨度约 49.4 ms，比 off 的约 34.4–34.8 ms 更长；它包含队列、GPU、DWM 和观察端点，不是 DWM CPU 耗时。[完整统计](comparison.json)

B1/B2 分别记录 1,367/1,373 次 Present，全部 status=0；其中 1,366/1,372 次使用同一条已绑定交换链，均只有首次是未绑定链。WAS_STILL_DRAWING=0，没有退回 DrawingSurface 掩盖实际路径。按 60 帧抽样的表面记录分别 23/22 条，也均为 bound=1、swap=1。

| 启用轮次 | copy 调用中位 ms | copy P95 ms | copy 最大 ms | Present 中位 ms | Present P95 ms | Present 最大 ms |
|---|---:|---:|---:|---:|---:|---:|
| 4k-nowait1-b1 | 0.087 | 7.511 | 95.904 | 0.116 | 3.627 | 13.461 |
| 4k-nowait1-b2 | 0.085 | 7.561 | 139.255 | 0.114 | 3.741 | 19.485 |

这些是 host wall-clock 跨度，包含 API/驱动调用及线程调度，不能直接全部归因于 GPU 执行或某一个阻塞点。去掉显式等待并没有消除这个配置下的长尾。测试保留了原来的逐帧 GPU query、QPC 与 socket tracing；没有单独验证关闭这些诊断后的交换链性能，因此撤回结论限定于已测配置，不声称所有交换链方案都更慢。

## 一个必须保留的负阶段差

B2 的 atlas frame 186、源 marker 674，在观察器中的 LastPresentTime 比 native committed QPC 早约 38.897 ms。分析器最初沿用 DrawingSurface 路径的“commit 必须早于 desktop”断言而中止；检查原始记录后，改为保存并报告该差值，没有删去该帧或重新对时来消除负数。

这条帧的 Present 已成功返回，约 21.516 ms 后出现桌面 LastPresentTime，而 native copy-ready/committed 记录要到 Present 返回后约 60.2/60.4 ms 才发生。GPU event query 的 submitted QPC 也在较晚位置。因此该样本与“当前绑定的交换链先更新内容，CPU 之后才完成提交记录”一致，不要求假设桌面时间早于实际 Present。它再次说明 native commit 不是屏幕呈现事件。

[完整同帧记录](method/nowait-early-visible-frame.json)包括 source marker、native 阶段、Present、GPU completion 及 desktop marker。copy-ready 已放在实际复制调用之后，但它表示 CPU 代码完成该步骤，不能证明精确 GPU 完成时刻。仍不把这个单个样本当作首次显示或光学测量的证明。

四轮唯一 marker 配对 771/939/937/804；仅 B2 有一个重复捕获导致的歧义 marker，排除而不补配。所有原始四时间戳交换复算有效，使用的 mapping 有效期覆盖桌面端点，capture→desktop 上界没有负数。B2 保留一条负的 commit/mutation→desktop，其余轮次没有。marker、正 LastPresentTime、readback sequence 严格递增；所有 ring abandoned=0、pending_peak=2。A1 有一条被并发写入打断的编码耗时行，解析内容被保留并从编码阶段统计排除；有效延迟长尾没有删除。

## 恢复与复算

每轮前后读回 ESRV 进程及当时两个 TimeCritical 线程为 Normal/base8，并确认没有其他 TimeCritical；这不是全程优先级采样。独立 10 分钟 SYSTEM 恢复任务绑定进程/线程创建时间。finally 恢复原来的 High/TimeCritical 并删除任务，未停止、重启或禁用服务。源按计划结束，receiver 随 peer 关闭，watchdog=0，观察器 exit=0。

临时 headless output 已移除，前后完整 monitor 列表与焦点读回一致；本地发送/接收配置与 Windows 隔离配置均逐字节恢复。最终现场读回：ESRV Running/Auto、PID 2344、High、两条 TimeCritical，实验进程及任务均为 0。

原 native EXE 仍为 `81CB49DD9269A50B7FB6124539F8034EDB094BD54700707E2BDF0F2E1442E0B4`，默认 Rust receiver 仍为 `A39CB1F4BD003EC3EE1237AF05D9915316E86119DC21FBE1C9F626CE61B3C30A`，原 PDB 哈希均未变。独立实验 EXE 为 `B636DC0EEE30967F7400CCABD64083BA147114DCB5421642BC8752A50DD950A6`；该新 Release 目录没有生成 PDB，清单明确记录不存在，没有声称备份了实验 PDB。[最终核验](method/nowait-final-state.json)、[控制记录](method/nowait-swap-state.json)

目录包含每轮压缩 source/receiver/desktop/producer/runner/cleanup/driver、fixture、唯一身份配对、逐次 Present QPC 和摘要；源码恢复前已冻结完整实验版本。method 保存构建、运行、分析和恢复脚本。绝对路径对应当时隔离环境；不能未经当前身份检查直接再次执行状态修改脚本。

纯分析：将 source/receiver/desktop 解压到 `/tmp/viewflow-integrated-pair/{kind}-{label}.log`，producer 解压到 `/tmp/viewflow-frame-fixture-first/{label}-source.log`；使用 source/tools 的两个依赖作为工作目录中的 tools，运行 `method/summarize-nowait-swap.py`，依序传入表中四个 label。SHA256 清单覆盖本目录文件，清单自身除外。

Microsoft 文档说明 [DO_NOT_WAIT](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-present) 可以用 WAS_STILL_DRAWING 返回替代 Present 内的特定等待；[Present 的 flip model sync interval 0](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiswapchain-present) 涉及队列中的帧取舍；[SetMaximumFrameLatency](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_3/nf-dxgi1_3-idxgiswapchain2-setmaximumframelatency) 要求创建时启用对应 waitable flag。这些 API 语义不保证本测试中的 host 调用耗时或最终显示延迟，后两者以上面的实测为准。
