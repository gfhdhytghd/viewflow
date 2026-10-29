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
  2026-10-28 netem 修复后，manifest 到首个媒体块等待最多 250ms；
  首块前不请求整平面重传。随后以新接受的唯一块刷新无进展等待预算
  `clamp(2 × QUIC RTT + 帧周期, 8ms, 250ms)`，重复块不刷新。帧周期由相邻
  manifest 的源时间差估计（活动双 lane 除以 2，初始按 60Hz，估计限于
  1–33.3ms）。这是恢复启发式，不是会话时限。回报 `ExpiredUnbound` 后沿用
  源端的关键帧恢复逻辑，保留连接、控制读取和其他 lane。
- V3 暖启动通过可选 protobuf 字段 `AtlasSession.nack_version = 1` 双向协商。
  只有接受此能力才启动专用 NACK 流读取器；旧端忽略未知字段或返回 0 时不发
  NACK，不改变旧消息版本。接收端本地的丢帧恢复不依赖 NACK 能力。
- NACK 使用独立的小型 QUIC uni stream（`VFN1`，长度前缀 + `VFNA` 版本 1），
  与媒体、输入控制流和已有反向游标数据报读取器分开。每帧最多请求
  三轮（2026-10-28 netem 修复）；包含帧号、平面和缺失块索引（每包最多 512 个），整个平面未收到时
  请求该平面。在约一个 RTT 后检查缺块，在 RTT 恢复窗口内仍容得下一个
  RTT 时请求。2026-10-28 netem 修复移除了 33ms 呈现目标对 NACK 的限制；
  首次 NACK 后保留 `min(3 × RTT + 200ms, 1s)` 的控制流恢复时间；
  仍有缺块时最多三轮选择性请求。新唯一块刷新无进展等待，重复块不刷新。
  重试耗尽、无进展窗口过期或被替代后回退到关键帧。
- 源端缓存每 lane 最近两帧的两个平面，共享原有 `Bytes`，不复制媒体 payload，
  不增加逐块分配。仅发生丢包时构造缺块列表/重传去重表；每块最多修复三次，
  重传使用非等待排队，队列满时 Quinn 可以丢弃旧数据报。2026-10-28 起缓存使用
  现有发送操作的 5 秒看门狗窗口，不依赖呈现目标；新帧替代检查和
  每 lane 两帧上限继续限制缓存。完整帧在 NACK 唤醒前到达时没有额外网络写入。
  缺块观测也包含原始迟到；实际 clean 测试仍出现少量 NACK，见 netem 表格。
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

### W2 Linux 自适应码率与帧率（2026-10-27 已实现）

配置 `AtlasSourceConfig.quality_mode` 支持 `auto`（缺省）、`high_quality`、
`save_bandwidth`，拒绝拼写错误。Linux coded sender 对应
`--quality-mode auto|high_quality|save_bandwidth`。策略在启动时选择；桌面应用和 macOS 应用的"画质与网络"选项写入此字段
（仅非默认值），修改后重启发送端组件。

收敛：采样同时把 QUIC `udp_tx.bytes` 换算为实际发送速率 `send_kbps`。拥塞时目标
直接降到 `min(当前 × 0.85/0.7, 实际发送速率 × 0.9)`，因此 900 Mbps 的自动上限
在一步内收敛到无线链路的实际容量，而不是经历数十次乘性下降；链路持续 5 秒
无拥塞后升速从每秒 8% 提高到 30%，恢复更快。

- **Auto**：每个编码 lane 上限 900,000 kbps，干净链路保持上限；复用共享
  `RateController`，拥塞时降低码率，到 2,000 kbps 下限后降低帧率到 30/20。
  SaveBandwidth 同样自适应，但上限为 20,000 kbps（共享核心对省带宽模式取
  `min(上限/4, 20 Mbps)`，避免高有线上限的四分之一仍远超无线链路）。这个上限是编码质量上限，
  不是带宽预留或要求始终发送这么多数据；静止内容实际输出可以很低。
  两个活动 lane 各自允许完整画布的上限，不能把总上限平均分配而降低前台质量。
