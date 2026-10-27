# 弱网（Wi-Fi）支持方案

2026-10-27 用户要求支持 Wi-Fi 等弱网环境：丢包、抖动和带宽波动时降低画质，
保持会话可用。本方案遵循[安全与可用性指导原则](security-and-availability-policy.md)：
弱网是正常使用，不能成为断开会话或销毁代理窗口的理由；33ms 仍是性能目标，
错过时降级和局部恢复。

## 现状（2026-10-27 调研）

- 码率固定：Linux GPU NVENC/VA-API 为 `constqp`/CQP，QP 10；CPU 路径 NVENC
  未设码控；Windows VPL 为 CBR 24 Mbps，MFT 为 24 Mbps 平均码率；macOS
  VideoToolbox 平均码率 24–80 Mbps。运行中都不调整，只在画布变大时重建编码器。
- 媒体走 QUIC 数据报，单帧切成多个块；无 FEC、无 NACK、无重传。丢一个块即丢
  整个平面。
- atlas 主路径的接收端在缺块时一直等待：发送端等待处置回执约 5 秒后报错，
  会话结束。这是弱网下最严重的可用性缺口。
- coded 路径缺块时接收端回 REJECT，发送端请求 IDR；IDR 体积大，在弱网上会
  加重拥塞。
- QUIC 使用 quinn 默认 Cubic；`connection.stats()`（RTT、丢包、拥塞窗口）只在
  调试变量打开时写日志，不参与任何决策。
- 已有的拥塞响应只降低后台窗口帧率（30/15/5），前台窗口、分辨率和码率不变。
- 应用里没有画质或网络相关设置。

## 分阶段方案

### W1 丢包不致命（2026-10-27 已实现）

- atlas 接收端为每个活动 lane 单独保存缺块等待状态。后续同 lane 的数据报或
  manifest 到达时，立即放弃旧的不完整帧；没有后续流量时也会唤醒恢复定时器。
  等待预算为 `clamp(2 × QUIC RTT + 帧周期, 8ms, 250ms)`；帧周期由相邻
  manifest 的源时间差估计（活动双 lane 除以 2，初始按 60Hz，估计限于
  1–33.3ms）。这是恢复启发式，不是会话时限。回报 `ExpiredUnbound` 后沿用
  源端的关键帧恢复逻辑，保留连接、控制读取和其他 lane。
- V3 暖启动通过可选 protobuf 字段 `AtlasSession.nack_version = 1` 双向协商。
  只有接受此能力才启动专用 NACK 流读取器；旧端忽略未知字段或返回 0 时不发
  NACK，不改变旧消息版本。接收端本地的丢帧恢复不依赖 NACK 能力。
- NACK 使用独立的小型 QUIC uni stream（`VFN1`，长度前缀 + `VFNA` 版本 1），
  与媒体、输入控制流和已有反向游标数据报读取器分开。每帧只请求
  一轮；包含帧号、平面和缺失块索引（每包最多 512 个），整个平面未收到时
  请求该平面。在约一个 RTT 后检查缺块，只在剩余呈现目标内还容得下一个
  RTT 时请求；超过目标、过期或被替代即停止重传并回退到关键帧。
- 源端缓存每 lane 最近两帧的两个平面，共享原有 `Bytes`，不复制媒体 payload，
  不增加逐块分配。仅发生丢包时构造缺块列表/重传去重表；每块最多修复一次，
  拥塞时立即丢弃无法排入的数据报。无丢包时没有 NACK 往返或额外网络写入。
- `LossTelemetry` 集中记录已观察缺块数、NACK 修复帧、关键帧回退帧、NACK
  请求数、成功修复往返及累计耗时，并采样 QUIC RTT/丢包累计值。活动接收循环
  每 5 秒输出一条 `atlas-loss` 摘要。整个平面完全未到时无法知道块数，缺块数
  暂按至少 1 块计，因此它是观测下界；QUIC 丢包数也不是媒体缺块数。NACK
  修复帧指请求后完成的帧，不能单凭此计数区分重传与原始迟到数据报。
- 发送端原有长处置等待继续只作为无进展看门狗；没有新增会话终止定时器。
  FEC **未实现**，留待后续阶段，不能将本次选择性重传当作纠删码支持。

