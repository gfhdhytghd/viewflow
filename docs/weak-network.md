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

### W2 Linux 自适应码率与帧率（2026-10-27 已实现）

配置 `AtlasSourceConfig.quality_mode` 支持 `auto`（缺省）、`high_quality`、
`save_bandwidth`，拒绝拼写错误。Linux coded sender 对应
`--quality-mode auto|high_quality|save_bandwidth`。策略在启动时选择，尚无运行中 UI。

- **Auto**：每个编码 lane 上限 900,000 kbps，干净链路保持上限；复用共享
  `RateController`，拥塞时降低码率，到 2,000 kbps 下限后降低帧率到 30/20。
  SaveBandwidth 同样自适应，但上限为 225,000 kbps。这个上限是编码质量上限，
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