- **HighQuality**：保持以前的固定质量与原有捕获调度；GPU NVENC 仍为
  `constqp qp=10`，CPU NVENC 保持原来的默认颜色设置，VA-API 保持 CQP 10。
  网络观测不改变码率或前台帧率。900 Mbps 日志值代表自动策略的参考上限，
  HighQuality 本身没有新增加的码率限制。
- 独立 Tokio 定时任务每 200 ms 读取 QUIC `path.rtt`、累计 `lost_packets` /
  `sent_packets` 的饱和差值、两 lane 最老的未完成媒体发送年龄，以及
  `ExpiredUnbound` 累计差值。即使媒体所有者正在等待反馈，采样仍继续。
  coded 路径对应使用在途发送年龄和 REJECT 差值。每次目标变化及每 5 秒输出
  `atlas-quality` / `coded-quality` 一行。计数只需固定数量原子字段，没有新增
  逐帧分配、锁或系统调用；计时沿用 Linux 的单调时钟/vDSO。
- 码率更新在编码器所有者线程的帧边界执行；活动 lane 利用现有 batch command
  携带最新目标，不增加逐帧队列。捕获选择复用活动调度器的帧率字段，严重拥塞
  时也限制前台；单 lane 和 coded 在编码前丢弃不需要的捕获，保持输入/反馈处理。
  质量设置失败仅记录并保留当前编码器，不结束会话。
- GPU / CPU NVENC 的自动模式为 VBR + CQ 7，保持 p1、ULL、零 lookahead、零
  B-frame、按需 IDR。CQ 与 const-QP 不是同一个参数；采用更保守 CQ 7 保留
  原 QP 10 的质量余量。更新 `AVCodecContext.bit_rate` / `rc_max_rate` /
  `rc_buffer_size`，FFmpeg 在下一帧经 `NvEncReconfigureEncoder` 应用，
  不重开编码器。[FFmpeg 实现](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/nvenc.c)
  的 `reconfig_encoder` 只在非 constqp 且硬件支持动态码率时执行更新；本机
  H.264、AV1 的实测见下表。新增 C ABI 函数保留旧构造函数语义，内部可选 CUDA
  DSO 工厂从 v2 升为 v3，防止错载旧布局。
- VA-API 自动模式选择 VBR。码率变化合并为一个待处理目标，在下一次编码时
  创建替换编码器并强制其首帧 IDR；两次重建至少间隔 1 秒。准备失败保留旧实例，
  一秒后可重试。VA-API 硬件动态行为尚未在本 NVIDIA 主机验证。
- `transparency=false` 不再强制关闭 occlusion。根据内容 cutout 矩形标记
  opaque/empty/mixed cell，跳过 GPU alpha 分类读回；合成使用相同的矩形 alpha，
  部分边界保守保留。CUDA 原位 mask 不分配存储；VA-API 对已有 prepared RGBA
  写相同 mask。原有不可容纳的画布处理不变。

#### 测量与限制

主机：NVIDIA RTX PRO 6000 Blackwell Workstation Edition，驱动 615.78.08，
FFmpeg n9.0.2 / libavcodec 63.1.102。全部是**自有 EGL 纹理**，3840×2160、
60 fps 时间戳，滚动编辑器式字形、平色面板及移动渐变；不捕获桌面、不注入输入。
每段 120 帧，去掉前 30 帧后用 `bytes × 8 × 60 / 90 / 1000` 计算 kbps。
VBR 在**同一个对象**中依次使用 900,000 → 8,000 → 32,000 kbps，段首请求
IDR，均返回关键帧。测试检查低段与恢复段在目标的 0.5–2 倍范围内，并检查
恢复确实提高码率；VBR 不是严格逐帧上限。

