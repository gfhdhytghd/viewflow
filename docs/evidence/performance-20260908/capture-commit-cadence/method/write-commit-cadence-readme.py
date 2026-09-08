from pathlib import Path
import json,re
out=Path('docs/evidence/performance-20260908/capture-commit-cadence');rs=json.loads((out/'comparison.json').read_text())
s='''# 窗口提交触发采集：原型未采用

2026-09-08，独立嵌套 Hyprland → Windows H.264，A1/B1/B2/A2 四轮。

**这版原型没有形成可靠的完整延迟改善，已撤回生产源码。** B 两轮 fixture pre-draw→桌面记录的上界中位数为 58.73/58.56 ms；原策略 A1 为 67.22 ms，A2 为 54.57 ms。提交触发采集改善了较差相位，却比相位较好的基线慢约 4 ms。原生提交率 B 为 58.64–58.88/s，仍未证明稳定 60 fps，完整两帧内显示也未达成。

本轮保留的是实测证据和可重建原型，没有把这版策略设为默认。此前已采用的[捕获帧到达唤醒](../capture-readiness/README.md)仍保持默认启用，Linux 二进制未变。

## 为什么尝试

对上一轮原始日志重新配对，fixture swapBuffers 返回→capture 的中位数随运行相位约为 1.74–16.18 ms，而 capture 的 CLOCK_MONOTONIC 时间模 60 Hz 周期的中位偏移仅约 0.023–0.032 ms，符合现行采集固定全局时钟网格的实现。[配对和摘要](method/capture-phase-baseline.json)保存原始 marker/atlas/capture/render/swap 时间，统计从 atlas frame 30 开始的有效 marker，可含重复 marker，用于研究相位；不能代替桌面唯一身份配对的端到端统计。

这提示可以尝试在窗口内容提交后提前采集，但 swapBuffers 返回不是 GPU 完成或 Hyprland 内容提交完成时间，不能将整个跨度直接解释成一个 timer 的等待。[当前 Hyprland 提交实现](https://raw.githubusercontent.com/hyprwm/Hyprland/efb50993780079460b0cbed1363e2166a2de1d9f/src/protocols/core/Compositor.cpp)先更新 current state/texture，再发出 surface commit 信号；原型监听该信号，仅安排延后 timer，不在提交回调内重入渲染。

## 原型和对照

实验插件独立命名为 `viewflow-capture-commit-test.so`，Lua namespace 为 `viewflow_capture_commit_test`。同一个 SO 同时提供原 grid start 与新的 `window_stream_start_commit`，A/B 通过本地诊断 hyprctl shim 只替换这两个精确 API 名称及对应 stop namespace。Rust sender/receiver 二进制相同，源端 capture readiness 两种情况均为 1。正常桌面的插件未重新加载或覆盖。

新策略将同一 fps 的所有 stream 放入一个 cohort，共用一次采集调度。main wl_surface commit 标记该组为 pending；下一次符合帧率预算的 timer 尽快采集全部成员，成员仍各自保持未释放帧的 ownership。每次实际采集尝试起点之后至少一个 `1e9/fps` 周期才再尝试；没有提交时额外等待 `min(1 ms, period/8)` 再周期采集，以覆盖装饰、popup 和无主 surface 提交的内容变化。只监听主 surface，未覆盖全部独立子 surface/popup 的提交事件。

这意味着静态内容下的尝试周期约为 17.67 ms（60 fps 配置，约 56.6 次/秒），是未采用原型的一项明确代价。它不是实测静态帧率，也不是会话时限。原型不增加授权、焦点或 freshness 条件，不用性能未达标关闭会话，既有捕获失败处理保持原样。主 surface 事件可能合并；attempts 是 renderer 调用次数，含 Busy 等没有实际导出新帧的情况，不能作为帧率。

cohort 使用弱引用监听及 timer，停止一路只移除该成员；最后一条流停止时取消 group timer。创建/回写失败会清理注册，避免过期成员占据相同流 ID。完整原型、CMake 可选实验名称及新策略测试在 [source-prototype](source-prototype/platform/viewflow-capture/src/main.cpp)；恢复前源码在 [source-before](source-before/main.cpp)。

## 测量环境与端点

源为独立嵌套 Hyprland v0.56.2，commit `efb50993780079460b0cbed1363e2166a2de1d9f`，与安装的 plugin ABI 对齐。bwrap 隔离 `/dev`，只显式暴露 GPU render/NVIDIA 节点和 Viewflow 私有 IPC 目录，物理 DRM/input/seat 不可用；使用 parent Wayland 分配器。实验进程继承专用 exec rule，在自有外层 headless output 上创建 NO_INITIAL_FOCUS 窗口。嵌套输出实际为 WAYLAND-1 3840×2400@60、scale 2，fixture 1920×1200 logical，导出 3848×2408、atlas 3968×2432。它比上一轮直接根 compositor 的环境多一层嵌套，因此不能将两轮绝对相位直接当成同条件 A/B。

Windows 使用相同 Intel GPU 6144×3456@60 输出、1:1 NOACTIVATE 自有窗口、H.264、原 Rust receiver 和独立 native-trace-controls-build。四轮均为 minimal tracing：native GPU queries、两端 socket trace、source GPU 分段日志和 alpha copy profile 关闭；QPC、raw clock exchanges、source/wire timing、GPU fixture marker 和桌面 observer 保留。不是完全无诊断的生产测量。

源每轮计划 25 秒、DD observer 20 秒，驱动总时长另含配置、启动及收取日志。没有注入输入、切换焦点或运行 ETW/WPR。本轮覆盖约 4K 内容的 Linux→Windows 路径，不是物理 3840×2160 显示器验收，也不证明 Windows/macOS 原生采集路径具有同等结果。

fixture pre-draw 是应用绘制前的时间戳；DD 端点是包含 marker 的桌面样本 LastPresentTime。它不能证明该帧第一次可见、物理扫描或光子时间。native commit/s 也不是物理显示 FPS。时间上界包含双端时钟映射不确定度；各阶段独立中位数不能相加重建总跨度。

## 四轮结果

| 轮次 | native commit/s | DD marker/s | pre-draw→capture 中位 ms | P95 ms | pre-draw→DD 上界中位 ms | P95 ms | 最大 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
'''
for r in rs:
 b=r['bounds'];c=b['unique_capture_stage_samples']['render_to_capture_ms'];u=b['latency_upper_ms'];s+=f"| {r['label']} | {r['native_commit_hz']:.3f} | {r['desktop']['observed_changes_per_second']:.3f} | {c['median']:.3f} | {c['p95']:.3f} | {u['median']:.3f} | {u['p95']:.3f} | {u['max']:.3f} |\n"
