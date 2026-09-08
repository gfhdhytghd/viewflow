# 4K 长停顿：传输与 EGL/CUDA 的分段证据

2026-09-08，Linux → Windows 隔离双端。源端已使用 alpha 输出所有权转移，Windows 已启用不可变 alpha 复用。内容为 3840×2400，捕获含边框为 3848×2408，alpha atlas 为 3968×2432。**本轮完成故障定位，尚未达到 4K60、两帧内延迟。**

## 结果与边界

每轮发送 25 秒；源端 124 是计划 timeout，接收端 1 是源端结束后的 peer close，所有 runner watchdog=0、observer=0、隔离进程退出。完整原始日志、fixture、校准、阶段统计见各子目录及 [summary.json](summary.json)。

| 轮次 | 接收端原生 commit/s | 反馈中位 / P95 / 最大 ms | 反馈 >100 ms 次数 | 捕获→桌面被观察到的时间上界中位 ms |
|---|---:|---:|---:|---:|
| stages，逐帧阶段 | 54.414 | 6.457 / 15.244 / 297.046 | 3 | 59.171 |
| poll，另加每 5 ms 连接采样 | 55.000 | 6.377 / 16.829 / 193.320 | 2 | 60.124 |
| no-gso，仅关闭源连接 GSO | 54.049 | 6.443 / 17.160 / 346.532 | 2 | 58.759 |
| pktmon，另加 10 秒包捕获 | 49.259 | 见 JSON | 见 JSON | 61.036 |

原生 commit 不是物理呈现凭据；桌面观察器可能错过第一次出现，因此最后一列也不是精确首次显示延迟。PktMon 轮作为网络诊断单独保存，不作为优化收益基准。所有轮次都开着逐帧日志和桌面观察器。各轮的原始四时间戳校准均通过现有分析器复算。

## 1. 慢帧并非都卡在发送队列

`4k-longtail-poll` 第 615 帧有 150 个媒体 datagram，203,664 字节。发送方约 0.183 ms 内完成应用排队。接收端的第一个应用派发在编码完成后约 5.47 ms，最后一个约 188.99 ms，反馈约 193.32 ms。

独立采样进一步显示：编码完成后 1.70 ms，源端累计 UDP 传输生成计数已增加 158，datagram 队列空闲空间也已恢复。核对当前 Quinn 0.11.11 / quinn-proto 0.11.17 源码后确认：`udp_tx` 在 `poll_transmit` 生成传输单元时增加，早于 `poll_writable` / `try_send`，因此也不能称为 socket 发送完成。该计数包含连接上的其他控制/时钟数据，不能把每一个 UDP 包绑定为这帧的媒体包，更不能称为 NIC 发出时间。但它排除了“这 190 ms 都留在发送应用的 datagram 队列里”的解释。

同一窗口，接收端连接的 UDP 处理计数反复以 **10 个包**增长，相邻批次相隔约 15–20 ms。源端采样最大间隔 6.70 ms，接收端最大间隔 15.51 ms，没有整段 190 ms 的采样任务停摆。QUIC 丢包和拥塞事件计数始终为零。**目前只能把停顿缩小到源端 QUIC 传输生成之后、接收端连接处理之前/之中；尚未区分 QUIC socket 驱动、主机 bridge、QEMU、网卡驱动、Windows 网络栈与某个连接任务的调度。**

`4k-longtail-no-gso` 第 1043 帧关闭 GSO 后仍出现 346.5 ms 反馈等待：源 UDP 传输生成计数约 2.77 ms 已增加 187，接收端最后包约 323.24 ms，manifest 派发约 341.53 ms。这个实验不支持关闭 GSO作为修复，因此测试开关已从最终源代码撤回；正常 QUIC 拥塞控制和发送配置未调整。该实验二进制未单独留存，日志保留了 `atlas-quic-gso enabled=false`，其他诊断源与前后轮相同；不要把最终源码哈希冒充该实验二进制哈希。

## 2. EGL/CUDA 存在另一类独立的长停顿