| 编码器 | 原 QP 10（三段）kbps | VBR CQ 7 上限段 | 8,000 目标 | 32,000 目标 |
| --- | --- | --- | --- | --- |
| H.264 | 34,215 / 34,226 / 34,107 | 133,202 | 6,181 | 22,079 |
| AV1 | 48,819 / 49,261 / 49,105 | 293,121 | 4,129 | 26,604 |

另一个每帧改变字形的高运动压力纹理（不是普通滚动）在原 QP 10 下达到
H.264 708,779–709,001 kbps、AV1 288,110–288,220 kbps，因此选用 900 Mbps
保守上限，而不是任意 24/40 Mbps。早期 CQ 10 压力测试的 H.264 8 Mbps 段
实际 14.80 Mbps，超过当时 12 Mbps 断言；该失败保留在证据中，不能声称硬限流。
最终 CQ 7 滚动纹理通过；不能仅凭这些码率数字证明所有真实内容的主观画质、
PSNR 或端到端延迟无回退，实机视觉验收仍待用户操作。

复现：`cargo test -p viewflowd --features native-gpu-nvenc
owned_synthetic_bitrate_reconfiguration -- --ignored --nocapture`；只运行自有纹理
oracle，不运行需要真实捕获/输入的其他 ignored 测试。C ABI 另有
`owned_bitrate_cabi_reconfiguration` 验证两种 codec 的更新、IDR 和错误后继续。
固定 QP 基线可用 CMake target `viewflow-gpu-bitrate-test h264 fixed` / `av1 fixed`；
附加 `stress` 参数运行高运动压力纹理。
证据见 [Linux W2 验证记录](evidence/weak-network-w2-linux.txt)。

最终验证：`cargo test --workspace` 950 通过 / 4 忽略；
`cargo test -p viewflowd --features native-gpu-nvenc` 734 通过 / 15 忽略；
`cargo clippy --workspace --all-targets -- -D clippy::unwrap_used` 通过（保留既有
warning）。显式运行自有纹理 bitrate oracle 与自有空画布 C ABI oracle 各 1 通过；
矩形 mask C++ 测试通过。未运行需要真实桌面捕获或输入的 ignored 用例。

**缩放尚未启用**：适配层强制 `scale_permille=1000`，没有修改共享控制器。
当前 atlas patch 的源裁剪像素、编码画布像素与原生 presenter 的纹理尺寸直接
对应，`config_generation` 只能宣告新尺寸，不能表达两套坐标；直接缩小会造成
裁剪错误及输入位置偏差。后续应在 warmup 协商独立 `atlas_encode_scale_version`，
每 tile 同时传原始捕获像素范围和编码 texel 范围；保持输入的原始逻辑/捕获坐标，
native presenter 在独立源/目标矩形间采样放大。切换时先排空该 lane，发布新
codec descriptor + config_generation + 成对 IDR，收到确认才使用新尺寸；旧端
不接受该能力时始终保持 1000。必须分别验证 Windows/Mac 原生裁剪、阴影、
稀疏 patch、桌面跨屏与双 lane 切换后再启用。

本阶段未实现帧内刷新、参考失效编码、自动切换透明度、真实 Wi-Fi / netem
验收或应用设置 UI；未改动 Windows/macOS 编码器。没有新增会话结束条件、
33 ms 安全边界或输入授权限制。

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

## netem 实测（2026-10-28）

### 方法与复现

```sh
tools/weak-network-test.py
# 单个场景；cap20 会同时运行三种画质模式：
tools/weak-network-test.py --scenario cap20 --output /tmp/viewflow-cap20.txt
```

依赖：Linux `unshare`、`ip`、`tc`、Rust 工具链、FFmpeg 开发库和 NVENC 驱动。
不需要 sudo。脚本编译 `native-gpu-nvenc` 测试后，为每个场景新建
`unshare -rn` 私有网络命名空间；发送端、接收端均在其中的 `127.0.0.1`。
只修改该空间内的 `lo`。空间退出时内核销毁 qdisc；超时时脚本终止自己的整个
进程组。没有修改宿主网络，没有捕获桌面，没有注入输入或改变焦点。

