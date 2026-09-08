# AV1 窗口接收与 NVENC 分片实测

2026-09-08。补齐普通窗口模式的 AV1 codec 传递，并完成 Linux → Windows 六轮真实链路对照。**编码阶段变快，但没有验证 4K60 或两帧内桌面呈现。** 保留 AV1 窗口支持和可选分片诊断，默认 codec 与自动分片设置没有改变，日常运行版本未替换。

## 修复的实际问题

此前这套完整链路隔离配置实际使用 **H.264**，原生二进制也没有链接 AV1 解码后端；之前独立 AV1 fixture 的成功不能证明完整链路使用了 AV1。最初分片对照在没有读到 AV1 控制记录时中止。接着发现 Rust receiver 只允许 desktop 模式选择 AV1，普通窗口的启动函数仍固定为 H.264，第二次实验在 AV1 配置验证处中止。两次失败均恢复临时状态，保留在 excluded-runs 和 method 中，不计入六轮对照。

现在 receiver 将协商到的 color codec 传入普通显示、disposition recovery、pointer/wheel/keyboard 和 input recovery 启动路径；AV1 通过 `--atlas-color-codec av1` 传给原生程序。旧 H.264 启动接口和参数保持兼容。移除了已经被此次实现补齐的 desktop-only 限制；没有增加授权、焦点、时限或会话退出条件。输入顺序、目标路由与恢复状态机沿用原实现。

Windows AV1 使用现有 FFmpeg D3D11VA 解码实现，要求编译时设置 `VIEWFLOW_FFMPEG_ROOT`。本轮使用独立 `native-av1-build` 和 `vf-media-peer-av1.exe`，没有覆盖原 native-build 或默认 receiver EXE。原生 AV1 构建使用 FFmpeg 8.1 Windows LGPL shared SDK，Linux NVENC 使用当前 FFmpeg 9.0.1 和 RTX PRO 6000 / 610.57.04 驱动。六轮使用完全相同的接收器、原生程序、观察器和源端二进制。

源端增加可选环境变量 `VIEWFLOW_NVENC_SPLIT_MODE=auto|4`，只作用于 AV1。没有设置时保持原来的 NVENC 默认；无法设置该 AVOption 时尝试回到 auto。该选项回退不是对所有驱动初始化错误的兜底：驱动在 avcodec_open2 阶段拒绝配置仍会报告原有初始化错误。本机四路模式已实测接受，但不能推断所有显卡都支持相同分片数。

## 验证范围

- Linux：12 项 child 测试通过，新增用例实际启动并回收临时 mock child，逐项检查 H.264/AV1 × 六种窗口启动方式的完整 argv 和 ready capability；10 项 atlas_peer、4 项 receiver presenter 测试通过。
- Windows：Release receiver 构建通过；10 项 atlas_peer、4 项 receiver presenter 测试通过。child mock 模块仅限 Unix，Windows 的该筛选运行了 **0 项**，没有将它记为 Windows 启动验证。Windows 普通窗口 disposition 路径由后面的六轮真实进程验证；其他原生输入模式和 macOS 未在本轮实测。
- Windows 原生 AV1 构建、atlas frame binding 测试通过；AV1 GPU growth fixture 在 1024²、4096²、8192×4096 下通过，日志确认 ffmpeg-d3d11va、hardware_required=true。它证明 GPU 解码/合成与尺寸增长，不单独证明全部窗口像素正确。
- Linux NVENC：7 项 CTest、原有 4K GPU integration，以及 auto/4 两种 sparse AV1 实际输出测试通过。四份彩色/半透明 sparse 输出又经独立软件解码与已知输入的 YUV/alpha 对比：YUV 最大误差分别 0/1/0/1，alpha 全部逐字节一致。仅覆盖这些 fixture 的颜色、遮罩和合成，不是所有内容的画质保证。
- 本轮没有注入键鼠或改变测试焦点；fixture、headless output 和 proxy 均由实验创建。

## 六轮完整链路

源内容 3840×2400，实际含边框捕获 3848×2408，编码 atlas 3968×2432。Windows 实际输出为 6144×3456@60，Intel GPU；proxy 以 1:1 像素放置。观察器参数名 physical4k 不表示物理输出为 4K。每轮发送 25 秒、桌面观察 20 秒，顺序 H.264 → AV1 auto → AV1 four → AV1 four → AV1 auto → H.264。timer1、alpha reuse、GPU/socket tracing 设置相同。统计的编码阶段是 CPU 时钟记录的 host elapsed，包含既有等待，不是 GPU 引擎独占耗时。