新增累计时间点覆盖导入子步骤、提前退出和局部资源析构。以下数字来自同一帧，阶段增量由相邻累计时间相减；它们是主机壁钟，包含驱动内部等待和调度，不能解释为 GPU 执行时间。

在 `poll` 第 1048 帧，EGL image 创建约 42.814 ms，纹理绑定约 65.231 ms，`glFinish` 约 0.005 ms，CUDA 注册约 133.493 ms，映射约 0.025 ms，函数总计 242.569 ms。这一帧干净过期后恢复，并未结束会话。

同轮第 493 帧，编码、输出和显式 cleanup 累计约 10.114 ms，局部 prepared tile 的 `cudaFree` 又耗时约 68.231 ms，总计 78.346 ms。此前只在成功路径结束前打印的汇总会漏掉这部分析构耗时。第 494 帧随后又在 EGL image/绑定处耗时约 172 ms。

下一步值得单独验证的是 prepared tile 生命周期复用，以及对相同底层 DMA-BUF 的有界导入复用；必须保留资源所有权、同步完成和原生像素验证。已有证据不足以直接删除同步或承诺这会解决全部尾部延迟。

## 3. Windows 环境与包捕获的局限

当前虚拟机使用 QEMU `-device e1000`，Windows 为 `Intel(R) PRO/1000 MT Network Connection #2`，驱动 `E1G6032E.sys`；中断合并开启且为 Adaptive。只读检查还得到 `NetworkThrottlingIndex=10`、`SystemResponsiveness=20`。这些环境值与“每批 10 包”的观测构成排查线索，**不是已确认的因果关系**。未修改注册表、网卡属性、VM 配置或当前桌面运行版。

PktMon 预检为空闲且无过滤器；本轮只添加 `ViewflowIsolated49073`（UDP、源主机 IP、测试端口 49073），持续 10 秒后停止并删除这个过滤器。ETL 声明 events/buffers lost=0，但转换出的 4,900 条记录全部是 Tx，包含跨组件重复观察，**没有 Rx 记录**，所以不能用它证明接收侧的 NIC/内核时间。原始 ETL、pcapng、UTF-8 转换文本、组件元数据和时钟锚点压缩保留以便复核。

最终复查：PktMon 停止、无过滤器、WPR 停止、隔离进程为 0；测试 fixture 规则恢复 disabled。参见 [Windows 状态](longtail-final-windows-state.txt)。

## 4. 代码与验证

- `VIEWFLOW_ATLAS_TIMINGS=all` 增加逐帧 QUIC 计数、首尾媒体派发、manifest 派发、配对完成及处理后时刻；计数表最多保留 4 帧。时间标签明确为应用派发，而非网络到达。
- `VIEWFLOW_QUIC_POLL=1` 才启动每 5 ms 连接采样；跳过错过的 tick，任务随连接作用域取消，不保留失效连接。
- `VIEWFLOW_GPU_TIMINGS=all` 覆盖全部编码尝试；有界 RAII 时间点包含提前退出、EGL/CUDA 子阶段和 prepared tile 析构，不改变 GPU 同步行为。
- 发现 poll 轮 2 条 wire timing 记录被跨 Rust/C++ 日志写入打断，已显式排除。源端 wire/source timing 改为一次完整写入后，no-gso 与 pktmon 轮没有这类缺字段 wire 记录。原始日志仍完整保存。

Linux release 构建通过；Linux atlas_session 33 项通过、feedback 1 项通过；Windows release 构建通过，atlas_session 30 项通过、1 项原有 ignored；本机原生 C ABI/GPU 集成 3 项通过；分析脚本 7 项通过；`git diff --check` 通过。测试日志和 [最终诊断源码/源端二进制哈希](final-source-sha256.json) 同目录保存。Windows 当前原生 presenter 沿用上一轮已验证的 alpha 复用版本，本轮未修改其渲染行为。

运行保存的 `analyze-longtail.py`、`inspect-poll.py` 时从仓库根目录执行，并保留 `/tmp/viewflow-integrated-pair` 对应原始输入路径。子目录中的压缩日志是可重新展开的原始输入。这些分析脚本是本轮取证辅助工具，不是新的性能达标测试。