完整 atlas 源依赖真实捕获，故采用 `cfg(test)` 的忽略测试
`atlas_session::netem_test::owned_netem_session`：预生成自有滚动字形/渐变画面，
1920×1080、60fps 名义提交；CPU RGBA 经现有 NVENC C ABI 上传编码 H.264，
不重放预编码片段。静态不透明 alpha 使用现有 lossless RLE 与 alpha 引用。
编码器在帧边界应用真实 `QualityMonitor` 的目标码率，并响应丢帧后的 IDR 请求。
每组先在干净回环上完成真实 TLS/atlas V3 暖启动，再施加网络条件并测量至少
30 秒。因此测量也包含从干净网络突然切入弱网的恢复，并非稳态 Wi-Fi 启动测试。

接收端调用真实 `next_frame`，包含 QUIC 数据报、manifest、分片重组、codec
admission、NACK/重传、关键帧回退和 disposition 反馈。完整重组后回报
`Committed`，仅模拟呈现完成；**没有解码、原生呈现或物理显示**。
单 lane 的真实 stop-and-wait 反馈与策略降帧会降低实际帧率，不能把名义 60fps
当作测得帧率。自动化没有调用真实输入 API。

场景：clean；wifi1 为 `delay 5ms 3ms loss 1%`；wifi5 为
`delay 15ms 10ms loss 5%`；cap20 为 `delay 10ms rate 20mbit`；cap8 为
`rate 8mbit loss 2%`。均使用 `netem limit 1000`，回环的两个方向共享整形。
burst 在测量第 10 秒切入 `loss 30%`，第 20 秒恢复干净，第 30 秒结束。
netem 的 seed、排队统计、机器版本、源文件与测试可执行文件 SHA256 均保存在原始证据。
随机 seed、线程调度与 GPU 负载会影响重复测量，不把单次结果当作统计置信区间。

计数与时间定义：

- sent 是提交给真实 `send_frame` 的帧；complete 是重组并通过 admission 的帧。
  lost 是接收端回报关键帧回退的帧。没有测量 presented。
- KF 不含启动 IDR，只计恢复关键帧请求；NACK 是请求记录数；repair 是成功排入
  Quinn 队列的修复数据报数，不证明这些数据报实际到达，也不证明原始包没有迟到。
- 延迟从 sender 提交前的同主机单调时钟，到 receiver 完整 admission 为止，
  包含画面复制、编码和传输。p50/p95/p99 只覆盖成功重组的帧；没有完整帧时无延迟样本。
- stall 是相邻完整帧之间超过 100ms 的间隔，包含初始等待和末尾等待。
  原始 JSON 保存每段时长。丢帧不以零延迟填入分位数。
- `chunks_lost_lower_bound` 是按轮累加的缺块观测次数下界；同一缺块可以重复计数，
  不能把该字段解释为唯一丢失块数或物理网络丢包数。
- UDP Mbps 使用源端 `udp_tx.bytes` 差值，包含协议和修复流量，属于 Quinn 的发送计数，
  不是 NIC 交付证明。complete Mbps 使用 admission 后的逻辑编码字节，包含 alpha
  引用展开，不能当作线路净吞吐。内核 qdisc 的实际发送/丢包计数另见原始日志。
- 每 200ms 独立采样目标 kbps/FPS。stable s 是首次连续 2 秒处在最后 5 秒目标中位数
  ±20% 内的起点；burst 从恢复网络的第 20 秒重新计时。它是本实验的收敛定义，
  不表示目标等于链路容量，也不表示整个后续过程没有探测波动。
- HighQuality 沿用原固定质量编码配置；日志中的 900000 是策略参考值，
  不是新施加给编码器的码率上限。

### 30 秒结果

8/8 会话持续运行；每组都有完整帧。错误字段均为 null。以下延迟不是显示延迟。

