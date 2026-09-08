# Windows 观察器等待精度与 WGC 端点对照

2026-09-08。完成 10 轮隔离实验：1 轮 WGC 冒烟、1 轮同时观察窗口与桌面、4 轮桌面观察器 timer0/1 交错对照、4 轮窗口观察器 timer0/1 交错对照。**观察器自身读回延迟下降，但没有稳定的 FPS 或桌面呈现延迟收益。4K60、两帧内呈现仍未验证。**

## 保留的实现

- 新增独立 `windows_window_frame_observer.cpp`，通过 WGC 捕获指定 PID 的唯一 ViewflowAtlasProxy 窗口，只读取测试 marker 的一行像素。三槽 staging ring 保留每次捕获的 frame、时间戳、序号，直到非阻塞 Map 成功才归还源 frame；不会把较新的时间戳配给旧像素。WGC 回调只唤醒事件，读回与解码在观察线程完成。
- 桌面与窗口观察器复用现有 TimerResolutionGuard，默认请求进程内 1 ms 定时器精度，退出时配对释放；`timer0` 禁用、`timer1` 启用，用于对照。每次启动记录请求结果与 8 次实际 1 ms 等待。请求成功不代表实际能在 1 ms 内唤醒。
- 原生接收端、视频合成器与源端二进制未因本轮实验而改变。观察器是测量工具，这些变更不能计为产品性能改善。

工具参数为 `PID duration_ms log_path [physical4k] [timer0|timer1]`。`physical4k` 是历史参数名：将本次测试自己的窗口以 NOACTIVATE 放在至少 3840×2400 的输出上，并核对 3848×2408 的客户区。它不检测或证明输出是物理 4K 显示器。实际本轮为 Intel GPU、6144×3456@60 Windows 输出，3840×2400 测试内容含边框后 3848×2408，以 1:1 像素放置。没有注入键鼠或改变焦点进行测试。

WGC 保留系统默认捕获边框，关闭捕获光标。第一次冒烟在加入关闭光标调用之前完成，保存了对应源代码；之后的双观察与 timer 对照均使用关闭光标的版本。

## 桌面观察器交错对照

timer0 与 timer1 使用同一个最终编译的观察器，仅命令行选项不同。顺序为 A1/B1/B2/A2，各轮 25 秒视频、20 秒观察。以下为每轮中位数；两端速率分别以原生日志和观察到的不同 marker 时间戳计算。

| timer / 轮次 | 原生 commit/s | 桌面所见 marker/s | 实际 1 ms 等待，ms | 观察器读回跨度，ms | capture→所见桌面上界，ms |
|---|---:|---:|---:|---:|---:|
| 0 / A1 | 57.14 | 38.14 | 18.20 | 17.57 | 51.13 |
| 1 / B1 | 57.41 | 39.73 | 4.95 | 11.36 | 52.90 |
| 1 / B2 | 58.03 | 40.47 | 4.67 | 11.39 | 54.43 |
| 0 / A2 | 58.56 | 42.03 | 18.26 | 15.43 | 50.41 |

最后的 timer0 轮帧率高于两个 timer1 轮，因此不能把首次 A1→B1 的变化归因为 timer1 的 FPS 收益。请求精度确实缩短了实际等待和观察器读回跨度，但 capture→桌面统计没有改善。[逐轮统计](desktop-comparison.json)

`copy_map_us` 含排队、两次轮询之间的延迟及成功 Map/解码时间，不是纯 GPU 执行时间。成功 Map 与解码约 10 μs 是 QPC 壁钟跨度，不是线程 CPU 消耗。timer1 会增加非阻塞 Map 轮询次数。该请求只在有限时长的诊断程序生命周期内使用。

桌面端点为本次读到 marker 的 DXGI `LastPresentTime`。观察器会漏读更新，同一 marker 也可能出现在多个桌面更新中，因此它尚不能确定首次呈现。表中的上界计入跨机时钟不确定度，但不能当成真实首次显示延迟；JSON 中相应 two-frame 计数也不能作为目标通过/失败判据。不要把读回耗时从使用 LastPresentTime 的延迟中直接减去。

## 窗口观察器对照

| timer / 轮次 | 原生 commit/s | 窗口所见 marker/s | 实际 1 ms 等待，ms | 观察器读回跨度，ms | capture→WGC render 上界，ms | render 时间晚于取得 frame 的样本 |
|---|---:|---:|---:|---:|---:|---:|
| 0 / A1 | 58.36 | 34.36 | 18.25 | 11.83 | 41.38 | 25 |
| 1 / B1 | 57.28 | 33.18 | 4.65 | 5.06 | 41.44 | 16 |
| 1 / B2 | 58.56 | 33.82 | 4.36 | 5.24 | 41.37 | 22 |
| 0 / A2 | 58.65 | 33.83 | 18.22 | 13.20 | 41.36 | 29 |

