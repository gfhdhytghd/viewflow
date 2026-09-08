# UDP socket 边界：4K 长停顿定位

2026-09-08，Linux 源端与同机 QEMU Windows 接收端，单轮 25 秒隔离测试。内容 3840×2400，捕获 3848×2408。源端 scratch swap、alpha 输出所有权优化、Windows alpha 复用均开启。**原生 commit 约 56.78 次/秒；捕获→桌面被观察到上界中位 58.77 ms，仍未达到 4K60 / 两帧内延迟。** 这些结果属于带诊断的环境观测，不能作为这次 socket 包装器的性能收益，也不能称为物理显示帧率。

## 新证据：已越过发送 socket 调用，接收仍分批等待

第 885 帧反馈等待 209.264 ms，媒体包 172 个。以该帧编码完成为零点：

- 源端 `try_send` 在约 0.23–0.50 ms 内成功接受共 180 个 UDP datagram、258,699 字节；包含控制/时钟等连接数据，不能把全部包逐一认定为该帧媒体。此时间窗没有 WouldBlock、发送错误或 writable Pending。
- Windows 第一次 socket 接收批次在约 8.95 ms，随后连续 11 批均为 10 包，相邻约 13–20 ms。每批之后立即再次调用接收，返回 Pending；单次调用仅为微秒量级。
- 后续剩余包在约 201.37–206.22 ms 被连续读取。媒体最后应用派发在 203.519 ms，manifest 派发在 202.734 ms；反馈在约 209 ms 返回。QUIC 丢包与拥塞事件增量均为 0。

因此可以排除“这整段 200 ms 都在源端应用排队，或源端 socket 等可写”的解释，也不是原生解码器耗时。**剩余范围是 Linux 发送调用之后到 Windows socket/运行时可读之间，尚不能区分 host 网络、QEMU/e1000、Windows 网络栈/驱动、I/O 就绪通知和特定任务调度。** Pending 是运行时接收 API 的状态，不能冒充 NIC 到达时刻；这里也没有测量 waker 被唤醒的时刻。独立 probe 和本轮均没有修改网卡、注册表、QUIC 拥塞控制或主运行版。

第 615 帧呈现类似现象：源端约 0.35 ms 完成首批发送，Windows 约 19、40、55、73 ms 各返回 10 包，manifest 到 93.55 ms 才派发。另一方面，第 11 帧在 7.17 ms 已收齐，反馈却为 128.04 ms，说明接收后的启动/原生路径仍有独立长尾；不要用网络解释所有慢帧。

## 测量方法与校准

`VIEWFLOW_QUIC_SOCKET_TRACE=1` 才安装透明的 Quinn Runtime / AsyncUdpSocket / UdpPoller 包装器。原有收发结果、waker 参数、timer、分段能力与 socket 属性原样转交；不记录 payload。每次调用前后只记录单调时刻、操作、状态、字节/分段数。最多保留 500,000 条，锁内停止记录后在会话结束时输出；默认无此包装。源端正常 client 构造与 IPv6 dual-stack 行为保持原样。

本轮源端 33,802 条、接收端 77,177 条，omitted=0；分析器要求声明条数与解析条数完全一致。记录分配与内存锁仍可能造成诊断扰动，所以本轮不是无开销基准。系统 send 成功仅意味着接受了发送，不意味着物理网卡发出。

源端 socket 时间锚定 native 单调钟；Windows socket 时间锚定 QPC，再由接收会话 QPC 锚点映射到校准时间线。锚点保留前后夹取区间。767 条四时间戳交换复算通过，96 个映射，校准不确定度中位 ±0.138 ms、最大 ±0.295 ms；加上 QPC 锚点采样区间约 26–27 μs，远小于观测的批间长停顿。跨机器相对时间均是带此不确定度的估计。

[完整 socket 分段与逐调用记录](socket-summary.json)、[逐帧阶段统计](4k-socket-boundary/summary.json)、[原始校准](4k-socket-boundary/clock-and-stages.json)。压缩原始源端、接收端、桌面观察和 fixture/runner/cleanup 日志在子目录。`analyze-socket-boundary.py` 从仓库根运行，读取 `/tmp/viewflow-integrated-pair`；可先将保存的压缩日志展开为同名输入。

## 独立 UDP probe

本轮 socket 诊断之前，运行了不含 QUIC、渲染或输入的有界 Winsock `recvfrom` probe：端口 49073 空闲、49101 空闲、49101 与 4K 隔离流并行；固定 1400 字节包，20/150 包突发，完整批次才返回 ACK。每包有 batch/sequence 和本次 nonce，输出在收完之后写入，所有批次均完整。

空闲 150 包 RTT 中位约 2.91 ms，最大约 3.58 ms；并行时中位约 3.18 ms，最大约 52.30 ms。最慢批次的 Windows 首包到末包跨度仅约 2.36 ms；另一批出现过约 14.96 ms 的接收间隙。因此独立接收器没有持续复现“每批 10 包”，也不能把所有 RTT 长尾归因到接收 drain。源 probe 只保存持续时间，未保存绝对发包时刻，无法再拆出首包前与 ACK 回程各自的单向时间。两类试验批次间隔不同（空闲 16.7 ms、并行 100 ms），只用作诊断，不作直接速度 A/B。

原始 probe 源码、运行脚本、源端 RTT、接收逐包 QPC 和计算结果见 [plain-udp/summary.json](plain-udp/summary.json)。并行 4K 流的原始日志也一并保存。

## 验证与收尾

Linux 与 Windows 的 socket 包装器测试均通过：真实 UDP payload、RecvMeta 地址、先 Pending 后延迟回包的唤醒，以及记录的单调顺序。Linux 和 Windows release 构建通过；分析脚本 7 项测试通过，`git diff --check` 通过。本轮 Linux 源端按计划 timeout=124；Windows 接收端因源端关闭退出 1，watchdog=0；桌面观察器退出 0。

临时 HEADLESS 输出由脚本创建、只承载自有 fixture，测试后清空并移除；创建前后与最终 monitors JSON 完全一致，隔离任务/进程均为 0。全程没有鼠标键盘注入或主动切换焦点。PktMon 无运行/无过滤器，WPR 停止。状态与二进制哈希见 [windows-final-state.txt](windows-final-state.txt)、[owned-output-state.json](owned-output-state.json)、[source-sha256.json](source-sha256.json)。
