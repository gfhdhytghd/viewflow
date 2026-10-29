# Moonlight / Sunshine 视频传输与 Viewflow 对比

本报告基于源码阅读。Moonlight 的主要弱网机制是分块 FEC、参考帧恢复和有界呈现队列，
不是持续自动测速或按丢包闭环调码率。Viewflow 已有 QUIC 拥塞控制、W1 选择性重传和
W2 自适应质量；优先补足前向修复、反馈归因和连接内排队，而不是另造一套 RTP 传输。
以下建议均为设计提案，本次没有修改协议或运行代码。

## 1. 来源、术语与验证边界

源码快照读取于 2026-10-28。参考仓库位于 `/home/wilf/data/viewflow-wt/_ref/`，
不属于 Viewflow 工作树。下文 `M:`、`S:`、`Q:` 分别代表以下仓库根目录。
引用格式为 `仓库:文件:function`；Viewflow 引用为仓库相对 `文件:行号`。

| 标记 | 仓库与固定提交 |
| --- | --- |
| M | [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c/tree/5d3c0ecca00c1bb3f587acb8060476edcf8e24aa)，`5d3c0ecca00c1bb3f587acb8060476edcf8e24aa` |
| S | [Sunshine](https://github.com/LizardByte/Sunshine/tree/a679b059096bcdd502e2192ce4f6a3c3732fbaae)，`a679b059096bcdd502e2192ce4f6a3c3732fbaae` |
| Q | [moonlight-qt](https://github.com/moonlight-stream/moonlight-qt/tree/ac296864ace96f51ad75f78b90644bdbca76c332)，`ac296864ace96f51ad75f78b90644bdbca76c332` |
| M/nanors | M 锁定的子模块 `a9b1636f9c98dbfdd0daeaf6982ccd24d1c30f29`，读取 `rs.c` |
| Viewflow | 本分支修改文档前的 `d9c4d8b2f4bee712d534b331213a3128a16b8507` |
| QUIC 依赖 | `Cargo.lock:902`：quinn 0.11.11 / quinn-proto 0.11.17；默认参数另读本机 Cargo registry 的对应源码 |

三个上游仓库各自固定当前 HEAD，不假定它们是同一发行版的配套组合。尤其不能把客户端
定义的扩展消息视为本次 Sunshine 快照已经接收并使用的功能。参考代码仅用于学习设计，
没有复制 GPL 代码、协议结构体实现或 nanors 实现进入 Viewflow。

- FEC：前向纠错，发送冗余 shard（等长分片），不等待重传往返。
- NACK：接收端请求缺失分片，修复至少需要一次往返。
- IDR：刷新解码参考链的关键帧；RFI：要求编码器停止引用指定帧范围。
- lane：独立编码、反馈和恢复的媒体通道；不等于独立 QUIC 拥塞窗口。
- pacing：发送或显示节奏控制；rate control：编码码率控制。两者不能混用。

**已验证范围**：下面的当前实现结论来自固定快照的函数、字段与调用链检查。
**未验证范围**：未编译或运行上游；未运行 Viewflow 媒体测试、netem、实机 Wi-Fi、
Windows/macOS 编码器或视觉验收。建议的收益是推导，参数是实验起点，不是测量结果。
没有发送鼠标/键盘输入，没有切换焦点，没有部署或推送。
所有建议遵循[安全与可用性指导原则](security-and-availability-policy.md)：
33 ms 是性能目标，修复预算到期只丢弃相关帧或恢复相关 lane，不增加会话结束条件。

## 2. 视频分包、包长与 MTU

### Moonlight / Sunshine

`M:src/Video.h:NV_VIDEO_PACKET/RTP_PACKET` 定义 12 字节固定 RTP 头；视频设置 extension，
再保留 4 字节，随后是 16 字节 `NV_VIDEO_PACKET`。视频编码字节前另有 Sunshine 帧头。
`S:src/stream.cpp:videoBroadcastThread` 用
`blocksize = packetsize + MAX_RTP_HEADER_SIZE`（16），
`payload_blocksize = blocksize - sizeof(video_packet_raw_t)` 插入每包头部位置。
因此协商的 `packetSize` 不是视频净载荷长度，也不是 IP MTU；净载荷通常是
`packetSize - 16`，未加密 UDP payload 是 `packetSize + 16`。

- RTP `sequenceNumber` 是网络字节序的 16 位包序号，包含校验包；timestamp 是 90 kHz。
- `frameIndex` 标识帧；数据包 `streamPacketIndex = (lowseq + x) << 8`。
  接收端对 NV 字段按小端读取，不能把它当作普通 RTP 序号。
- 每个 FEC block 内首尾数据包设置 `FLAG_SOF/FLAG_EOF`；帧跨 block 时还依赖
  `multiFecBlocks`，并非遇到一次 EOF 就提交整帧。
- `fecInfo` 的 bit 4–11 为百分比，12–21 为 block 内 shard 索引，22–31 为数据包数。
  `multiFecBlocks` 的 bit 4–5 为 block 序号，6–7 为最后 block 序号。
  接收过程见 `M:src/RtpVideoQueue.c:RtpvAddPacket`。

`Q:app/streaming/session.cpp:Session::startConnectionAsync` 的启动配置使用 `packetSize=1392`；
VPN 使用 1024，用户可以覆盖。配置在连接启动前完成。
`M:src/Connection.c:LiStartConnection` 将包长向下对齐到 16 字节；远程 IPv4 上限 1024，
远程 IPv6 上限 1184。`M:src/SdpGenerator.c:getAttributesList` 为视频加密
先扣除 32 字节 `ENC_VIDEO_HEADER`，因此加密前缀不额外扩大所选 UDP 大小。
例如默认未加密 UDP 为 1408 字节，另加 IPv4/UDP 28 字节或 IPv6/UDP 48 字节；
这不是对任意 VPN 路径 MTU 的保证。

### Viewflow 与差距

`crates/viewflow-transport/src/media.rs:6` 定义 `VFMD` v1 的 52 字节应用头。
`MediaPlaneFrame::fragment`（`:44`）按 `max_datagram_bytes - 52` 切片，
用 `window_id/frame_id/geometry_epoch/plane/chunk_index/chunk_count` 标识分片。
数据片共享 `Bytes`；`MediaDatagram::encode`（`:137`）才组成单包字节。
`crates/viewflowd/src/atlas_session.rs:941` 从连接的 `max_datagram_size()` 取预算，
不是把 UDP MTU 当作 QUIC DATAGRAM 净载荷。先入队可靠 manifest，再入队颜色和 alpha；独立传输路径不保证到达先后。

`crates/viewflow-transport/src/reassembly.rs:90` 的 `MediaAssembler` 按窗口、平面、帧
重组。限制 8192 chunks、64 MiB/plane、256 个 pending plane（`:11`、`:20`）；
新帧替换同窗口同平面的旧帧，拒绝冲突片。`push_latest`（`:134`）允许当前帧在调用者
看门狗内完成，不把默认 33.3 ms 重新解释为安全条件。

**差距**：Viewflow 的分片身份更适合多窗口和 alpha，但没有 FEC block 身份。
不能直接照搬 1392 或 1024 为 QUIC 应用包长；QUIC 的头、AEAD、DATAGRAM framing
已经由 quinn 从最大可发大小中扣除。后续 FEC 必须继续在该预算内切片。

## 3. FEC、重组队列与不可恢复判定

### Moonlight / Sunshine

`S:src/stream.cpp:fec::encode` 调用 Reed–Solomon；默认
`S:src/config.cpp:stream` 的 `fec_percentage=20`，配置范围 0–100。
设一个 block 有 D 个数据 shard，通常 P=`ceil(D × percentage / 100)`。
`M:src/SdpGenerator.c:addGen5Options` 请求 `minRequiredFecPackets=2`；
`S:src/rtsp.cpp:cmd_announce` 读取这个值。启用 FEC 且 P 小于下限时，
`fec::encode` 提升 P 和包内百分比；D=1 时可以产生两个 parity，即 200%。
FEC=0 不强制这个下限。小帧的相对开销因此显著高于 20%。

`S:src/stream.cpp:videoBroadcastThread` 根据总 shard 数不超过 255 来分 block：
D 上限初算为 `floor(25500/(100+percentage))`，默认 20% 时是 212。
帧最多 4 个 FEC block；各 block 独立 RS，先发送数据，随后发送该 block 的 parity。
末片补零；超出 4 block 的异常大帧关闭 FEC，并继续按最多 4 block 分包。
每 block 达到 1024 包时还会记录索引溢出错误；这说明上游也有尺寸边界，
不是建议 Viewflow 对大帧断开会话。

`M/nanors:rs.c:reed_solomon_new/reed_solomon_encode/reed_solomon_decode` 使用 GF(2^8)
矩阵，D+P≤255。接收端给出缺失标记，解码器从收到的 parity 行恢复缺失数据行。
这里是已知擦除位置的修复，不是对任意损坏字节自动纠错。

`M:src/RtpVideoQueue.c:reconstructFrame` 的过程为：

1. 当前 block 收到至少 D 个不同 shard 后尝试完成；全数据到齐时无需 RS。
2. 缺数据时为缺失位置分配 buffer，并补齐短包的零填充。
3. 调用 `reed_solomon_decode`，重建包头必要字段，只留下数据包。
4. `stageCompleteFecBlock` 保存完成 block；最后 block 完成后，
   `submitCompletedFrame` 才按顺序提交 depacketizer。

Debug 的 `FEC_VALIDATION_MODE` 故意再丢一个数据 shard，因此需要 D+1 个包；
不能将这个验证模式的门槛误报为正常发行版规则。
`RtpvAddPacket` 丢弃旧帧、旧 block、重复包和范围外包。新帧或新 block 到达而旧 block
不足 D 时，报告 FEC 最终状态并清理整帧未提交数据。中间 block 完全丢失也使整帧失败，
不是把后一个 block 交给解码器拼出残缺帧。

`reconstructFrame` 另有推测性丢失判断：启用 RFI 且近期无乱序时，若当前已观察缺包数
超过剩余纠错能力，提前 `notifyFrameLost(..., true)`，不用等到下一帧。
出现乱序或预测错误后，`queuePacket` 的逻辑使该优化冷却 300 秒。
它保留普通乱序重组，不把一次乱序变成连接故障。

**超时核对**：`M:src/VideoStream.c` 的 `RTP_QUEUE_DELAY=10` 只有定义，没有调用点。
本快照的 `RtpVideoQueue.c` 没有定时淘汰当前 block 的 10 ms 逻辑。
不可恢复判定主要由收到后续帧/block或推测性缺包触发。
`FIRST_FRAME_TIMEOUT_SEC=10` 是启动期收不到数据/完整首帧的检查；
控制通道 ENet 连接超时与 Sunshine 默认 10 秒 ping 看门狗又是不同机制。
不能把这三个数合成“每帧 10 ms 截止”。

### Viewflow 与差距

`crates/viewflowd/src/atlas_loss.rs:37` 的 `LossWait::new` 使用
`clamp(2 × RTT + frame_period, 8ms, 250ms)`；这只是局部恢复预算。
`crates/viewflowd/src/atlas_session.rs:1711` 从 manifest 时间差估算帧周期；活动双 lane
除以 2，并将周期限制为 1–33.3 ms。`:1718` 另外把 NACK 可用时间夹在剩余呈现目标内。
`:1156` 的 `poll_loss` 在约一 RTT 后只尝试一轮 NACK，且必须还能容纳一次 RTT。
无流量时也由 `loss_wakeup` 唤醒；`:1213` 的同 lane 新数据/manifest 会淘汰旧帧。
到期走 `expire_lost_frame`（`:1128`），回 `ExpiredUnbound`，保留连接和其他 lane。

NACK 能力在 `atlas_session.rs:538`、`:714` 双向协商 `nack_version=1`。
`atlas_loss.rs:13`、`:110` 定义 `VFNA`、最多 512 索引和 64 项发送队列；
专用 `VFN1` QUIC uni stream 与输入流分开。`:141` 的 `Retransmit` 缓存每 lane
最近两帧的两个平面，共享 `Bytes`，每块最多修复一次，过期或同 lane 已有新帧即停止。
`:225` 通过 `send_datagram` 尝试修复；返回错误时停止，不阻塞延长预算。
**源码差异**：quinn 0.11.11 的 `Connection::send_datagram` 在缓冲满时可淘汰旧待发
数据报，拥塞不会直接返回 `Blocked`。所以现有 W1 不能据 `is_err()` 保证
“缓冲满则只丢修复包”。修复可能挤掉同连接中其他 lane 的待发媒体。
这与 `send_datagram_wait` 等待空间的语义不同；后续应先检查可用空间或增加统一
发送仲裁；多任务并发时，仅预查空间不能保证检查与入队之间没有变化。证据：quinn `src/connection.rs:Connection::send_datagram` 与
quinn-proto `src/connection/datagrams.rs:Datagrams::send`。
**后续修复**：`atlas_loss.rs` 的修复发送已改为先检查 `datagram_send_buffer_space()`，
空间不足时跳过修复，不再淘汰其他待发媒体；多任务并发下的检查与入队竞态仍待统一发送仲裁。

**差距**：W1 已有上游当前 FEC 队列没有的显式静默唤醒，但无前向冗余。
33 ms 目标内，较高 RTT 时 NACK 经常没有修复机会；FEC 可以填补这段空白。
颜色、alpha、manifest 是联合可用条件，不能只保护颜色后宣称“整帧恢复”。
FEC 也不能消除 quinn 对真实网络丢包的拥塞响应。

## 4. 丢帧恢复：RFI、IDR 与反馈

### Moonlight / Sunshine

`M:src/Misc.c:isReferenceFrameInvalidationEnabled` 要求服务器支持，且当前 codec 的
解码器 capability 支持 RFI。`Q:app/streaming/video/ffmpeg.cpp:FFmpegVideoDecoder::getDecoderCapabilities`
合并 backend 能力；软件 HEVC、软件 AV1 有明确支持，硬件 backend 各自声明，
不能以“支持 NVENC”推导所有接收器都支持 RFI。

`M:src/VideoDepacketizer.c:dropFrameState/notifyFrameLost` 在已有可用 IDR 且支持 RFI 时
转为等待 ref-invalidation 帧，并报告从最后接收链起点至丢失帧的范围。
未建立 IDR、损坏 IDR、严格等待模式时请求 IDR；连续丢弃 120 帧也触发 IDR。
`LiCompleteVideoFrame` 收到 `DR_NEED_IDR`，或解码队列溢出，都走完整 IDR 恢复。

`M:src/ControlStream.c:connectionDetectedFrameLoss/referenceFrameControlFunc` 合并待发
失效范围；`requestInvalidateReferenceFrames` 用 urgent ENet 可靠消息 `0x0301`。
`SS_RFI_REQUEST` 是 24 字节小端布局，首尾为 32 位 frame index 加 reserved，
兼容 Sunshine 按两个 64 位值读取。IDR 为 `0x0302`。
新客户端还有 `SS_LTR_FRAME_ACK_PTYPE=0x0350`；本报告不假定该 Sunshine 快照使用 LTR ACK。

`S:src/stream.cpp:controlBroadcastThread` 将 `0x0301` 转成编码器事件；
`S:src/video.cpp:encode_run` 消费事件。`nvenc_encode_session_t::invalidate_ref_frames`
调用 `S:src/nvenc/nvenc_base.cpp:nvenc_base::invalidate_ref_frames`：

- 失效范围扩展到最新编码帧，排除后续已经引用损坏链的帧。
- 范围达到 DPB 参考帧容量、范围非法或 NVENC API 失败时，回退到 IDR。
- 对范围内帧调用 `nvEncInvalidateRefFrames`；下一输出标记 `after_ref_frame_invalidation`。
- `videoBroadcastThread` 将恢复输出帧头标记为 type 5，客户端据此恢复参考链。

`nvenc_base::configure_reference_frames` 保留较大 DPB，并限制每帧引用数量；
H.264/HEVC 缺省 DPB 5，AV1 为 8，实际还受客户端请求及硬件能力约束。
**AMF / QSV 的实际结论**：本快照只有专用 NVENC session 接通 RFI；
`S:src/video.cpp:avcodec_encode_session_t::invalidate_ref_frames` 明确记录不支持并请求 IDR。
AMF/QSV 的 FFmpeg 路径不能因为底层 SDK 有某种相关 API 就写成 Sunshine 已支持 RFI。

### 统计发送不等于统计生效

`M:src/RtpVideoQueue.c:reportFinalFrameFecStatus` 发送 frame/block、D/P、收到的 D/P、
最高序号、连续序号和缺包数。`M:src/ControlStream.c:lossStatsThreadFunc` 的现代路径每
100 ms 发送可靠 `0x0200` ping，让 ENet 更新 RTT；Sunshine 专用 FEC 状态 `0x5502`
以 unsequenced、不可靠方式发送，队列上限 8。旧主机路径每 50 ms 发 `IDX_LOSS_STATS`，
其中丢包计数字段实际填 0，不能当作现代客户端每 50 ms 发送准确媒体丢包率。

`S:src/stream.cpp:controlBroadcastThread` 对 `0x0201` 仅打印 loss stats；
没有用它调整码率或 FEC。此 Sunshine 快照没有注册接收 FEC 状态 `0x5502` 的回调，
`control_server_t::call` 对未知 type 写 debug 日志。其 `packetTypes` 中同数值还用于
主机到客户端的 RGB LED 扩展，方向不同，不能据常量名推导服务器接收行为。
因此“Moonlight 发送每 block 状态”和“Sunshine 利用状态闭环调参”是不同结论，后者无源码支持。

### Viewflow 与差距

`crates/viewflowd/src/gpu_atlas_sender.rs:393`、`:404` 在 reference gap 请求关键帧，
并要求颜色和 alpha 成对关键帧。`crates/viewflowd/src/atlas_feedback.rs:87` 的 disposition
区分 committed、superseded、expired；本次检查的编码器封装没有 RFI 范围 API。
NVENC 经 FFmpeg，Windows 用 VPL/MFT，macOS 用 VideoToolbox，不能共享一个虚假的
“全部支持 RFI”能力位。

`crates/viewflowd/src/atlas_loss.rs:18` 保存 `LossTelemetry`；
`atlas_session.rs:1203` 每 5 秒输出摘要，`:2106` 把发 NACK 后完成计作 recovered。
它不能区别原包迟到和真正重传。全平面未到时，`:1148` 的缺包计数按至少 1 计，
不是准确分片数；quinn `lost_packets` 则含连接内其他流量，不能当作媒体丢片分母。

**差距**：现有恢复主要是成对关键帧，弱网时会增大突发；缺少按 lane、codec generation、
颜色/alpha 参考链定义的 RFI，以及远端可用的统一恢复统计。
先建立准确统计和能力契约，再试 RFI；保留 IDR 作为不支持或失败时的局部回退。

## 5. 码率、拥塞、发送节奏与套接字

### Moonlight / Sunshine

`Q:app/settings/streamingpreferences.cpp:StreamingPreferences::getDefaultBitrate` 根据
分辨率、帧率、YUV444 给默认值；用户通过滑块选码率。
`Q:app/gui/SettingsView.qml` 的 `autoAdjustBitrate` 是更改画面设置后重算默认值，
不是流中测量链路容量的 ABR。`Q:app/streaming/bandwidth.cpp:BandwidthTracker` 统计
接收编码字节的窗口平均/峰值，不测量空闲带宽。

`S:src/rtsp.cpp:cmd_announce` 从客户端 SDP 取码率。若有客户端 configured bitrate，
按 FEC（比例≤80 时乘 `1-F/100`）、音频预算和最多 500 kbps 包头/控制预算扣减，
再交编码器；不是精确线速上限，特别是小帧最少 parity 会扩大相对开销。
`S:src/video.cpp:make_avcodec_encode_session` 编码初始化设置 `bit_rate/rc_max_rate`
及约一帧的 VBV，受 `max_bitrate` 配置夹紧。
专用 NVENC 的 `S:src/nvenc/nvenc_base.cpp:nvenc_base::configure_rate_control` 设置
CBR、无限 GOP、无 B 帧、零 lookahead、约一帧 VBV（支持硬件可增加 VBV 百分比）。
没有从上述 loss 回调到编码器动态目标更新的闭环。CBR/VBR 编码器码控不等于网络 ABR。

`S:src/stream.cpp:videoBroadcastThread` 使用约 **800 Mbps** 的帧内发送节奏：
按 `1Gbps × 80% / 1000 / blocksize / 8` 得每毫秒包数，分组 sleep，记住上一帧
末尾的应发时间。batch 少于约 64 KiB，最多 64 包，支持平台 `send_batch`，失败回退
逐包发送。这是削平超大瞬时突发，不是按 Wi-Fi 容量或用户目标逐帧均匀铺满帧周期。
`S:src/stream.cpp:start_broadcast` 的视频 socket 请求 1 MiB `SO_SNDBUF`。

`M:src/VideoStream.c:startVideoStream` 请求容纳 2048 个视频包的接收 buffer；
`M:src/PlatformSockets.c:bindUdpSocket` 尝试设置并读取实际缓冲，系统限制会改变结果。
`setSocketQos` 在 Linux 设 video `SO_PRIORITY=5`、audio=6，Apple 用网络服务类别。
`S:src/platform/linux/misc.cpp:enable_socket_qos` 在启用 DSCP 时设 video=40（CS5），
audio=48（CS6），并设 priority 5/6；Windows 用 QoS flow。
DSCP 是可选标记，不保证 AP/Wi-Fi 驱动接受或获得专用带宽。

### Viewflow 与差距

`crates/viewflow-transport/src/tls.rs:94` 的 server 配置将 DATAGRAM 收发应用缓冲设为
16 MiB、uni stream 上限 256；client（`:118`）保留 quinn 默认配置。
`crates/viewflowd/src/bin/vf-window-peer.rs:53` 用带 keepalive 的新默认配置，
覆盖原配置时不会自动继承 server 的 16 MiB。
coded client 在 `crates/viewflowd/src/coded_peer.rs:1452` 单独设 64 KiB 发送缓冲。
这些是 quinn 应用数据报缓冲，不是操作系统 `SO_SNDBUF`；不能直接比较字节数得出优劣。

锁定的 quinn-proto `src/config/transport.rs:TransportConfig::default` 默认 Cubic、
初始 UDP MTU 1200、启用 MTU discovery、DATAGRAM send buffer 1 MiB；
`src/connection/paths.rs` 使用 `src/connection/pacing.rs:Pacer` 控制发包。
Viewflow 没有替换拥塞算法或 MTU 默认配置。
QUIC DATAGRAM 不保证交付且不自动重传，但仍受连接拥塞窗口和 pacing 控制；
可靠控制流与所有媒体 lane 共享连接容量。不要在它之上再加固定 800 Mbps 的限流器。

`crates/viewflow-core/src/rate_control.rs:166` 的 `RateController::on_sample` 已有网络 ABR：
丢包率≥10%，或≥2%且 RTT 膨胀，或发送年龄超过两帧，或 RTT 膨胀且丢帧时降低码率。
RTT 膨胀门槛为 `min_rtt + max(min_rtt/2,10ms)`（`:237`）。
目标乘 0.85/0.7，并取实际连接发送速率的 0.9；最低 2000 kbps。
稳定后每秒升 8%，连续干净 5 秒后升 30%，到下限才逐级降帧率。
`quality.rs:99`、`:197` 的 monitor 每 200 ms 采样累计计数差、发送年龄和 disposition，
Auto 每 lane 上限 900000 kbps，SaveBandwidth 上限 20000；HighQuality 保留原行为。
`:141` 强制 `scale_permille=1000`，本版本没有真正动态缩放。

| Viewflow 编码路径 | 源码与现有行为 |
| --- | --- |
| Linux CPU/GPU NVENC | `platform/nvenc-encoder/nvenc_encoder.cpp:118`、`gpu_dmabuf_encoder.cu:408`：低延迟、零 lookahead、无 B 帧，Auto 为 VBR/CQ 7；运行时更新 `bit_rate/rc_max_rate/rc_buffer_size`（`:231`、`.cu:508`）。颜色码率与 alpha 保真约束不同，不能把 alpha 当作可随意有损的视频 |
| Linux VA-API | `platform/linux-media/vaapi_encoder.cpp:50`、`:68`：VBR/CQP；待更新目标在帧边界创建替换编码器，至少间隔 1 秒，首帧 IDR，准备失败保留旧实例 |
| Windows VPL | `platform/windows-reverse/vpl_encoder.cpp:110`：排空已提交工作，`MFXVideoENCODE_Reset` 更新 CBR，`StartNewSequence=OFF` |
| Windows MFT | `platform/windows-reverse/mft_encoder.cpp:149`：更新 `ICodecAPI` 平均/最大码率；`:189` 可请求关键帧 |
| macOS | `platform/macos/window_codec.mm:69`：更新 `AverageBitRate/DataRateLimits`，按画布限制 24–80 Mbps；`:168` 请求关键帧 |
| 原生桥接 | `crates/viewflowd/src/native_quality.rs:125`：能力探测后每 200 ms 向本地子进程发送 tag 7 质量记录，远端旧反馈格式不变；`:94` 用 QUIC 和本地接收队列反馈采样 |

**差距**：Viewflow 已有比本次 Sunshine 更完整的网络质量闭环，但没有统一的
连接线速预算：lane、alpha、控制、重传均占共享链路；实际 `udp_tx.bytes` 还是连接级值。
增加 FEC 后必须将 parity 一并计费。也应测应用排队年龄与实际发出时间，而非继续增大缓冲。
当前检查的 transport 配置没有应用层 DSCP 策略；QoS 可以实验，不能代替拥塞控制。

## 6. 延迟、解码提交与陈旧画面

### Moonlight / Sunshine

`M:src/VideoDepacketizer.c:initializeVideoDepacketizer` 给 decode unit 队列上限 15。
完整帧提交有 direct-submit 和排队两种路径；队列满时清空并请求 IDR，不结束串流。
`M:src/VideoStream.c:VideoDecoderThreadProc` 向 decoder callback 提交完整 decode unit；
FEC 成功意味着编码帧重组完成，不代表解码或物理显示完成。

`Q:app/streaming/video/ffmpeg.cpp:FFmpegVideoDecoder::submitDecodeUnit` 合并编码包，
调用 `avcodec_send_packet`；解码线程通过 `avcodec_receive_frame` 取画面，再交 Pacer。
错误返回 `DR_NEED_IDR`，连续失败 20 次触发 decoder/renderer reset 事件。

`Q:app/streaming/video/ffmpeg-renderers/pacer/pacer.cpp:Pacer::handleVsync/renderFrame/submitFrame`
分别控制显示节奏、呈现和入队。每个 pacing/render 队列硬上限 3；
500 ms 队列历史决定容忍短突发还是丢旧画面，把稳定积压收紧到更低数量。
`dropFrameForEnqueue` 满时丢最旧的已解码帧，不破坏编码参考链，也无需因此发 IDR。
不能把“两个队列各最多 3”说成端到端最多 3 帧，解码器内部还有 surface/in-flight 工作。

`FFmpegVideoDecoder::submitDecodeUnit` 根据 frame number 间隙累加 `networkDroppedFrames`；
`Pacer` 用 `pacerDroppedFrames` 记录部分节奏丢弃，overlay 分别显示网络丢帧与抖动丢帧。
但硬上限路径 `dropFrameForEnqueue` 只释放 AVFrame，没有增加该计数。
帧号间隙也包括上游未交 decoder 的恢复性丢弃，不能当作原始 IP 丢包率或纯 decoder 丢帧。
`BandwidthTracker` 按编码完整帧字节计量，不包含 FEC、协议头和全部线速开销。

### Viewflow 与差距

`crates/viewflowd/src/atlas_session.rs:1893` 的组包路径使用 `push_latest`；
`:2071` 在送 decoder/native 前检查 frame freshness，迟到只丢相关帧并要求参考链恢复。
`crates/viewflowd/src/atlas_receiver_presenter.rs:561` 将 `CommittedLate` 映射为 committed，
保留已开始的原生呈现；`:972` 周围回报无法呈现的 `ExpiredUnbound`。
atlas manifest/颜色/alpha/窗口布局须成对绑定，不能把 Sunshine 的“最新桌面视频图像”
替换规则原样套到稀疏 atlas patch 或仅颜色的已解码缓存。

**差距**：已有 admission、disposition、native feedback，但没有统一展示
网络缺块、恢复等待、解码失败、呈现队列丢旧帧及物理显示延迟。
借鉴上游“解码后丢旧画面”的位置；对 Viewflow 先证明 atlas patch/alpha 缓存的依赖，
再压缩队列，不能丢了 patch 后把未更新区域当完整新画布。

## 7. 控制通道与加密

### Moonlight / Sunshine

现代控制走 ENet 可靠 UDP，而媒体走独立原始 UDP/RTP。
`M:src/ControlStream.c:startControlStream/sendMessageEnet` 建立 ENet peer 并按 channel 分流；
`S:src/stream.cpp:control_server_t::iterate` 服务控制事件。
与视频有关的主要消息如下，旧 GameStream 版本有不同 type 表，不能一概套用。

| 消息 | 现代 type / 发送特性 | Sunshine 本快照行为 |
| --- | --- | --- |
| 请求 IDR | `0x0302`，urgent reliable | raise `idr_events` |
| RFI 范围 | `0x0301`，urgent reliable | raise `invalidate_ref_frames_events` |
| 旧 loss stats | `0x0201`，旧路径周期发送 | 只日志 |
| periodic ping | `0x0200`，100 ms reliable，推动 RTT ACK | 回调为空；ENet 事件刷新存活时间 |
| FEC block 状态 | `0x5502`，现代 M 对 Sunshine 发 unsequenced | 未注册接收处理 |
| LTR ACK | `0x0350`，reliable | 未注册接收处理 |

`M:src/ControlStream.c:encryptControlMessage` 和
`S:src/stream.cpp:encode_control/controlBroadcastThread` 为 control protocol 13
包装 AES-GCM，带序号与认证 tag；旧协议的输入加密另有路径。
`M:src/SdpGenerator.c:getAttributesList` 协商视频加密 feature；
`S:src/stream.cpp:videoBroadcastThread` 在生成 FEC 后逐 shard 加密，32 字节前缀含
12 字节 IV、frameNumber 和 16 字节 tag。
`M:src/VideoStream.c:VideoReceiveThreadProc` 先认证解密再送 FEC 队列；认证失败包不参与修复。
因此 parity 本身也加密，重组使用明文 shard；不是对密文做 RS 再猜 AEAD tag。
视频是否加密受协商及 LAN/WAN encryption policy 影响，不能写成永远明文或永远加密。

ENet 可靠发送失败、首帧启动失败和真正 ping 失联在上游有结束连接的路径；
这不授权 Viewflow 把普通丢帧、短时拥塞或 33 ms 目标失败升级为断流。

### Viewflow 与差距

`crates/viewflow-transport/src/tls.rs:94`、`:118` 使用配对证书的 rustls 双向认证，
QUIC 统一保护可靠流及 DATAGRAM；`lib.rs:172`、`:263` 提供长度前缀、有序控制消息。
`atlas_session.rs:729` 创建独立 NACK uni stream，避免应用控制流的有序阻塞。
不同流仍共享拥塞窗口；不能把独立 stream 宣称为拥塞隔离。

**差距**：不需要新增 ENet、第二套密钥或明文 RTP。
新的 FEC/RFI/统计能力继续通过现有握手显式协商；旧端走现有 W1/IDR。
FEC 若放在 QUIC 应用数据报层，应编码媒体 payload，quinn 照常逐包认证；
不得修改 QUIC 密文或让恢复结果绕过原有帧身份、长度、generation 校验。

## 8. 其他 Wi-Fi 机制及不适用的推论

- **帧内刷新**：`S:src/rtsp.cpp:cmd_announce` 接受 `x-ss-video[0].intraRefresh`，
  默认 0。`S:src/nvenc/nvenc_base.cpp:nvenc_base::configure_h264_hevc_metadata` 的
  共享配置仅在请求值为 1 且硬件支持时启用，period=300、count=299，并按结构能力输出
  recovery-point SEI。它是可选能力，不能说所有 Moonlight 会话默认启用。
  Viewflow 上述 encoder 封装没有启用同等网络恢复策略，后续还需接收端恢复点语义。
- **slices / tiles**：`Q:app/streaming/video/ffmpeg.cpp:FFmpegVideoDecoder::getDecoderCapabilities`
  软件 decoder 请求最多 4 slices（受 CPU 核数限制）；
  `S:src/video.cpp:make_avcodec_encode_session` 按客户端、编码器标志、软件线程设置
  slices；`nvenc_base::configure_h264/configure_hevc/configure_av1` 对应 slice/tile 配置。
  主要用途是低延迟并行，当前接收器仍等待整帧全部 FEC block，不能据此宣称丢一个
  slice 仍显示残帧。Viewflow 的 HEVC tiles/稀疏 atlas 分块也不是传输层 FEC。
- **错误隐藏**：Moonlight 的 decoder capability 与 RFI 等待逻辑限定损坏参考链恢复。
  本次未发现网络层把缺失的帧片段直接作为完整帧提交 decoder 的设计。
  驱动/codec 内部的 concealment 效果未验证，不应把容错预算交给未证明的硬件行为。
- **连接检查**：`M:src/ConnectionTester.c:LiTestClientConnectivity` 是端口可达性检查；
  `Q:app/streaming/session.cpp:Session::clStageFailed/clConnectionTerminated` 的失败诊断会用它。
  它不是串流前的有效带宽探测，也不保证链路质量。
  Viewflow `doctor` 目前的身份、握手和平台诊断见 [doctor.md](doctor.md)，
  网络容量/丢包诊断仍可按 [weak-network.md](weak-network.md) W3 扩充为可选提示，
  不得作为启动许可门槛。

## 9. Viewflow 建议与优先级

以下参数是建议的首轮实验矩阵。所有项都**不与 AGENTS.md 可用性原则冲突**；
每项局部失败均保留会话、输入控制读取及无关 lane。性能目标错过只产生指标和局部恢复。
协议变更指远端 wire 协商；本地编码器能力探测不等于远端协议变化。

| 优先级 | 具体建议 | 预期收益（待测） | 成本与边界 | 协议协商 | 政策约束 |
| --- | --- | --- | --- | --- | --- |
| P0 | 统一每 lane/plane/generation 的发送、缺块、修复、IDR、解码、呈现统计；区分 original late 与 repair；每 200 ms 汇总，5 秒日志 | 分清随机丢包、拥塞与 decoder 饱和，给 W2/FEC 决策输入 | 中；分母必须是已知媒体片数，全平面丢失靠 manifest 计数；远端反馈可合并更新 | 仅本地指标否；增加精确 manifest 计数及远端统计需可选版本 | 统计丢失不得断流 |
| P0 | 修复包使用统一发送仲裁/有界预算，禁止修复挤掉其他 lane 的旧待发媒体 | 减少重传引起的二次缺块 | 中；仅检查空间有并发竞态，须覆盖所有数据报所有者；先用拥塞回环证明语义 | 否，发送端本地变化 | 空间不足只跳过修复，不关闭连接 |
| P0 | 应用层有界 block FEC，先测试 D=16/32/64，P=ceil(D×10%/20%)，D+P≤255；每帧每 plane 独立、多 block，无 4-block 人为上限 | 在一个 RTT 之外修复随机丢包，减少大 IDR | 高；CPU/SIMD、内存、补零、parity 带宽；短 block 抗突发能力须实测 | 是，`fec_version`、算法、D/P 上限、block/plane 标识和原始长度 | 失败转 W1/局部 IDR；资源超额只放弃该帧 |
| P0 | 按连接计费 FEC/alpha/NACK/控制，保留各 lane 质量上限；Auto 拥塞时优先收缩编码预算和旧工作 | 防止 parity 把 Wi-Fi 推入更严重排队 | 中；需要明确连接实际速率与各 lane 消耗，不能简单平均分配而降低前台质量 | 发送端本地调度否；依赖远端新统计时需版本 | HighQuality 保持现有语义，拥塞不得结束会话 |
| P1 | 修复入队前检查预算，避免 `send_datagram` 淘汰其他 lane；FEC 快速修复优先；未修复且剩余目标≥RTT 时沿用一轮 W1 NACK；再局部 IDR；缓存已解码可用画面 | 降低恢复等待与 IDR 频率，保留旧端兼容 | 中高；必须分别计 FEC 成功、NACK 迟到、修复字节；不延长目标掩盖积压 | FEC 部分是；现有 NACK 语义可保留 | 保留 W1 静默恢复定时器，过期只丢帧 |
| P1 | 先测 quinn 队列年龄，再限制应用待发送帧/字节；保留 quinn pacing；按 lane 轮转准备 block，抑制大 IDR 独占排队 | 减少 Wi-Fi 突发和旧数据滞留 | 中；检查 send_datagram_wait、GSO/batch、共享 cwnd；不能用固定 800 Mbps 代替链路测量 | 否，发送调度本地变化；若跨帧重排破坏现有 admission 需先改契约 | 丢弃前维护参考链，仅恢复受影响 lane |
| P1 | NVENC 小范围 RFI 原型；能力按 codec/encoder/decoder 双向协商；范围带 lane、plane、config generation；超出 DPB 或 API 失败回 IDR | 减少整帧 IDR 突发 | 高；现有 FFmpeg 封装缺失效 API；alpha/patch 基线须一起定义，不能把单桌面 RFI 直接平移 | 是，并扩展本地编码器 ABI；不支持端维持 IDR | 不增焦点、新鲜度或授权门槛 |
| P1 | MTU/包长可见化：记录 max_datagram_size、QUIC PMTU/变更和 TooLarge；FEC shard 始终扣完应用头 | 降低隧道/IPv6 下碎片与大包失败 | 低中；先用 quinn 默认 1200+PMTUD；可做保守应用 payload 对照，不固定照抄 1392 | 固定现有分片无需；FEC 变更 shard 大小时需标识 block 参数 | 探测失败回退小包，禁止断开已有会话 |
| P2 | decoder 后有界最新画面队列，分别记录 decode/present 丢弃；按 atlas patch/alpha 依赖安全压缩 | 限制显示延迟，不引发不必要 IDR | 高；窗口布局、alpha、稀疏增量不同于完整桌面视频；须先证明缓存不丢基线 | 纯完整画面缓存否；新 patch 依赖契约可能需要 | 迟到呈现和局部恢复并存，无 33 ms 退出 |
| P2 | 可选 NVENC intra-refresh、slice/tile 对照；AMF/QSV/VT 只按已接通并验证的能力声明 | 平滑刷新峰值/改善并行，收益取决于 codec | 高；编码效率、恢复点、解码兼容与 alpha 成对语义均需验证 | 刷新恢复语义和能力需要；纯 slices 编码配置通常无需新 wire | 不支持就保留现有编码器，不阻断使用 |
| P2 | 可选 QoS 和连接诊断，比较 DSCP 开/关及 AP 实际队列；保留本地提示 | 特定 Wi-Fi 设备上降低竞争延迟 | 中；平台权限、AP 重标记、同 QUIC 连接混合流量；先测再选 DSCP | 否，端点选项；无需另开 ENet | 失败只日志，诊断不成为许可或连通性门槛 |

### FEC 首轮参数的进一步决定

1. 无丢包时 FEC=0，保持弱网方案的有线基线；诊断实验可显式固定 10%/20%。
   Auto 在连续观测到媒体缺块但 RTT/排队稳定时逐步启用；持续拥塞先降编码预算，
   不因丢包直接无限加 parity。退出冗余需滞回，首轮可以用 5 秒稳定窗口。
2. 默认试 D≤32、最多 P=8（25%）的自适应档；同时测试 D=16/64 与 10%/20%固定档。
   这些档不是照搬 Sunshine 默认 20% 的承诺，按成功修复率、CPU 与线速比较再选择。
3. 小 block 至少 1 parity 作为实验档；另测至少 2 parity 的档位。D=1 时 1/2 parity
   分别带来 100%/200% 载荷冗余，必须计入预算，不能称作 10%/20% 开销。
   0% 档不强制最小 parity。透明 alpha 与颜色分别测，不能牺牲 alpha 保真。
4. FEC 描述必须包含源帧身份、lane、plane、generation、block index/count、D/P、
   shard index/size、原始末片长度。协商上限限制分配，但超额只局部丢弃。
   每平面拥有自己的 block，首轮不做跨帧 FEC，不把两个 lane 混入一个恢复矩阵。
5. 相邻 shard 连发对 burst loss 不利；先测按两个 lane/block 轮转发送，
   不等待下一帧积攒交织深度。接收端仍保留 W1 的新帧替代与静默到期机制。
   parity 太晚即无益，测完成时间而非只测最终收到多少包。
6. `fec_version=0` / 旧端维持现有 VFMD+NACK；新格式不得无协商塞入 v1 数据片。
   优先独立 parity 记录，明确定义可恢复的是应用 payload 和校验后的媒体身份。
   RS 库另选与项目许可兼容的实现，本次 nanors 只用于设计理解。

## 10. 后续验证与验收标准

后续实现项按以下矩阵验收，本次没有执行这些运行测试：

- 确定性丢片：无丢包、每 block P 个缺片、P+1 个缺片、parity 丢失、整个 alpha 丢失、
  manifest 迟到、首/中间/末 block 全丢、重复/乱序、跨帧/plane/generation 混片。
  检查恢复字节与原始编码 payload 完全相同，并证明只影响相关 lane。
- 网络：1%/5% 随机丢包、连续 2/8/16 包突发、20 ms 抖动、5/10 Mbps 限带宽，
  RTT 分别 2/20/60 ms；比较 W1、FEC、FEC+W1 的 p50/p95/p99 完成延迟、线速、
  IDR 次数、恢复率、CPU 与队列年龄。连接、控制和其他窗口持续可用。
- 双 lane、多窗口、alpha 复用、稀疏 patch、大 IDR、MTU 变小、新旧能力两方向兼容。
  不用单视频/单 lane 成功代替 atlas 联合恢复证明。
- 有线无损时 FEC 自动回 0；不新增等待、编码质量或视觉回退。记录编码目标与实际线速，
  区分网络缺片、解码错误、节奏丢弃、原生提交、物理显示。
- Windows/macOS 的 API 生效与解码恢复独立验收。真实鼠标/键盘和焦点测试由用户操作。

## 11. 本次文档检查

本次新增此报告，并从 `docs/README.md`、`docs/weak-network.md` 添加入口。
同时修正弱网文档中 `send_datagram` 缓冲语义的描述，保留历史验证记录。
已验证：本地 Markdown 链接与标题锚点检查通过，Viewflow 源码路径与行号范围检查通过，
上游引用函数/字段名称存在性检查通过，`git diff --check` 通过。名称存在性检查不代替
调用链阅读或运行验证。没有将历史 W1/W2 测试数字当成本次运行结果。