| 轮次 | NVENC 中位 ms | 整段编码中位 ms | 每帧 wire 中位 KiB | 原生 commit/s | 所见 marker/s | capture→所见桌面上界中位 ms | P95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| h264-a1 | 4.192 | 6.879 | 29.10 | 57.89 | 40.02 | 51.65 | 66.24 |
| av1-auto-b1 | 2.053 | 4.762 | 92.31 | 57.83 | 41.03 | 49.83 | 66.61 |
| av1-four-c1 | 1.253 | 4.013 | 97.08 | 58.06 | 42.00 | 47.94 | 66.54 |
| av1-four-c2 | 1.251 | 4.000 | 96.67 | 57.44 | 40.18 | 48.38 | 67.00 |
| av1-auto-b2 | 2.050 | 4.788 | 92.77 | 57.98 | 41.11 | 47.69 | 65.41 |
| h264-a2 | 4.090 | 6.802 | 29.18 | 57.82 | 40.20 | 48.77 | 65.34 |

[完整统计](comparison.json)。AV1 auto 的 NVENC 阶段约为 H.264 的一半；four 相比 auto 再缩短约 0.80 ms（约 39%）。但当前画面在同为数字 QP=10 时，AV1 auto/four 每帧 wire 分别约 92/97 KiB，H.264 约 29 KiB；相同 QP 数字不是跨 codec 的同等画质标准，不能据此声称 AV1 压缩效率更差或画质相同。

encoded→pipe admission 的中位时间从 H.264 的约 3.69 ms 增到 AV1 的 5.78–6.04 ms，而 pipe admission→decoded 约 1.38–1.55 ms。编码节省被增大的传输/接收/pipe 阶段部分抵消。four 的 capture→mutation 上界中位约 14.37–14.74 ms，auto 约 15.10–15.33 ms；最终 mutation→所见桌面仍约 32–35 ms。阶段中位数来自各自样本，不能直接相加作为同一帧的总延迟。

原生提交率没有稳定提高到 60；four 两轮所见 marker/s 也一高一低。最终延迟中位数有交叠，P95 仍约 65–67 ms，不能宣称已实现稳定的最终显示加速。保留显式选择 AV1 的可用路径和分片测量开关，但没有改默认 codec、默认分片策略或强制切换用户配置。

## 同一编码器微基准与颜色校验

独立 GPU-resident 微基准使用 3968×2432、16 张已上传 NV12 图案、330 帧，前 30 帧不计入耗时。P1/ULL、无 B 帧、lookahead=0、delay=0、constQP=10，逐帧核对 packet PTS。auto A1/A2 的 send/receive 中位约 1.922/1.915 ms；four 约 1.170 ms；disabled 约 3.459 ms。auto 两次 330 个 packet 逐字节一致，four 与 auto 不同，明确说明分片路径改变了编码结果。

该灰色文字图案下，four 的平均 packet 约 37,561 B，auto 约 22,609 B，增加约 66%；这是微基准结果，不能套用到完整链路的约 5% auto→four 差异。软件解码核对 330 个 PTS，测量其中 300 帧、2,895,052,800 个亮度样本：auto/four 亮度 PSNR 约 68.86/69.06 dB、最大亮度误差均 2、色度误差为 0。此结论仅限这个灰色图案。AV1 头部两种模式均解析到相同的五个非均匀 tile rows；tile 数与 AVOption 读回不能证明实际用了几个物理 NVENC 引擎。

源与 packet/CSV/头部输出在 [nvenc-microbench](nvenc-microbench/)；彩色 sparse 原始输出在 [sparse-fixtures](sparse-fixtures/)，其独立校验结果为 [sparse-quality.json](method/nvenc-split-sparse-quality.json)。

## 像素身份与时钟边界