s+='''
B 的采集前等待分布约为 0.25–17.04 ms，中位数约 8 ms；它没有保持每次提交后立刻取得最新内容。A1 与 A2 的原网格相位中位数分别为 19.35 和 6.55 ms；B 相比前者好、相比后者差。A1 超过一个刷新周期的跨度也包含应用和嵌套 compositor 处理，不能全部归因于原采集 timer。

| 轮次 | capture→recv 中位 ms | capture→mutation 上界中位 ms | mutation→DD 中位 ms | capture→DD 上界中位 ms | P95 ms |
|---|---:|---:|---:|---:|---:|
'''
for r in rs:
 u=r['bounds']['unique_capture_stage_samples'];c=r['capture_delivery_ms']['socket_age_max_us'];d=u['capture_to_desktop_upper_ms'];s+=f"| {r['label']} | {c['median']:.3f} | {u['capture_to_mutation_upper_ms']['median']:.3f} | {u['mutation_to_desktop_ms']['median']:.3f} | {d['median']:.3f} | {d['p95']:.3f} |\n"
s+='''
采集后读取中位数仍为 0.22–0.25 ms，说明保留的 socket readiness 路径继续工作。编码整个 host 阶段中位数约 6.98–7.07 ms，编码后至 pipe admission 约 2.67–2.72 ms，pipe→decoded 约 1.52–1.59 ms。新策略没有消除 Windows 提交后的约 34–37 ms 跨度，B 的该项还更高；这里没有独立证据把它全部归因于 DWM CPU、GPU 执行或显示队列中的某一项。

B 的原生提交率比这两轮 A 高约 0.4–0.9/s，但只有两次对照、仍低于 60，完整延迟也没有一致改善，不能据此宣称稳定 FPS 增益或采用默认值。四轮全部 pre-draw→DD 样本下界都超过两次 60 Hz 刷新（849/868/886/835 个），确证在两帧内的样本为 0。未隐藏 A2 272.6 ms 或 B2 157.3 ms 的长尾。

## 运行验证与完整性

实验 CMake/Release 编译成功，全部八项 CTest 通过，包括 wire、sender、几何/IME 范围、原网格和新 commit schedule。新纯策略测试覆盖多帧率、提前/晚到提交、事件合并、无提交周期回退、长停顿无追赶及整数饱和。它们不代替实际 GPU 采集。

最终 SO 在独立嵌套桌面通过 169 帧双窗口 GPU 验证：每帧检查 232-byte HCGF 主头加 HCGI 扩展、两枚 SCM_RIGHTS FD、native fence 完成、目标窗口地址/进程/几何、精确 HCGR sequence/epoch；持有 A 的一帧不释放时 B 继续取得 12 帧，A 不重复导出；停止 A 后 B 再取得 12 帧；同一 ID 在空组删除后重新启动；grid API 同样取得实际帧。一次 DMA-BUF 回读验证为 3848×2408，图像包含 fixture 的棋盘、红色线和 marker，[PNG](nested/jeutsu3_/first-frame.png)及原始 PPM gzip 保留。回读只用于前置 smoke，不在四轮延迟测量中运行。

真实 A/B 的 60 fps streams 按日志顺序对应 A1/B1/B2/A2，attempts 为 1480/1481/1485/1483；B1/B2 分别记录主 surface notifications 1483/1488、commit attempts 1479/1484、fallback attempts 2/1。这些计数证明分支真实执行，不表示每次尝试都导出了帧。全部 start/stop 记录保留于 [嵌套 compositor 日志](nested/jeutsu3_/compositor.log.gz)。

唯一捕获配对为 846/867/886/835，歧义 marker 为 3/1/0/0，只从要求唯一捕获身份的阶段中排除；总 pre-draw 跨度仍保留所有 849/868/886/835 个 marker，无需猜测某个重复 marker 属于哪次 capture。无 missing capture marker、无过期时钟映射；776/776/784/776 组 raw clock exchanges 全部复算有效。每个所用映射有效期覆盖相应桌面端点。marker、正 LastPresentTime、readback sequence 严格递增，ring pending_peak=2、abandoned=0，无负 capture 上界或 mutation/commit→DD。没有 malformed wire/encoder 记录；minimal 模式的 GPU encode 细分为空是预期结果。

前置驱动失败也保留于 nested：`mi4r_sfg` 为启动中 instances 尚未注册时返回非完整 JSON，后续改为检查同一存活进程的注册状态；`nqzwbcuk` 为 smoke 错把 320-byte 总包长度当成 HCGF 主头长度；`bdtlj6qj` 明确记录嵌套 headless GBM 分配失败，随后改为已验证实际模式的 Wayland 输出；`2nklm9hu` 为测试重启时重复绑定旧 socket 路径，后续改为每次新 socket；`4zqk3nt5` 为首次完整 smoke 通过。以上不能记为生产采集故障，也未用于性能表。最终 `jeutsu3_` 使用修正后的驱动及最终 SO，通过 smoke 和四轮测量。所有实例均终止，自有外层输出移除，前后 root monitor、focus、plugin 列表逐项相等。

## 恢复和可复查材料

四轮使用的实验 SO SHA256 为 `8c76a5a9a3f5cf805ff28f9a6298619bb2d0322b94b58fbc93eb92652d55ceeb`。源码与构建文件在测量期间未改变。随后先冻结 source-prototype 和所有哈希，再将生产 main.cpp、CMakeLists.txt 逐字节恢复原备份，删除生产目录中新加的 policy/test 两文件。[恢复记录](method/commit-cadence-production-restored.json)和[最终现场读取](method/commit-cadence-final-state.json)分别证明源码恢复与实际二进制/配置状态。未把实验 SO 复制到生产目录。

根桌面仍加载原 `viewflow-capture.so`（`f7c23f70d1636ab75a0c12b5082349d7e92e4cf2bd91548169da1206ea1c9aea`），Linux Release 仍为 `ddbc806b581037ee64abf084a8c8c77ec14c5f437e079edc44bad5b92277aae2`。原 renderer 两文件未修改，Windows 默认 native、Rust receiver、DD observer、诊断 native、三种 runner 和原 PDB 的哈希均与前置核验一致；原临时配置逐字节恢复。

ESRV 控制采用先注册独立十分钟 SYSTEM 恢复任务，再仅调整同一 PID/start time、两条特定 thread/start time 的优先级。每轮前后读回 Normal/base8、无其他 TimeCritical，未作连续优先级采样。finally 恢复原 High/两条 TimeCritical 并删除恢复任务；最终服务 Running/Auto，PID 2344、实验进程和任务均为 0。没有停止、重启或禁用服务。每轮驱动 exit=0、计划源 timeout exit=124、receiver peer 关闭 exit=1 且 watchdog=0、DD exit=0，自有 fixture 均退出。

各轮原始 source/receiver/desktop/producer/runner/cleanup/driver、fixture 元数据、唯一配对、摘要及[完整比较](comparison.json)均保留；method 包含分析和控制脚本、构建及测试日志、原始源哈希、恢复脚本；source-prototype 保存实际受测插件源码和分析依赖。大型 EXE/SO 不写入仓库，保留实际哈希和构建输出路径。控制脚本中的绝对路径及进程/线程身份对应当时现场，再次运行任何修改前必须重新读取状态，不能直接复用旧身份。

纯分析复算：将每轮 source/receiver/desktop 解压到 `/tmp/viewflow-integrated-pair/{kind}-{label}.log`，producer 解压到 `/tmp/viewflow-frame-fixture-first/{label}-source.log`；在工作目录 tools 下放置 source-prototype/tools 两个依赖，然后运行 `method/summarize-commit-cadence.py`，依次传入上表四个 label。原型重建使用 source-prototype/platform/viewflow-capture 作为 CMake source，配置 `VIEWFLOW_CAPTURE_PLUGIN_NAME=viewflow-capture-commit-test`、`VIEWFLOW_CAPTURE_LUA_NAMESPACE=viewflow_capture_commit_test`，需要相同 Hyprland ABI 和原构建依赖。sha256.json 覆盖本目录所有文件（自身除外）。

下一步应分别改善提交相位跟随与 Windows 提交后的等待，并验证完整 pre-draw→桌面跨度；不能只缩短 capture 后指标，也不能把固定 33 ms 性能目标改成连接退出条件。
'''
# Derive the final cadence counters from actual log; never hard-code an unverified A2 count.
log=(out/'nested/jeutsu3_/compositor.log.gz')
import gzip
rows=[]
for line in gzip.decompress(log.read_bytes()).decode().splitlines():
 if line.startswith('viewflow-capture-cadence stop=1 stream=gpu-stream-') and ' fps=60 ' in line:rows.append(dict(re.findall(r'(\w+)=([^ ]+)',line)))
assert len(rows)==4 and [r['mode'] for r in rows]==['grid','commit','commit','grid']
s=s.replace('1480/1481/1485/1483','/'.join(r['attempts'] for r in rows))
(out/'cadence-counters.json').write_text(json.dumps(rows,indent=2)+'\n')
(out/'README.md').write_text(s)
print('wrote README',rows)