验证：测试在发送数据报路径确定性丢弃指定块，覆盖无丢包无 NACK、单块修复、
连续三帧无法修复后关键帧继续、普通/活动双 lane、同 lane 新数据或 manifest
替代旧帧、V3 新旧能力双向兼容。回归测试在原实现上复现：丢一个颜色块及整个
alpha 平面后，80ms 等待结束仍保留 staged 帧且无处置回执。本次接收端在恢复
预算内回报丢帧。本机最终检查：`cargo test --workspace` 938 通过、4 忽略；
`cargo clippy --workspace --all-targets -- -D clippy::unwrap_used` 通过；
`cargo test -p viewflowd --features native-gpu-nvenc` 727 通过、13 忽略。
自动化不注入真实鼠标/键盘。实机 Wi-Fi、`tc netem`、吞吐与视觉体验尚未验证。

### W2 自适应码率与画质

1. 码率控制器：输入 QUIC RTT/丢包/拥塞窗口、发送队列年龄、处置回执延迟；
   AIMD 式调整目标码率，下限保证可用、上限为当前固定画质。
2. 编码器改为可运行时调整码率的码控：NVENC 由 `constqp` 改为 VBR/CBR 并在
   帧间更新码率；Windows VPL 用 `Reset`，MFT 设置 `CODECAPI_AVEncCommonMeanBitRate`；
   macOS 设置 `AverageBitRate`；VA-API 在关键帧处重建。
3. 码率降到下限仍拥塞时，依次降低前台帧率、缩小编码分辨率（沿用
   `config_generation` + 关键帧，接收端放大），并可关闭透明度（见透明度
   可选功能）。网络恢复后按相反顺序逐级回升。
4. 弱网下用帧内刷新或参考帧失效替代整帧 IDR，避免恢复时的码率尖峰。

#### W2 原生 Windows / macOS 源端（2026-10-27）

本次实现限于原生窗口源；Linux 编码器与 atlas 源由独立工作项负责。
`vf-window-peer` 在拥有 QUIC 连接的 Rust 桥接层每 200ms 调用共享
`RateController`。输入为 `connection.stats()` 的 RTT、发送/丢包计数差值，
以及现有 24 字节反馈中的队列年龄、饱和标志、关键帧请求次数。饱和标志
按至少 100ms 排队信号传入；拥塞窗口只记入日志，不伪造成丢包计数。
控制同时覆盖 activity 双 lane 和未协商 activity 的单流；后者没有接收端
队列反馈时仍使用 QUIC 统计。所有变化只降低/恢复质量，不增加会话退出条件。

- 配置：`vf-window-peer` 顶层 `quality_mode` 接受 `auto`、`high_quality`、
  `save_bandwidth`。未显式配置时读取 macOS 应用继承的
  `VIEWFLOW_QUALITY_MODE`（同样三个值；未设置/未知值为 `auto`）。显式 JSON
  优先于环境变量。UI 在独立工作项中实现。
- 能力：沿用现有独立能力探测方式，启动原生程序
  `--quality-capabilities`，读取一行 `native-quality-v1 max_kbps=24000 max_fps=60`
  （macOS `max_kbps=80000`）。不修改旧 `--activity-priority-capabilities` 的
  严格输出，也不把文本混入正常二进制 stdout。探测失败/旧程序不支持时，
  Rust 不发送任何新记录。
- 本地 stdin 记录：4 字节小端长度 `20`，随后五个小端 `u32`：
  `tag=7, version=1, kbps, max_fps, scale_permille`。它只存在于 Rust 与本地
  子进程之间，绝不转发到远端 QUIC；现有 tag 5 的 24 字节反馈完全不变。
  新 Rust + 旧原生继续旧行为；旧 Rust + 新原生没有 tag 7，保持固定码率与
  旧帧率调度。新 Rust 的 `high_quality` 也不发质量覆盖记录，保留旧调度。
