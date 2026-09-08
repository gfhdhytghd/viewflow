# GPU 精确 alpha 比较：跳过未变化帧的完整读回

2026-09-08，Linux NVENC → Windows 原生接收端。内容 3840×2400，捕获 3848×2408，alpha atlas 3968×2432。**源端编码中位耗时降到约 7 ms，但原生提交仍约 53–54 次/秒；60 fps / 两帧内首次显示目标尚未达到。**

## 改动

新增 CUDA kernel，比较当前 alpha 与上一次成功输出的 GPU 镜像。所有有效像素逐字节参与，边缘无效线程也参加 block vote；每个有变化的 block 至多写一次全局标志。这是精确比较，不使用哈希或有损判断。

结果未变化时，只读回 4 字节标志并复用现有不可变 CPU 快照，省去 9,650,176 字节 alpha 读回与 CPU 扫描。变化时保留完整读回、独立快照和设备镜像更新。NV12 与比较仍在同一 stream 顺序执行，读回标志后的同步仍保证 NV12 工作完成。

设备镜像开始更新时立即失效，只有最终编码和 cleanup 成功、CPU 快照也发布之后才重新有效。这样即使新 alpha 已进入 GPU 缓存但该帧在 NVENC 前后过期，也不能拿它去授权复用旧 CPU alpha。发生 CUDA 操作错误时，完成已排队工作的收尾并退休失败编码器，不把故障当作“没有变化”。

每个固定尺寸编码器增加一块 alpha 大小的 device 缓冲区及 4 字节标志的 device/pinned 缓冲区；在所需 NVENC 资源初始化之后申请。可选缓存分配失败时释放部分资源并保留原有 CPU 路径。没有逐帧重新申请缓存。`VIEWFLOW_GPU_ALPHA_DIFF=0` 可运行 CPU 比较对照，默认开启；关闭 alpha 快照复用时也自动关闭 GPU 比较。

## 同一二进制交错 A/B

四轮各发送 25 秒，顺序 CPU A1 / GPU B1 / GPU B2 / CPU A2；alpha 快照、scratch swap、Rust 原生 alpha 持有和 Windows alpha 复用均开启。逐帧日志与桌面观察器开启，socket trace、5 ms QUIC sampler、WPR、包捕获关闭。

以下为 frame≥30 的 ms 中位数。NV12/alpha 段是主机 checkpoint 区间，包含 GPU 等待和快照处理，不能当作纯 GPU kernel 执行时间。

| 轮次 | NV12/alpha 段 | 源端 encode host | 捕获→原生修改上界 | 捕获→桌面被观察到上界 | 原生 commit/s |
|---|---:|---:|---:|---:|---:|
| 4k-alpha-diff-off-a1 | 1.192 | 8.371 | 16.208 | 53.991 | 52.002 |
| 4k-alpha-diff-on-b1 | 0.090 | 6.963 | 14.337 | 50.752 | 53.145 |
| 4k-alpha-diff-on-b2 | 0.090 | 7.087 | 14.275 | 49.455 | 53.035 |
| 4k-alpha-diff-off-a2 | 1.203 | 8.400 | 16.156 | 55.072 | 51.827 |

GPU 两轮都只完整读回 2 次 alpha（初始/变化内容）；其余比较命中的准备过程只读回标志。CPU 两轮分别完整读回 1,281 / 1,291 次。NV12/alpha 段中位数从约 1.2 ms 降到 0.09 ms；编码中位数减少约 1.3–1.4 ms，捕获到原生修改约减少 1.9 ms。两组原生提交均提高约 1.1–1.2 次/秒，仍没有稳定达到 60。

表格中的桌面观察上界下降约 3.24 / 5.62 ms，但不能把全部差异归因于这约 1 ms 的局部优化。观察器可能错过第一次出现，commit 也不是物理呈现凭据。alpha CPU 分项只计算既有 copy/compare profiling 范围，不包含 CUDA launch、等待、其他编码工作或整个进程 CPU，不能把其接近零的数值解释为整个 alpha 路径不耗资源。

[comparison.json](comparison.json) 包含完整分位数、准备阶段的 readback/compare 计数；准备阶段记录也可能来自随后干净过期的帧，所以没有把这些计数冒充成功显示帧数。各轮压缩原始日志、fixture、时钟交换与阶段统计都在子目录。

## 剩余限制：反馈长尾

另做一轮关闭桌面观察器的诊断，其他优化保持开启：原生提交约 **54.054 次/秒**，仍有 **335.469 ms** 的反馈等待。约 24 秒有效提交区间里，等待上一帧反馈累计约 **1.992 秒**；开启观察器的 B1/B2 分别约 2.111 / 2.328 秒。

这单轮检查不支持“移除观察器就能达到 60 fps”的解释，也不能作为无观察器的重复性能基准。它没有桌面显示时延数据，不能用于证明两帧目标。等待时间可能与已经完成的编码重叠，不能简单从分母减掉来宣称一个假想 FPS。详细数据见 [remaining-waits.json](remaining-waits.json)。

此前 [socket 边界证据](../socket-boundary/README.md) 已定位到源发送调用完成后、接收端读到数据之前的每批 10 包间歇等待。还需区分 Tokio 接收就绪/任务唤醒与真正的系统收包调用；本轮没有更改网卡、注册表或 QUIC 拥塞控制。

## 校验与收尾

- 原生 CTest 7 项通过；分析脚本 7 项通过；Linux release 构建及 `git diff --check` 通过。
- 最新原生二进制的 3840×2400 GPU/CPU 路径均通过完整 alpha 像素、H.264 解码颜色、旧输出保留、只改最后一字节、过期后恢复和 tile 数量/尺寸切换校验。
- 强制可选 GPU 比较缓存分配失败，以及强制 alpha pinned 分配失败，均通过默认 1936×1732 原生集成测试。后者走 pageable 全量读回，并继续正确处理重复帧。
- AV1 sparse mode 1/2 新增两次相同帧的完整 alpha 比较；CPU/GPU 两种模式均通过，导出的 AV1、alpha、patch JSON、解码 RGBA 均逐字节一致。
- cache 更新后在 NVENC 之前/之后强制过期的场景仍恢复到正确 alpha，未削弱所有权、同步、身份或原有失败收尾。

四轮 A/B 和无观察器轮均 source=124（计划 timeout）、receiver=1（源端关闭）、watchdog=0；有观察器的轮次 observer=0。临时 HEADLESS 输出只承载自有 fixture，收尾时均移除，原有 monitors JSON 与测试前完全一致；隔离进程/任务为 0，fixture 规则停用。没有鼠标键盘注入、主动改变焦点或部署主运行版。

源码/测试/二进制哈希与完整测试日志同目录保存。[Windows 最终状态](windows-final-state.txt) 保留实际接收器/presenter 哈希。`summarize-trials.py` 从仓库根读取 `/tmp/viewflow-integrated-pair` 与 fixture 原始日志；可由保存的压缩日志重新展开复算。
