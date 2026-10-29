# 弱网（Wi-Fi）支持方案

2026-10-27 用户要求支持 Wi-Fi 等弱网环境：丢包、抖动和带宽波动时降低画质，
保持会话可用。本方案遵循[安全与可用性指导原则](security-and-availability-policy.md)：
弱网是正常使用，不能成为断开会话或销毁代理窗口的理由；33ms 仍是性能目标，
错过时降级和局部恢复。

协议源码对照与后续参数建议见 [Moonlight / Sunshine 视频传输对比](moonlight-comparison.md)。
下节保留 W1/W2 之前的调研基线；当前实现见对应阶段记录。

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
  不增加逐块分配。仅发生丢包时构造缺块列表/重传去重表；每块最多修复三次。
  quinn 缓冲满时会淘汰旧待发数据报，所以修复发送前先检查
  `datagram_send_buffer_space()`，空间不足时跳过修复，不挤掉其他待发媒体；
  多任务并发时检查与入队之间的竞态仍需统一发送仲裁，见
  [源码对比](moonlight-comparison.md#3-fec重组队列与不可恢复判定)。
  2026-10-28 起缓存使用现有发送操作的 5 秒看门狗窗口，不依赖呈现目标；新帧
  替代检查和每 lane 两帧上限继续限制缓存。完整帧在 NACK 唤醒前到达时没有额外
  网络写入。缺块观测也包含原始迟到；实际 clean 测试仍出现少量 NACK，见 netem 表格。
- `LossTelemetry` 集中记录已观察缺块数、NACK 修复帧、关键帧回退帧、NACK
  请求数、成功修复往返及累计耗时，并采样 QUIC RTT/丢包累计值。活动接收循环
  每 5 秒输出一条 `atlas-loss` 摘要。整个平面完全未到时无法知道块数，缺块数
  暂按至少 1 块计，因此它是观测下界；QUIC 丢包数也不是媒体缺块数。NACK
  修复帧指请求后完成的帧，不能单凭此计数区分重传与原始迟到数据报。
- 2026-10-29 突发丢包补测进一步修正 atlas 发送等待：原始媒体入队遇到反压时
  等待 Quinn 的连接结果；不再因帧内 5 秒计时结束会话。精确处置回执使用原来的
  同一个读取 future，超过 5 秒只记录等待，保留部分读取进度，直到回执、流错误或
  真实连接关闭。活动 lane 的 ticket 等待采用相同规则；控制流所有者和其他 lane 不变。
  可靠 manifest 写入、对端本地呈现/管道的资源看门狗、QUIC 的连接失联检查仍保留。
  发送修复缓存仍保留 5 秒和每 lane 两帧的内存上限；缓存过期后不再修复该旧帧。
  没有新增会话终止定时器。
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

2026-10-29 ABR 修订（netem 的修复前/后记录见下节）：

- RTT 基线采用固定 11 个一秒桶，取最近约 10 秒的最小值，旧暖启动值会过期。
  三点中位数再经 1/4 EWMA 平滑；膨胀必须同时超过基线的 1.5 倍和基线加 15ms。
  单个 RTT 抖动、恢复丢帧或随机丢包计数不独立触发降级。
- `queue_age_us` 只表示原始媒体入队期间的年龄与 Quinn 数据报缓冲的预计排空时间
  的较大值。后者为当前缓冲字节 / 最近采样的发送字节速率；它是估计值，不是 NIC
  的实测队列时间。GPU 预编码等待、处置回执和 NACK 等待不再直接计入队列年龄。
- 真实积压与 RTT 膨胀同时出现时降低目标；RTT 平稳但原始帧服务受积压限制时，
  只按发送服务预算调整。Linux 已知原始发送代次时，服务帧率低于上述 RTT 修正
  门槛且积压超过一个名义帧周期就调整预算；完整帧率下的瞬时高峰不触发降级。
  没有发送代次的原生桥接保留四帧门槛。这些都是延迟调参目标，不是截止期限
  或断流条件。
  有持续发送积压的 RTT 拥塞时，目标取
  `min(当前 × 0.85/0.7, 发送速率 × 0.9)`；
  只有整个速率区间的 10ms 观测点都有实际待发数据时，才把墙钟速率用于该夹紧；
  某一瞬间刚产生的积压不能把之前的回执空闲时间当作链路容量。
  部分区间受应用帧率限制时改用下述帧预算，不反复乘性下降。
  10% 丢包只选择乘数，不再单独证明拥塞。
- 停止等待会让墙钟发送速率低于编码器的名义码率。RTT 平稳或区间含发送空闲，
  且原始发送帧率低于名义帧率时，预算取 `发送 kbps × 名义 fps / 实际原始发送 fps × 0.6`，
  并且只向下夹紧当前目标，不反复乘 0.85。保留 40% 服务余量用于回执和选择性修复。
  这是合成网络实验的调参选择，不是无线链路容量的无偏估计，也不是协议保证。
- 同一原始媒体发送代次最多降一次，等待新的原始帧开始后再判断；目标仍在
  编码器所有者的帧边界应用。没有新帧的
  采样不把低发送速率当作容量。Linux 的下限帧率阶梯同样等待新的原始发送代次，
  不因同一旧帧的修复等待连续降至 30/20fps。原生桥接没有此代次观测，使用 0 表示未知。
- Quinn 缓冲和原始入队年龄每 10ms 观测一次，控制器每 200ms 消费区间峰值。
  单独每 200ms 观察瞬时值会与停止等待周期混叠，漏掉发送高峰。
  原始帧持续产生时，平滑 RTT 比基线高 60ms 也允许乘性下降，覆盖 Quinn 之后的
  内核/AP 排队；没有本地积压时不以墙钟发送速率夹紧目标。
- 无积压且原始帧服务达到 `0.8 × min(当前目标 fps, 1 / (基础 RTT + 半个目标帧周期))` 后，沿用每秒 8%
  升速，连续 5 秒后升至 30%。基础 RTT 来自上述窗口最小值；80% 是采样容差。
  停止等待的空缓冲不再独立证明容量充裕；基础 RTT 为 20–40ms 时也不会因
  无法达到名义 60fps 而永久冻结质量恢复。不改变捕获帧率或输入许可。
  没有增加会话终止条件。

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
  `sent_packets` 的饱和差值、两 lane 原始媒体入队年龄的区间峰值、Quinn 缓冲
  字节的区间峰值（峰值每 10ms 观测），以及
  `ExpiredUnbound` 累计差值。即使媒体所有者正在等待反馈，采样仍继续。
  coded 路径也在媒体入队结束时清除发送年龄，再等待 REJECT/ACK。每次目标变化及每 5 秒输出
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
  不重开编码器。2026-10-29 将 CPU/GPU NVENC 的 VBR 缓冲从一秒码率改为一帧
  （编码器名义时钟固定 60fps，因此为 `kbps × 1000 / 60` bit）。原先一秒的
  VBV 允许目标变化后继续产生大帧，停止等待与恢复会放大其排空成本。
  HighQuality 的固定质量配置没有此 VBR 设置；颜色 CQ 仍为 7，alpha 保真规则不变。[FFmpeg 实现](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/nvenc.c)
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

### 修复前：30 秒结果

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
原始轨迹见 [ABR 修复前 75 秒恢复观察](evidence/weak-network-abrtune-recovery-before.txt)。

### 首轮传输修复（ABR 修复前）

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

原始记录：[ABR 修复前 8 组](evidence/weak-network-abrtune-before.txt)、
[初测、失败与中间版本](evidence/weak-network-netem-before.txt)。

### ABR 修复前的回归检查

- `cargo test --workspace`：965 通过、0 失败、4 忽略。
- `cargo test -p viewflowd --features native-gpu-nvenc`：746 通过、0 失败、16 忽略。
- `cargo clippy --workspace --all-targets -- -D clippy::unwrap_used`：退出 0；保留既有告警。
- 最终 8 组及 75 秒补测：场景数、存活、完整帧、时长、帧计数守恒与源 SHA256 检查通过。
- 宿主 `lo` 仍为 `noqueue`；没有残留本测试进程。没有运行真实桌面/输入的忽略测试。

摘要与六项新增回归见 [ABR 修复前检查](evidence/weak-network-abrtune-checks-before.txt)。

### ABR 修复后：30 秒结果（2026-10-29 UTC）

以下为同一最终源码组合的一次完整八场景测量，八组均保持会话并产生完整帧。
错误字段均为 null。源 SHA256、测试可执行文件 SHA256、seed 和 qdisc 计数见
[最终原始记录](evidence/weak-network-netem.txt)。没有并行启动本任务的其他构建。
本机其他工作负载没有清空，因此这些数字不是严格隔离或匹配 seed 的 A/B 置信区间。

| 场景/模式 | 提交/完整/丢帧 | KF/NACK/repair | 内核/UDP/逻辑 Mbps | p50/p95/p99 ms | >100ms 卡顿数 | 末目标 kbps/fps | stable s |
|---|---|---|---|---|---|---|---|
| clean/auto | 1791/1791/0 | 0/41/913 | 157.32/151.85/158.32 | 10.0/12.9/16.7 | 0 | 900000/60 | 0.001 |
| wifi1/auto | 523/522/1 | 1/377/3536 | 7.73/7.47/10.30 | 42.3/97.1/139.4 | 38 | 5924/60 | 2.401 |
| wifi5/auto | 125/124/1 | 1/141/1862 | 2.39/2.41/2.50 | 170.2/549.0/682.7 | 109 | 2000/20 | 3.801 |
| cap20/auto | 669/668/1 | 1/3/672 | 8.03/7.70/12.70 | 32.2/46.0/52.5 | 3 | 4752/60 | 23.202 |
| cap8/auto | 454/454/0 | 0/260/2797 | 6.75/6.56/9.12 | 50.7/80.5/141.5 | 22 | 3306/60 | 3.402 |
| burst/auto | 960/958/2 | 2/28/758 | 56.28/54.43/59.19 | 8.5/11.3/16.9 | 7 | 62388/60 | 4.849 |
| cap20/high_quality | 669/669/0 | 0/2/47 | 8.14/7.81/13.08 | 32.9/35.7/37.0 | 0 | 900000/60 | 0.001 |
| cap20/save_bandwidth | 720/720/0 | 0/2/51 | 7.12/6.82/12.59 | 31.3/46.9/53.8 | 1 | 20000/60 | 23.401 |

- clean 为约 59.7fps，目标始终 900000kbps/60fps；p95 为 12.9ms，修复前为
  12.0ms。记录该差值，不将单轮接近基线的数字写成严格零回退证明。
- wifi1 完整帧从 435 增至 522，实际约 17.4fps；p95 从 115.8ms 降至 97.1ms，
  >100ms 卡顿从 52 降至 38。最低目标、重复测量和帧率目标另见下方补测记录。
  Auto 仍因真实 Quinn 服务能力限制而降低帧预算，不能把“随机丢包不等于拥塞”
  写成“QUIC 在 1% 丢包时仍能交付 900Mbps”的承诺。
- cap20 末目标为 4752kbps，p95 从 161.4ms 降至 46.0ms；HighQuality 本轮为
  35.7ms。cap8 末目标为 3306kbps，p95 从 86.7ms 降至 80.5ms；完整帧从
  489 变为 454。限带宽场景维持低于链路速率的末目标和有界延迟，不声称吞吐全项提高。
- burst 的 30 秒测量仍恢复，末目标为 62388kbps/60fps；不能用该末值证明
  已经恢复到 900000kbps。75 秒观察用于单独检查质量恢复。
- wifi5 的长尾仍明显。开发阶段的重复测量曾出现会话存活但 73 帧全部丢弃的
  seed；见 [5% 失败原始记录](evidence/weak-network-abrtune-wifi5-repeat.txt)。
  该轮在区间持续积压判定修正之前，不能作为最终源码的等价重放，也不能删除失败。
  本次没有证明所有 5% 丢包 seed 稳定可用；选择性修复与停止等待的极端行为仍有限制。

### ABR 原因、改动与独立验证

原实现的 RTT 门槛已经同时包含相对值和 10ms 绝对值，并非只有比值条件。
确认的问题是最小值从不过期、直接使用采样 RTT，以及恢复等待与发送积压混合归因。
本次将绝对余量调为 15ms，并增加窗口与平滑；不是把原有双条件当作不存在。

| 确认的问题 | 当前改动 | 验证边界 |
|---|---|---|
| 干净暖启动的 RTT 最小值永久保留 | 约 10 秒窗口、三点中位数和 EWMA | 基础 RTT 跃变、抖动和窗口过期单元测试 |
| GPU 预编码等待、原始入队和处置等待混为队列年龄 | 只计原始媒体入队；每 10ms 观察 Quinn 缓冲，200ms 消费峰值 | 真正入队/回执等待原子状态测试；真实 QUIC/netem |
| 空闲后瞬时积压套用低墙钟速率，同一旧帧反复降级 | 区间全部观测点忙才直接使用发送速率；部分区间按名义帧预算；每代次最多降一次 | 部分区间 RTT 膨胀、应用受限、旧帧和 FPS 阶梯测试 |
| 回执等待时空队列被当作容量充裕 | 用基础 RTT 加半帧服务时间修正升速门槛 | 无进展不探测、基础 RTT 不冻结恢复测试 |
| VBR 的一秒 VBV 允许目标变化后继续产生大帧 | CPU/GPU NVENC 使用一个 60Hz 名义帧的 VBV | 最终 netem；自有纹理与 C ABI oracle 另列，不代表视觉验收 |
| 30% 突发丢包时把本地 5 秒回执超时升级为会话失败 | 保留原始入队等待和同一精确回执 future，5 秒只警告；实际流/连接错误继续返回 | 部分读取跨警告、真实 EOF 两个 QUIC 回归；75 秒补测 |

突发失败的原始证据是 18.209s 出现 `atlas disposition feedback expired: deadline has elapsed`，
尚未到第 20 秒网络恢复点，之后没有完整帧。
[失败记录](evidence/weak-network-abrtune-recovery-failed.txt)与
[开发轮次](evidence/weak-network-abrtune-iterations.txt)均保留。
修复保留同一个读 future 的部分字节，不取消后重新读、不跳过旧回执，也不增大硬退出数字。
Quinn 的连接失联检查、真实流错误和对端本地资源看门狗继续生效。
`Sleep` 和等待 future 固定在栈上；没有逐帧 Box、锁、媒体复制或新的会话结束条件。

### 停止等待的吞吐成本与流水线决定

本次保留每 lane 一帧在途。`AtlasSenderSession::send_frame` 等待精确 disposition；
接收端每 lane 只有一个 `staged`/`feedback_pending`，后续同 lane manifest 会替代
不完整帧，`admit_manifest` 不接受尚未完成处置的下一帧。恢复围栏也只容纳每 lane
一个后续 manifest。两帧重传缓存不等于两帧有序 admission 队列。

GPU 源已经在 `GpuAtlasSender::submit_batch_with_release` 中编码下一帧，再等待
`finish_pending()`，因此它能隐藏部分编码时间；它没有并行发送下一份 manifest。
只删除发送端的等待会破坏 alpha 缓存、稀疏 patch/编码参考链和精确反馈所有者，
不属于安全且局部的兼容修改。本次没有修改协议。

仅往返延迟为 20–40ms 时，即使处理和序列化成本为零，单 lane 停止等待也不高于
50–25fps；多一个修复往返时上界进一步不高于 25–12.5fps。
本次 owned CPU 编码路径实际为 clean 59.7fps、wifi1 17.4fps、cap20 Auto 22.3fps、
HighQuality 22.3fps。它们包含编码和反馈时间，不是 GPU 编码提前路径的独立成本测量。

后续流水线必须协商新的可选能力，例如 `atlas_pipeline_version`，为每 lane 增加有界
admission/重排与多个精确反馈槽，定义 generation 内颜色/alpha/patch 的依赖和按序提交，
并在丢帧后正确处理所有后续参考帧。旧端继续停止等待。必须单独验证双 lane、
alpha 引用、稀疏 patch、恢复围栏和原生呈现；本次不以单 lane 合成成功替代这些验证。

### 固定源码补测与检查

完整八场景之后，clean、wifi1、cap8 与 75 秒 burst 使用相同 13 项源文件 SHA256
和同一个测试可执行文件 SHA256 再测。补测每 5 秒检查 Cargo 进程，排除本次 harness
自身的短暂构建；没有观察到外部 Cargo 重叠。检查记录见
[构建隔离记录](evidence/weak-network-abrtune-isolation.txt)。
先前与其他工作区构建重叠的 clean/恢复观察另存 `*-before-isolation.txt`，不用于下表。

| 补测 | 完整帧 | 实际 fps | p95 ms | >100ms 卡顿 | 最低/末目标 kbps | 最低帧率目标 |
|---|---|---|---|---|---|---|
| clean 30s | 1795 | 59.8 | 11.9 | 0 | 900000/900000 | 60 |
| wifi1 30s | 542 | 18.1 | 93.9 | 30 | 4246/4246 | 60 |
| cap8 30s | 406 | 13.5 | 82.3 | 20 | 2837/2837 | 60 |
| burst 75s | 3693 | 49.2 | 12.6 | 2 | 2000/900000 | 30 |

两次最终 wifi1 均未到 2000kbps 下限，帧率目标始终为 60；最低目标分别为
5924/4246kbps，完整帧为 522/542，p95 为 97.1/93.9ms。
clean 两次为 59.7/59.8fps、p95 12.9/11.9ms、无 >100ms 卡顿，目标始终为上限。
这是重复观察，不是统计置信区间。
原始记录分别见 [clean](evidence/weak-network-abrtune-clean-repeat.txt)、
[wifi1](evidence/weak-network-abrtune-wifi-repeat.txt)、
[cap8](evidence/weak-network-abrtune-cap8-repeat.txt)。

75 秒 burst 完整 3693/3698 帧。恢复网络后 1624.5ms 收到首个完整帧，
5.0 秒回到 60fps 目标，29.6 秒回到 900000kbps 目标；修复前的目标恢复为 37.6 秒。
本次有一次 11391.9ms 的完整帧间隔。日志在 frame 605 记录
`connection_closed=false retaining_exact_read=true`，随后继续完成帧并恢复，
直接覆盖超过原 5 秒等待的存活路径。不能把目标恢复变快写成所有媒体恢复延迟变快。
见 [75 秒最终恢复记录](evidence/weak-network-netem-recovery.txt)。

本次最终检查：

- `cargo test --workspace`：980 通过、0 失败、4 忽略。
- `cargo test -p viewflowd --features native-gpu-nvenc`：749 通过、0 失败、16 忽略。
- `cargo clippy --workspace --all-targets -- -D clippy::unwrap_used`：退出 0，保留其他告警。
- 核心码控 21 项、真实 QUIC 的回执警告/流错误 2 项均通过。
- 自有 GPU 空画布 C ABI 和 4K 自有纹理码率更新 oracle 各 1 项通过。
  新的一帧 VBV 下，H.264 的 900000/8000/32000 目标段分别为
  133202/11248/28754kbps；AV1 为 293121/11120/29583kbps。
  8000 目标段仍超过目标，虽然满足已有 0.5–2 倍断言，不能将 VBR 当作严格限流。
  上限段与历史同图案的码率相同，不代表 PSNR、视觉质量或原生显示验收。
- 最终 8 场景及四组补测的源 SHA256、相同可执行文件、时长、存活、完整帧与
  帧计数守恒检查通过。原始 `tc` 输出的行尾空格统一删除，数字与内容没有改写。

证据见 [最终检查](evidence/weak-network-netem-checks.txt)与
[决定及边界](evidence/weak-network-abrtune-decisions.txt)。
代码位置：`rate_control.rs:187`、`:330`、`:356`，`quality.rs:57`、`:234`、`:268`，
`atlas_session.rs:191`、`:1025`、`:1047`，`coded_peer.rs:2422`，
`nvenc_encoder.cpp:139`、`gpu_dmabuf_encoder.cu:411`。
GPU 的下一帧在前一帧回执前编码，发送代次不证明该提前编码帧使用了最新目标；
本次实际逐帧应用目标的测量路径为 CPU-owned RGBA，GPU atlas 路径仍列为未覆盖。

### 未覆盖

- Windows/macOS 源、真实 Wi-Fi、异步跨主机时钟与真实输入。
- 解码正确性、视觉质量、原生呈现、显示延迟、用户验收。
- GPU atlas 的 DMA-BUF/纹理合成导入、双 lane 的 netem 实测、VA-API 与 AV1。
  本次仅走 CPU-owned RGBA 上传到硬件 H.264 NVENC；现有普通测试另覆盖双 lane。
- 多次重复的统计置信区间、长时间浸泡和全内容性能回归。

## 拥塞控制实测：Cubic、Quinn BBR 与 DelayCubic（2026-10-29）

本节追加实验，不替换上述 W1/W2、ABR 或停止等待的历史记录。使用同一个
`tools/weak-network-test.py` 自有 RGBA → 硬件 H.264 NVENC → 真实 atlas/QUIC → 重组路径。
每组使用独立 `unshare -rn` 网络命名空间，至少 30 秒；不解码、不显示、不捕获桌面，
不注入真实输入、不切换焦点。仍是单 lane、一帧在途，不修改协议或 admission。

### 源码结论与选择

- 锁定版本为 quinn 0.11.11 / quinn-proto 0.11.19。Quinn 明确把 BBR 标为
  `Experimental! Use at your own risk.`；不能把它等同于 Linux BBRv2/v3。
- 此 BBR 根据带宽与 RTT 建模，但仍有丢包 conservation/growth 恢复窗口。
  DATAGRAM 所在 QUIC 包仍参加 ACK、丢包检测、拥塞窗口和 pacing；数据报本身不自动重传。
- `bw_estimation.rs` 只在新的非应用受限采样严格高于旧最大值时更新最大值过滤器，
  较低采样不能使旧估计过期。暖启动在干净 loopback、之后加入 netem 的路径变化
  因此尤其值得检查；这不是成熟的按包 delivery snapshot 估计。
- BBR 计算的 `pacing_rate` 只用于 `ControllerMetrics`/qlog。实际发包沿用
  Quinn 的 `1.25 × cwnd / smoothed RTT` token bucket，未采用 BBR 的 pacing gain 速率。
  BBR 默认初始窗口为 240000 B，Cubic 为 12000 B。
- 实测 BBR 没有提高 wifi1 Auto，且 cap20 明显变慢，因此不设为默认值。
  Cubic 的公开调参只有 initial window，没有随机丢包容忍度参数；增大初始窗口
  不解决持续乘性退让。没有修改或 fork Quinn 的 BBR/pacer。
- 新增局部 `DelayCubic`：复用 Quinn Cubic 的窗口增长、0.7 退让、MTU 和恢复状态。
  平滑 RTT 必须同时超过近期基线的 1.5 倍和基线加 15ms，才把普通丢包作为拥塞信号。
  无丢包时也在 ACK 路径检测排队并退让；同一 RTT 最多退让一次。ECN 和 Quinn
  persistent congestion 继续使用原响应。Quinn 可靠流重传、丢包探测和 pacing 不变。
- 基线用两个固定的一秒最小值桶，覆盖约 1–2 秒。确认基线上升超过 15ms，且窗口
  已低于原始初始窗口时，只恢复到原始 12000 B 并重新 slow start。它缩短基础时延
  改变后的过度退让，不恢复到历史大窗口。缓存并复用配置，ACK 路径没有新分配或锁。
  此窗口与 15ms 都是性能启发式，不是输入许可、帧截止或会话退出条件。

源码审阅、registry SHA256、替代方案与失败测试见
[控制器审阅及决定](evidence/weak-network-bbr-source-review.txt)和
[缺少恢复调用时的失败记录](evidence/weak-network-bbr-rebase-test-failed.txt)。

### 统一配置与兼容

`viewflow-transport` 导出 `media_transport_config()` 与
`media_transport_config_with(MediaCongestionController)`。默认选择 `DelayCubic`。
`VIEWFLOW_CONGESTION_CONTROL=cubic|bbr|delay_cubic` 在构造配置时读取，未知值记录错误并
保留默认值。TLS client/server、atlas、coded、window、audio 与 clipboard 的配置覆盖
统一经过该 builder。现有服务器 16 MiB、coded client 64 KiB、音频和默认数据报缓冲
分别保留；keepalive 和 idle timeout 不变。历史 evidence 快照不修改。

拥塞控制器只决定本地发送行为，不新增 QUIC transport parameter 或应用能力。
Cubic 与 BBR/DelayCubic 混用时，双向可靠流和 DATAGRAM 的真实本机 QUIC 测试通过；
原 ALPN 新旧配置兼容测试继续通过。旧端由旧 ALPN/默认 Cubic 配置模拟，未编译
历史二进制做跨版本联测。控制器没有 wire 协商，不要求同时升级两端。

### 测量与归因边界

测试器在每组测量前执行 `pgrep -af "weak-network-test|netem_session"`。遇到实际网络测试
按 60 秒间隔等待。完整进程清单和实际测量清单分别写入记录；等待中的 Python wrapper
不是正在测量，避免两个工作树相互等待。只修正本工作树的测试器，不操作兄弟工作树。
测量期间不运行本任务的 Cargo 检查。`tc -s qdisc` 每 0.5 秒在私有命名空间内采样。

下表 UDP Mbps 是 Quinn 的发送字节统计，包含协议和重传；不是有效视频吞吐。
完整帧逻辑 Mbps 还包含重组后的 alpha，不与压缩 RLE 的线速直接比较。
p95 为源提交到完整帧重组，不是解码、呈现或物理显示延迟。随机 netem seed、源文件与
可执行文件 SHA256 均保留；不同轮次没有匹配 seed，不构造统计置信区间。
默认值的最终轮使用 `--controller default` 并清除环境覆盖，单独验证默认选择。

### 最终 30 秒矩阵

每格为 **UDP Mbps / p95 ms / 末目标 kbps**。BBR 是原版 Quinn BBR；默认是最终
DelayCubic。三组各九场景均存活并产生完整帧，send/receive error 均为 null。

| 场景/模式 | Cubic（旧） | Quinn BBR | DelayCubic（默认） |
|---|---|---|---|
| clean/auto | 152.11 / 11.8 / 900000 | 152.09 / 11.7 / 900000 | 152.14 / 12.1 / 900000 |
| wifi1/auto | 7.43 / 97.1 / 3897 | 6.87 / 103.2 / 3821 | 15.53 / 38.0 / 9566 |
| wifi5/auto | 2.70 / 455.2 / 2000 | 2.72 / 290.1 / 2000 | 6.03 / 109.9 / 7135 |
| cap20/auto | 7.30 / 51.7 / 15720 | 4.34 / 137.1 / 2531 | 7.85 / 36.5 / 3654 |
| cap8/auto | 7.00 / 88.6 / 2000 | 6.79 / 95.8 / 2243 | 6.09 / 77.3 / 3787 |
| burst/auto | 55.04 / 11.0 / 19582 | 56.30 / 11.7 / 10576 | 102.67 / 14.9 / 900000 |
| cap20/high_quality | 7.88 / 34.9 / 900000 | 2.77 / 287.6 / 900000 | 7.30 / 37.6 / 900000 |
| cap20/save_bandwidth | 6.01 / 45.9 / 9118 | 2.90 / 226.2 / 2000 | 7.18 / 36.9 / 2000 |
| wifi1/high_quality | 6.40 / 106.7 / 900000 | 7.39 / 95.8 / 900000 | 16.86 / 30.9 / 900000 |

原始记录：[Cubic 九组](evidence/weak-network-bbr-cubic.txt)、
[Quinn BBR 九组](evidence/weak-network-bbr-stock.txt)、
[最终默认九组](evidence/weak-network-bbr-final.txt)。

- wifi1 Auto：默认相对 Cubic 的 UDP 发送率约 2.09 倍，末目标约 2.45 倍；
  完整帧从 554 增至 1258，p95 从 97.1ms 降至 38.0ms。
  HighQuality 的 UDP 从 6.40 增至 16.86Mbps，完整帧从 440 增至 1417。
- clean：Cubic 与默认均为 1795 完整帧，目标维持 900000kbps/60fps，
  p95 为 11.8/12.1ms；不能把接近基线写成严格零回退证明。
- cap20/cap8 Auto 的 p95 为 51.7→36.5ms、88.6→77.3ms。
  cap8 UDP 为 7.00→6.09Mbps，不能声称吞吐全项改善；cap20 末目标也低于本轮 Cubic。
- cap20 HighQuality 的 p95 为 34.9→37.6ms，Cubic 同源码补测为 36.2ms。
  默认有小幅 p95 回退，不宣称所有模式满足严格零回退。完整帧为 677→619。
  该模式仍保持原固定质量；控制器不改变编码目标。基础时延变化后的启动恢复仍有成本。
- BBR 的 cap20 Auto p95 为 137.1ms、HighQuality 为 287.6ms；wifi1 Auto
  发送率为 6.87Mbps。下表的 BBR 队列反而较小，不能把其慢帧直接归因于 netem
  持续积压；本实验没有按包记录 BBR 内部状态来证明某一个源码缺陷的独立因果。

### 内核队列与丢弃

以下是 0.5 秒采样的 backlog，单位 KiB（1024 B）。p95 使用排序后
`floor((n-1)*0.95)`；末段取最后 20 次采样的最大值。采样不能证明两次观察之间
没有更高峰值。drop 是同一 qdisc 计数的观测最大值，不是媒体丢帧数。

| 场景/模式 | 控制器 | backlog p95 KiB | 峰值 KiB | 末段峰值 KiB | drop |
|---|---|---|---|---|---|
| cap20/auto | Cubic | 75.7 | 863.1 | 48.8 | 0 |
| cap20/auto | BBR | 16.0 | 281.5 | 18.9 | 0 |
| cap20/auto | DelayCubic | 44.1 | 131.4 | 44.1 | 0 |
| cap8/auto | Cubic | 382.5 | 869.2 | 29.6 | 174 |
| cap8/auto | BBR | 18.1 | 96.7 | 21.7 | 170 |
| cap8/auto | DelayCubic | 499.3 | 983.7 | 28.2 | 121 |
| cap20/high_quality | Cubic | 44.3 | 44.4 | 44.1 | 0 |
| cap20/high_quality | BBR | 10.4 | 17.4 | 7.3 | 0 |
| cap20/high_quality | DelayCubic | 43.9 | 56.8 | 43.7 | 0 |
| cap20/save_bandwidth | Cubic | 43.8 | 82.2 | 82.2 | 0 |
| cap20/save_bandwidth | BBR | 8.8 | 25.3 | 9.1 | 0 |
| cap20/save_bandwidth | DelayCubic | 43.7 | 44.1 | 44.1 | 0 |

cap20 三种模式的最终默认 qdisc drop 均为 0。cap8 配置本身含 2% 随机丢包，
`tc` 的合并计数不能区分随机丢弃与队列溢出。默认 cap8 有约 1 MB 瞬时峰值，
高于本轮 Cubic；末段没有维持该积压。结论限于有界且能排空的采样结果，
不声称每个瞬时峰值都下降。

### 开发轮次与检查

保留 [10 秒旧基线窗口](evidence/weak-network-bbr-delay-cubic.txt)、
[短窗口但未恢复初始窗口](evidence/weak-network-bbr-delay-fast.txt)、
[该版本 HighQuality 重复](evidence/weak-network-bbr-delay-hq-repeat.txt)。
旧窗口 wifi1 为 17.08Mbps，但 cap20 启动阶段持续过度退让；缩短窗口改善恢复。
短窗口仍在很小的 Cubic congestion-avoidance 窗口中缓慢增长，因此最终增加有界
初始窗口恢复。不同 seed 不能用于精确分摊这两项改动的收益。

最终源码检查：

- `cargo test --workspace`：985 通过、0 失败、4 忽略。
- `cargo test -p viewflowd --features native-gpu-nvenc`：749 通过、0 失败、16 忽略。
- `cargo clippy --workspace --all-targets -- -D clippy::unwrap_used`：退出 0；保留其他告警。
- 新增四项控制器测试：随机丢包、排队退让频率、ECN/持续拥塞、基线过期/抖动、
  路径时延变化后的初始窗口恢复与再次退让；部分情形在同一测试中验证。
- 新增混合控制器 QUIC 测试；Cubic/BBR 与 Cubic/DelayCubic 都交换双向可靠流和数据报。

证据：[检查摘要](evidence/weak-network-bbr-checks.txt)、
[工作区](evidence/weak-network-bbr-check-workspace.txt)、
[NVENC](evidence/weak-network-bbr-check-nvenc.txt)、
[Clippy](evidence/weak-network-bbr-check-clippy.txt)、
[transport 检查](evidence/weak-network-bbr-transport-checks.txt)。

### 同一最终可执行文件的补测与恢复

最终默认九组及下列七项补测使用相同源 SHA256 和同一个测试可执行文件 SHA256。
Cubic/BBR 复测在最终源码中显式选择原控制器，避免把不同构建当作唯一对照。

| 补测 | UDP Mbps | 完整帧 | p95 ms | 最低/末目标 kbps |
|---|---|---|---|---|
| Cubic wifi1 Auto | 7.67 | 566 | 87.7 | 4955/4955 |
| BBR wifi1 Auto | 7.03 | 504 | 112.7 | 4738/4738 |
| BBR cap20 Auto | 2.78 | 164 | 259.3 | 2000/2000 |
| 默认 wifi1 Auto | 15.02 | 1399 | 32.4 | 10567/36556 |
| 默认 cap8 Auto | 6.18 | 411 | 78.7 | 2798/2798 |
| 默认 cap20 HighQuality | 7.42 | 630 | 36.1 | 900000/900000 |
| 默认 burst 75s | 125.39 | 3909 | 13.8 | 58134/900000 |

- wifi1 两次最终默认为 15.53/15.02Mbps，Cubic 为 7.43/7.67Mbps；
  默认末目标 9566/36556kbps，有明显 seed/码控轨迹差异，不是容量收敛的置信区间。
- cap8 两次最终默认 p95 为 77.3/78.7ms；补测有一次 5274.7ms 完整帧间隔。
  p95 不能替代最大停顿或启动恢复指标，本任务没有消除所有长尾。
- cap20 HighQuality 最终默认重复为 37.6/36.1ms；Cubic 为 34.9/36.2ms。
  两组范围接近并有重叠，仍不宣称严格零回退。
- 75 秒 burst 存活，3912 提交、3909 完整、3 丢弃。网络恢复后 57.5ms
  观察到完整帧；这不证明该帧的源时间也在恢复点之后。最大完整帧间隔为
  1833.0ms，p95 为 13.8ms；最低目标 58134kbps，帧率目标始终为 60。
  恢复后 13.4 秒首次回到 900000kbps，持续到观察结束；不是显示或视觉恢复证明。

补测证据：[Cubic wifi1](evidence/weak-network-bbr-cubic-wifi-repeat.txt)、
[Cubic HighQuality](evidence/weak-network-bbr-cubic-hq-repeat.txt)、
[BBR wifi1](evidence/weak-network-bbr-stock-wifi-repeat.txt)、
[BBR cap20](evidence/weak-network-bbr-stock-cap20-repeat.txt)、
[默认 wifi1](evidence/weak-network-bbr-final-wifi-repeat.txt)、
[默认 cap8](evidence/weak-network-bbr-final-cap8-repeat.txt)、
[默认 HighQuality](evidence/weak-network-bbr-final-hq-repeat.txt)、
[75 秒恢复](evidence/weak-network-bbr-final-recovery.txt)。

全部 54 组完成记录通过时长、存活、完整帧、错误为空、帧计数守恒和 burst 恢复检查。
最终矩阵与七项补测的源 SHA256 均匹配最终源码，可执行文件 SHA256 相同。
运行 `python3 docs/evidence/weak-network-bbr-validate.py` 可以重复检查，见
[校验结果](evidence/weak-network-bbr-validation.txt)。原始日志只删除行尾空白和末尾空行，数字不改写。
宿主 `lo` 保持 `noqueue`；本任务的测试器、网络测试和命名空间采样进程没有残留。

### 未验证与适用边界

- Windows/macOS 构建及实机源，真实 Wi-Fi/AP、竞争流、小缓冲拥塞与互联网公平性。
  没有 RTT 膨胀的小缓冲丢包不能仅凭本控制器区分随机损失与拥塞；应用 ABR 继续生效。
- 历史二进制的跨版本联测、跨主机时钟、GPU atlas 导入、双 lane 的 netem 测量。
  本机混合控制器测试和已有双 lane 普通测试不替代这些检查。
- 解码正确性、主观画质、原生呈现、物理显示延迟和用户视觉验收。
- 所有随机种子的稳定性、长时间浸泡、严格零性能回退。没有实现 FEC 或多帧流水线。

默认选择基于上述单 lane 自有内容测量，保留 Cubic/BBR 覆盖开关便于回退和继续研究。
没有增加认证、焦点、输入或会话退出限制，没有推送或部署。