- Windows VPL：保留原有 CBR 24Mbps 上限，等待已提交工作输出后调用
  `MFXVideoENCODE_Reset`，携带当前 HEVC tiles 与
  `mfxExtEncoderResetOption::StartNewSequence=OFF`；不主动请求 IDR。
  MFT 初始化显式设置 CBR，运行时以 `ICodecAPI::SetValue` 更新平均/最大码率。
  不支持的属性/Reset 失败记录实际状态，保留现有编码器，不因此断流。
  API 依据：[VPL Reset](https://intel.github.io/libvpl/latest/API_ref/VPL_func_vid_encode.html)、
  [MFT 码率属性](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-encoder)。
- macOS VideoToolbox：在编码器串行工作线程上更新 `AverageBitRate` 和
  `DataRateLimits`（字节/1 秒）。每个画布仍以
  `clamp(width*height*fps/8, 24Mbps, 80Mbps)` 为上限；Rust 使用 80Mbps 全局
  上界，小画布在原生端夹紧，所以初期降码率可能先落在画布上限以上。
  分辨率改变重建 session 后重新应用目标。
  [VideoToolbox 平均码率](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate)
  是目标而非实际码率保证；不支持的属性会记录 OSStatus，
  不因此结束流。Windows/macOS 目标帧率均叠加到现有节奏，包含前台 lane。
- `scale_permille` 已编码、校验和日志化，**尚不改变分辨率**；透明度降级、
  帧内刷新也不在本次实现中。原生编码器属性是否生效仍依赖平台驱动。
- Rust 与原生端输出 `native-quality target` 变化记录与约 5 秒摘要，包含
  请求目标；编码器另记实际夹紧值及 API 返回状态。HighQuality 无原生质量
  覆盖，因此仅 Rust 记录质量摘要。日志不逐帧输出。

验证：新增 Rust 测试覆盖三种配置、默认模式、能力解析与旧端不接收新记录、
控制器目标编码、QUIC 计数差值、反馈样本、跨定时器的分片记录，以及
HighQuality 原样转发。共享 C++ 测试覆盖 tag/version/长度/范围校验与
Windows/macOS 码率参数映射，已接入双方 CMake。Windows/macOS 完整编译、
驱动属性生效、真实 Wi-Fi 的码率/FPS/画质恢复均 **未验证**；不把 Linux 上的
便携测试当作原生平台验收，也不自动注入鼠标/键盘或改变焦点。

本机最终结果：`cargo test --workspace` **951 通过、4 忽略**；
`cargo clippy --workspace --all-targets -- -D clippy::unwrap_used` 退出 0
（仓库既有告警仍存在）。便携 C++ 用 `g++ -std=c++20 -pthread -UNDEBUG
-Wall -Wextra` 编译运行 **41 通过**，其中新质量控制测试及另 39 项还通过
`-Werror`；`async_trace_test.cpp:27` 有既有缩进告警，未修改该无关测试。
另 5 项依赖 Windows 头文件，Linux 无法编译，未计为通过。首次工作区回归
暴露了新增管道持有 stdin 导致的 5 项 EOF 清理失败；已修复为旧原生/呈现端
直通、质量源端显式关闭并释放 writer，最终 6 项桥接集成测试全部通过，包含
有/无 activity、质量记录、重启及 EOF 清理。原始失败和最终日志保存在本机
`/tmp/abr-workspace-test.log`、`/tmp/abr-workspace-final.log`、
`/tmp/abr-clippy-final.log`、`/tmp/abr-portable-tests/`。

### W3 传输与可见性

1. 评估 quinn 的 BBR 拥塞控制：Cubic 把 Wi-Fi 随机丢包当作拥塞，会过度降速。
2. 应用里提供"画质/网络"选项：自动（默认）、有线高画质、省带宽；显示当前
   网络质量与实际码率。
3. `viewflowd doctor` 增加链路检查：是否为无线网卡、往返时延与丢包率。

## 验收

- 用 `tc netem` 在本机回环或测试网卡上模拟 1%/5% 丢包、20ms 抖动、10/5 Mbps
  带宽，会话持续，画面在数秒内恢复，日志记录降级与恢复。
- 有线网络下画质、延迟与当前版本相比无回退（无丢包时 FEC 比例为 0、码率
  上限等于原固定画质）。
- 实机 Wi-Fi 体验由用户验收；自动化测试不注入真实输入。