| 场景/模式 | 提交/完整/丢帧 | KF/NACK/repair | 内核/UDP/逻辑 Mbps | p50/p95/p99 ms | >100ms 卡顿数 | 目标起/末 kbps | stable s |
|---|---|---|---|---|---|---|---|
| clean/auto | 1794/1794/0 | 0/9/144 | 157.80/151.85/158.59 | 9.5/12.0/13.8 | 0 | 900000/900000 | 0.001 |
| wifi1/auto | 437/435/2 | 2/459/5131 | 6.96/6.69/8.31 | 53.5/115.8/180.9 | 52 | 900000/2000 | 0.802 |
| wifi5/auto | 140/139/1 | 1/159/2232 | 2.52/2.53/2.79 | 147.9/536.1/630.9 | 110 | 900000/2000 | 1.201 |
| cap20/auto | 562/561/1 | 1/3/719 | 10.29/9.88/13.83 | 18.0/161.4/171.2 | 86 | 900000/8359 | 10.602 |
| cap8/auto | 491/489/2 | 2/377/5012 | 6.71/6.57/8.90 | 50.3/86.7/228.3 | 30 | 900000/2000 | 5.201 |
| burst/auto | 855/852/3 | 3/52/705 | 55.44/53.52/57.42 | 9.0/11.9/382.2 | 14 | 900000/2000 | 0.026 |
| cap20/high_quality | 679/679/0 | 0/2/67 | 8.28/7.92/13.26 | 32.4/35.0/35.8 | 0 | 900000/900000 | 0.001 |
| cap20/save_bandwidth | 606/606/0 | 0/2/120 | 9.48/9.09/13.72 | 19.2/161.0/170.9 | 72 | 20000/8000 | 15.001 |

内核 Mbps 是该私有 qdisc 的 `Sent` 字节除以测量时长，包含双向控制与协议流量，
以及微量退出收尾流量。它与 UDP/逻辑字节使用不同统计位置。

- clean 实际约 59.8fps，无丢帧、无 >100ms 卡顿；初测为 59.7fps、
  p95 12.7ms，最终 p95 12.0ms。没有观察到本合成负载的干净链路回退；
  初测曾与编译重叠，因此不是严格隔离的 A/B 性能证明。
- wifi5 仍有明显时延：p95 536.1ms，最长卡顿 904.1ms。会话与完整帧恢复
  不代表达到 33ms 目标，也不代表真实 Wi-Fi 视觉验收通过。
- cap20 的 Auto 在约 7.5–9.1Mbps 目标带内继续做有界探测，
  SaveBandwidth 也有周期波动；stable 不是无波动承诺。
  本负载下 HighQuality 的 p95 更低，但其固定编码质量与 Auto 的 CQ/VBR 配置不同，
  不能据此推断同画质的普遍优劣或 20Mbps 链路满载效率。
- burst 的三个 10 秒完整帧数为 598/21/233；恢复网络后 148.5ms 收到首帧。
  30 秒结束时目标仍为 2000kbps/30fps，画面恢复快于质量阶梯恢复。

另以相同 burst 切换、不同 seed 运行 75 秒，验证较慢的目标恢复：
完整帧 3439/3443，丢帧 4；网络恢复后 82.6ms 出现首个完整帧，
12.8 秒恢复到 60fps 目标，37.6 秒恢复到 900000kbps 目标。
这是策略目标恢复，不是解码画质或用户体验证明。
它解释了 30 秒测量为何只能看到画面恢复与部分 FPS 恢复。
原始轨迹见 [75 秒恢复观察](evidence/weak-network-netem-recovery.txt)。

### 问题与修复

全部改动保持连接、输入所有者与其他 lane；没有新增会话退出条件。
生产热路径没有新增逐帧分配或锁。测试与计数注入均放在 `cfg(test)`。