窗口观察器读回跨度下降到约 5 ms，但仍只读到约 33–34 次不同 marker/s。它的时间戳是 WGC `SystemRelativeTime`，**不是 DXGI 桌面 LastPresentTime**。原始记录中确实存在 render 时间晚于取得该 frame 的情况，保留并计数，没有丢弃或减常数校正。它不具备本实验所需的首次桌面呈现证明力，不能拿约 41 ms 与桌面观察器约 50–54 ms 的差异声称优化成功。[逐轮统计](window-comparison.json)

第一次窗口冒烟为 56.97 native commit/s、32.59 window marker/s，capture→WGC render 上界中位 41.31 ms；同时开启两种观察器的一轮为 57.42 native commit/s、34.89 window marker/s，窗口端上界中位 57.94 ms。双观察也会改变负载，不是无扰动基准。

双观察轮对同一像素 marker 配对 619 组，WGC render 减 DXGI desktop present 中位 -6.57 ms、范围 -41.24 至 +32.21 ms，其中 183 组 WGC render 晚于桌面端已报告的同一 marker。这进一步证明两个端点不能互换，也不能拟合一个固定差值替代首次呈现测量。只在其中一个观察器出现的 marker：窗口 60 个、桌面 37 个。[双端统计](dual-comparison.json)、[逐 marker 配对](dual-pairs.json.gz)

## 验证与恢复

Windows MSVC Release 原生编译了两个观察器。10 轮观察器均实际返回 0，各轮源端按计划在 25 秒后退出，receiver 随 peer 关闭，watchdog 未触发。所有 ring 最终 abandoned=0。像素使用 64 位 frame/input/checksum 验证；窗口样本与源捕获、原生 commit 唯一匹配，重复捕获身份不用于延迟统计。保存原始四时间戳交换并通过已有分析器复算，映射有效期覆盖使用的结束时间，窗口捕获上界与 commit→render 没有负值。WGC 的 future-render 现象另行保留，不以这些其他检查掩盖。

所有对照均临时把 ESRV 进程及当时两个 TimeCritical 线程降为 Normal，以保持先前已验证的调度条件。每组先建立独立 10 分钟恢复任务，再检查 PID、进程/线程创建时间；每轮前后核对实际优先级，无其他 TimeCritical 线程。这里是前后读回，不能声称持续跟踪了整个期间的优先级。各组 finally 已恢复原来的 High + 两个 TimeCritical，并删除恢复任务。未重启或停用服务。

最后读回时间 2026-09-08 06:38:43 -04:00：服务 Running/Auto，PID 2344，High，线程 12232/16604 为 TimeCritical；实验所属进程和计划任务均为 0。各组本次创建的 Linux 输出已移除，前后 monitor 列表一致，焦点读回一致。[最终状态与二进制 SHA](method/observer-final-state.json)

最终原生接收端 SHA 为 `81CB49DD9269A50B7FB6124539F8034EDB094BD54700707E2BDF0F2E1442E0B4`；Rust receiver 为 `A39CB1F4BD003EC3EE1237AF05D9915316E86119DC21FBE1C9F626CE61B3C30A`，均与本轮开始前相同。两种最终观察器 SHA 和全部源文件 ledger 一同保存。早期无 timer 的 WGC 观察器二进制未单独冻结，不能为它编造二进制哈希；对应源代码及当时构建日志已保存。

## 复算材料

每个 trial 目录保存源端、接收端、观察器、runner、cleanup、producer 原始压缩日志、fixture JSON、逐帧配对与摘要。method 保存采集、独立恢复、构建及分析脚本；source 保存本轮观察器与分析器源代码。方法脚本中的临时目录和 Windows 隔离路径记录当时环境，不应不加检查地重复执行采集控制。

从仓库根目录复算：按 trial 目录名把 `source.log.gz`、`receiver.log.gz`、`window.log.gz`、`desktop.log.gz` 解压为 `/tmp/viewflow-integrated-pair/{kind}-{label}.log`，将 fixture 恢复为 `fixture-{label}.json`，producer 日志恢复到 `/tmp/viewflow-frame-fixture-first/{label}-source.log`。运行 `method/analyze-window-observer.py` 并传入六个窗口 trial 标签；运行 `method/summarize-observer-timers.py` 并传入四个桌面 timer 标签。`method/analyze-dual-observer.py` 保存双端逐 marker 比较。两个窗口分析步骤已从原始日志重新计算，与之前保存结果完全一致。

SHA256 清单覆盖本目录所有最终文件，清单自身除外。构建、像素校验和复算通过仅证明这轮诊断实现和证据一致，不代表达到了性能目标。

## API 语义参考

[Microsoft timeBeginPeriod](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod) 说明 Windows 10 2004 起该请求具有进程范围，不能假定接收进程的请求自动属于观察进程。[WGC SystemRelativeTime](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.direct3d11captureframe.systemrelativetime?view=winrt-26100) 描述 compositor render 时间；这里保留实验所见异常，不把 API 名称当作首次桌面显示证明。[CreateFreeThreaded](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.direct3d11captureframepool.createfreethreaded?view=winrt-26100) 用于后台 frame-arrived 通知。[D3D11 Flush](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-flush) 是提交而非 GPU 完成等待，代码以成功的非阻塞 Map 作为该槽可读取的依据。