六轮唯一 marker 配对依次 784/804/830/793/814/795；重复捕获导致的歧义 marker 为 7/6/0/4/0/0，全部排除，没有使用邻近帧补配。原始四时间戳交换复算有效，使用的 clock mapping 有效期覆盖桌面端点。marker、正的 LastPresentTime、异步 slot sequence 严格递增；配对 commit→desktop 与 mutation→desktop 无负值；所有 readback ring abandoned=0、pending_peak=2。

four C1 和 auto B2 各有一条源端编码日志被并发写入打断，缺失 total 数值；分析器保存其解析内容并从整组编码耗时统计排除。其他编码行和 wire 行完整。没有为了得到更低的延迟删除有效长尾，最大 capture→所见桌面上界为 104–207 ms。

桌面观察器会漏读帧，所见 marker/s 不能等同真实显示 FPS。LastPresentTime 对应被读到的桌面内容，不能保证是该 marker 首次呈现的时间；延迟上界包含跨机时钟不确定度。GPU copy probe 只有本进程 D3D 队列完成的轮询边界；部分 completion→desktop 下界为负，原样保留，不当作精确完成时刻。没有把 readback 耗时从 LastPresentTime 延迟中减去，也没有把 native commit 当作屏幕已显示。本次没有新增光学测量或物理 4K 输出验证。

## 控制与恢复

每轮前后读回 ESRV 进程及当时两个 TimeCritical 线程均为 Normal/base8，并确认没有其他 TimeCritical 线程；没有持续记录整段优先级。独立 10 分钟 SYSTEM 恢复任务以 PID、进程及线程创建时间绑定。六轮结束后 finally 恢复 High/TimeCritical 并移除任务，没有停止、重启或禁用服务。

所有 source 均按计划超时停止；receiver 随 peer 关闭，watchdog=0；观察器 exit=0。临时 Linux output 已移除，前后完整 monitor 列表与焦点读回一致。发送/接收配置逐字节恢复。最终现场核验为 ESRV Running/Auto、PID 2344、High、两条 TimeCritical；实验进程与任务均为 0。

原 native EXE 保持 `81CB49DD9269A50B7FB6124539F8034EDB094BD54700707E2BDF0F2E1442E0B4`；默认 receiver 恢复 `A39CB1F4BD003EC3EE1237AF05D9915316E86119DC21FBE1C9F626CE61B3C30A`，匹配 PDB 与备份一致。独立 AV1 receiver/native EXE 分别为 `CE6DD99EF6484C06D5EBDFA1C2406CC5E4830CCC19B1BD5EDBA01DF3C71BC705` / `BC92FDCA50A98F0BED563C1CFF13ED91A8751FD9093C9431464D755260C9F38E`。初次备份脚本误用了 Rust PDB 的连字符文件名，未开始构建即失败；实际名称为 vf_media_peer.pdb，更正后完整备份、构建、恢复并核对一致。[最终状态](method/codec-final-state.json)、[六轮控制记录](method/codec-split-state.json)

## 复算

每轮保存压缩原始 source/receiver/desktop/producer/runner/cleanup/driver、fixture JSON、唯一 marker 配对和摘要。method 保存实际构建、执行、恢复与分析脚本；source 保存测试版本与打包原生编译输入。归档后仅收窄了当前 C++ 注释中对 AVOption 回退的描述，明确驱动初始化错误不在回退范围；可执行逻辑未改变。绝对路径指向当时隔离环境，重新运行状态修改脚本前需要重新解析当前机器和进程身份。

纯分析复算：将每轮 source/receiver/desktop 解压到 `/tmp/viewflow-integrated-pair/{kind}-{label}.log`，producer 解压到 `/tmp/viewflow-frame-fixture-first/{label}-source.log`；在包含 source/tools 两个 Python 依赖的 tools 目录的工作目录下，运行 `method/summarize-codec-split.py` 并依序传入表中六个带 `4k-codec-v2-` 前缀的 label。没有网络或桌面写操作。SHA256 清单覆盖本目录全部文件，清单自身除外。

[NVIDIA Video Codec SDK 13.1：Multi-NVENC Split Frame Encoding](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/nvenc-video-encoder-api-prog-guide/index.html#multi-nvenc-split-frame-encoding-in-hevc-and-av1) 说明 AV1/HEVC 的自动/强制分片、硬件数量限制及质量/码率权衡；这里的性能判断以本机实测为准。目标仍是 4K 下 60fps、延迟不超过两帧，本证据未证明已达成。
