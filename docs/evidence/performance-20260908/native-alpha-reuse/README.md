# Windows alpha：复用已解压快照及其派生结果

2026-09-08。源端固定为上一轮消除 C ABI alpha 复制后的相同 Release 二进制。Windows 使用同一个原生二进制，`VIEWFLOW_NATIVE_ALPHA_REUSE=0` 为原有展开/比较路径，默认启用共享复用。四轮交错，各 25 秒；无 WPR 录制，保留同一 observer 与诊断配置。

## 已验证的结果

单位 ms，每个值为该轮分布中位数。capture→mutation 与 capture→所见桌面采用校准后的时钟上界；“所见桌面”并非可靠的首次显示或光子时间。

| 轮次 | alpha 纹理准备 host | capture→应用 mutation | capture→所见桌面 | 原生 committed 次/秒 |
|---|---:|---:|---:|---:|
| A1 原有路径 | 1.224 | 26.436 | 64.125 | 50.821 |
| B1 共享复用 | 0.007 | 17.292 | 58.946 | 51.016 |
| A2 原有路径 | 1.276 | 27.218 | 64.269 | 52.735 |
| B2 共享复用 | 0.007 | 17.480 | 59.484 | 52.193 |

两组 capture→mutation 减少约 9.1–9.7 ms，capture→所见桌面减少约 4.8–5.2 ms。B1/B2 分别有 1240/1241、1254/1255 条 atlas alpha 记录命中已解压快照；只在初次 atlas alpha 到来时展开。A1/A2 命中为零，模式和源端版本均已从运行日志核实。

第一组 encoded→pipe admission 中位从 7.02 降至 2.70 ms，pipe admission→decoded 从 4.63 降至 1.51 ms；这些阶段分别包括多个操作，不能把整个差值全称作 RLE 解压成本。各阶段独立中位数不能直接相加。源端的少量运行变化也影响总跨度。[完整对照统计](comparison.json)

**4K60 / 两帧以内仍未达标。** committed 仅约 51–53 次/秒，且不是实际显示 FPS。提交到所见桌面仍有约 38 ms 中位等待，observer 仍可能漏观首次出现并干扰 GPU。

## 数据所有权与失效规则

- Parser 比较完整编码 alpha 字节、宽高和记录版本；仅与已成功解码的上一快照完全相同时复用。变化数据仍经原有验证和解码流程。
- `Frame.shared_alpha` 持有不可变缓冲区。每帧的 identity、layout、deadline、color AU 保持独立；异步 MTA 解码持有对应帧的共享所有权。
- GPU alpha cache 保留不可变 owner 与 COM 纹理。相同 owner/尺寸可跳过全量比较；不同 owner 仍比较精确字节或重建纹理。已提交帧继续持有自己的 COM 引用，新的 alpha 不覆盖旧帧纹理。
- 透明区域判断只在 alpha owner、画布尺寸和 patch 布局均相同时复用；变化时重新计算包含采样 halo 的原有判断。
- 保留一个最新编码 alpha 和解码快照缓存；未处理完的帧通过共享引用保留各自版本。不新增线协议引用，不靠时间、focus 或安全阈值判定缓存有效性。

## 正确性验证

Windows Release 构建通过，重新构建并运行的 10 项原生 CPU 测试全部通过，覆盖 VFGP 各版本、拒绝损坏输入、旧 alpha buffer 回收、帧绑定与 opaque 判断。新增案例覆盖碎片化输入、重复内容、透明度变化、相同面积但尺寸变化、错误尺寸/损坏 run、parser 销毁后仍持有旧帧，以及相同 alpha 但 patch/尺寸变化时不错误复用透明区域判断。[测试日志](windows-parser-tests.log)

真实 Windows D3D11/MF GPU 测试：256×256 的逐帧变化及重复→变化两组，最后保留三帧一起逐像素读回验证；3840×2400 另做相同→相同→变化的三帧测试，全部 9,216,000 个 alpha 像素逐帧与预期完全一致。观察到重复帧复用纹理，变化帧创建新纹理。[256 测试](windows-gpu-256-tests.log)、[4K 测试](windows-gpu-4k-test.log)

4K GPU oracle 的颜色用 FFmpeg h264_nvenc 生成三条独立 I 帧，alpha 为覆盖 0–255 的人工序列，前两帧相同、第三帧偏移 17。它验证 alpha GPU 结果与保留帧生命周期，不被解释为用户操作或物理显示验证。该 oracle 在四轮性能对照全部结束后运行。

四轮 source 均由计划的 25 秒 timeout 收尾；receiver 为 peer close（exit 1），watchdog=0，observer=0，独立进程和任务清理成功。测试窗口规则恢复为停用。当前桌面部署未替换。

## 新暴露的长尾

B2 fixture 生产约 60.001 帧/秒，但有效 capture marker 约 53.470 次/秒；capture 间隔中位 16.678 ms，最大 366.791 ms。通过 exact frame ID 关联发现：

- frame 906：编码约 10.10 ms；encoded→pipe admission **362.48 ms**；原生 admission→committed 约 2.19 ms。source 的 frame 907 在等待它的前一帧反馈时停了 351.22 ms。
- frame 210：encoded→pipe admission **223.31 ms**。
- frame 1064：encode host **239.62 ms**，与前一类属于不同位置的停顿。

因此下一轮应同时明确传输进入原生 pipe 前的长尾位置和 GPU/编码内部的长尾阶段。现有证据不能把前者全部归因于网络丢包，也不能把后者直接称作 NVENC 硬件耗时。需要发送/接收分段时刻与 QUIC 状态，以及长编码帧的 GPU 子阶段日志，随后再选择修复。

原始压缩日志、逐轮 clock/alpha/desktop 统计随本目录保存；[源码哈希](source-sha256.json) 记录本轮实现。性能数据基于单台 Linux→Windows QEMU/Intel GPU 环境，未外推到 macOS 或不同显示配置。