| 问题 | 修复 | 前后证据 |
|---|---|---|
| `atlas_session.rs:1011`：PMTU 在分片后缩小，`TooLarge` 使发送端中止 | 当前帧停止排入，保留 feedback 等待及 IDR 回退 | 初测 wifi1 首帧在 0.0167s 中止；最终持续 30s，435/437 帧完整 |
| `atlas_session.rs:1739`：33ms 目标同时截断 NACK 和发送缓存 | 恢复使用 RTT/无进展窗口与现有发送看门狗；不重写源时间戳 | 初测 wifi5 0/72 完整；最终 139/140；另有超过目标的真实 NACK 回归 |
| `atlas_session.rs:1913`：完整平面的重复修复块产生 `StaleFrame`，连带放弃另一平面 | 忽略当前已完整平面的重复块 | 诊断 frame 2 出现一次该错误；新增重复 alpha 后继续 color 的配对回归通过 |
| `atlas_session.rs:1921`、`atlas_loss.rs:61`、`reassembly.rs:111`：manifest 越过排队媒体，初始等待过早到期；传输进展没有延长等待 | 首块前等待；唯一新块刷新无进展计时，重复块不刷新 | 中间版本 wifi1 0/312 完整；最终 435/437；慢速分块跨原始窗口的回归通过 |
| `atlas_loss.rs:72`：一轮重传与一个 RTT 不能覆盖丢失的可靠 NACK/PTO 或修复块 | 最多三轮，逐块最多三次；每轮等待可靠控制恢复，耗尽后局部丢帧 | 单轮版本 wifi5 0/79；最终 139/140；三轮上限回归通过 |
| `Cargo.lock:922`：Quinn 修复队列挤出时重复扣减字节计数 | `Cargo.lock` 的 quinn-proto 0.11.17 → 0.11.19 | 原诊断退出 134；4096 次排队挤出并继续接收 marker 的回归通过；最终 8 组无进程崩溃 |

位置：`crates/viewflowd/src/atlas_session.rs`（发送、接收、回归测试）、
`crates/viewflowd/src/atlas_loss.rs`（进展/重试/缓存）、
`crates/viewflow-transport/src/reassembly.rs`（O(1) 唯一块查询）、`Cargo.lock`。
上游队列修复可核对 [quinn-proto 0.11.19 数据报实现](https://github.com/quinn-rs/quinn/blob/quinn-proto-0.11.19/quinn-proto/src/connection/datagrams.rs)。

上述链路数字是累积修复前后的观测，seed 与调度不同，不用于分摊单项修复的效果。
各独立回归检查对应触发条件。不可修复帧用例从 80ms 等待改为 1s，覆盖三轮有界恢复；
仍断言反馈到达、staged 清空、会话没有退役。不是把 33ms 改为退出门槛。

原始记录：[最终 8 组](evidence/weak-network-netem.txt)、
[初测、失败与中间版本](evidence/weak-network-netem-before.txt)。

### 回归检查

- `cargo test --workspace`：965 通过、0 失败、4 忽略。
- `cargo test -p viewflowd --features native-gpu-nvenc`：746 通过、0 失败、16 忽略。
- `cargo clippy --workspace --all-targets -- -D clippy::unwrap_used`：退出 0；保留既有告警。
- 最终 8 组及 75 秒补测：场景数、存活、完整帧、时长、帧计数守恒与源 SHA256 检查通过。
- 宿主 `lo` 仍为 `noqueue`；没有残留本测试进程。没有运行真实桌面/输入的忽略测试。

摘要与六项新增回归见 [最终检查](evidence/weak-network-netem-checks.txt)。

### 未覆盖

- Windows/macOS 源、真实 Wi-Fi、异步跨主机时钟与真实输入。
- 解码正确性、视觉质量、原生呈现、显示延迟、用户验收。
- GPU atlas 的 DMA-BUF/纹理合成导入、双 lane 的 netem 实测、VA-API 与 AV1。
  本次仅走 CPU-owned RGBA 上传到硬件 H.264 NVENC；现有普通测试另覆盖双 lane。
- 多次重复的统计置信区间、长时间浸泡和全内容性能回归。
