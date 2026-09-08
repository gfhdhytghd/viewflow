from pathlib import Path
import json
out=Path('docs/evidence/performance-20260908/composition-path-probe');runs=out/'runs'
a=json.loads((runs/'comparison.json').read_text());b=json.loads((runs/'toggle-comparison.json').read_text());startup=json.loads((runs/'startup-comparison.json').read_text())
lines=['# Windows 合成路径独立探针（2026-09-08）','',
'同一进程中保留四个背景节点、只将其透明度从 1 改为 0，两次反向顺序对照均降低了“表面绑定前 CPU 时间戳 → 含对应标记的桌面更新时间戳”的中位数。它为背景效果开销提供了更直接的证据；尚未将该省略方式用于产品，也没有验证 4K60、两帧内完整远程显示。观察到的标记变化率没有随延迟一起改善。','',
'## 同一进程对照','',
'两个进程各运行 33 秒，GPU 以约 60 Hz 生成 3848×2408 纹理（3840×2400 内容及四像素透明边框）。窗口、Compositor、两张交替 DrawingSurface、五个区域、四个背景节点与 60 Hz 提交网格始终保留；每 240 个实际提交帧切换背景透明度，第二进程反转顺序。效果来自未修改的 production `SharedSparseScene`，HostBackdrop 模糊 sigma=12。每段前 30 帧固定标记为过渡预热并排除统计，原始数据仍全部保存。DD 观察 30 秒，最后一段只有部分覆盖，表中如实显示。','',
'| 轮次 | 背景透明度 | 有效配帧 | 绑定→DD 中位数 ms | P95 ms | 最大 ms |','|---|---:|---:|---:|---:|---:|']
for r in b:
 for bg in ['4','0']:
  g=r['grouped'][bg];s=g['mutation_to_dd_ms'];lines.append(f"| {r['label']} | {'1（4 个）' if bg=='4' else '0（4 个保留）'} | {g['n']} | {s['median']:.3f} | {s['p95']:.3f} | {s['max']:.3f} |")
lines+=['','开启与静音两组中位数相差 8.876 ms / 7.453 ms；这是组间分布的差异，不是逐帧配对减法或完整链路提速。反序轮静音组 P95 仍为 36.379 ms，不能声称可靠满足 33.33 ms。透明度为零是否完全取消 GPU 背景计算，没有单独 GPU 时间戳证明。','',
'| 轮次 | 段 | 背景数（透明度 1） | 首/末有效帧 | 配帧 | 绑定→DD 中位数 ms | P95 ms | 观察标记变化/s |','|---|---:|---:|---|---:|---:|---:|---:|']
for r in b:
 for p in r['phases']:
  s=p['mutation_to_dd_ms'];lines.append(f"| {r['label']} | {p['phase']} | {p['backgrounds']} | {p['first_frame']} / {p['last_frame']} | {p['n']} | {s['median']:.3f} | {s['p95']:.3f} | {p['observed_change_hz']:.3f} |")
lines+=['','分段变化率只在各段连续覆盖内计算，不把分散的背景开启片段拼成连续时间。两轮分别生成 1977 / 1980 帧，漏过 3 / 0 个提交时隙；不会补发过期帧，也不会因性能目标关闭用户会话（本工具本来就没有远程会话）。本轮没有引入 DWM vblank 锚点，不能声称已锁定到 DWM 的精确提交相位。','',
'## 独立进程八轮筛查','',
'相同最终五模式二进制，按 A/B/C/D/D/C/B/A 顺序各运行 25 秒，DD 各观察 20 秒。A 为 WinRT 单 Sprite；B 加 HWND HostBackdrop 标志；C 使用实际共享稀疏场景及四个背景；D 将手工构造的五个区域都标为 opaque，让场景不创建背景节点。D 是此二值 alpha 图案的诊断设定，未验证通用 alpha、缩放或抗锯齿语义。','',
'| 轮次 | 模式 | 配帧 | 提交/s | 观察标记变化/s | 绑定→DD 中位数 ms | P95 ms | 最大 ms |','|---|---|---:|---:|---:|---:|---:|---:|']
for r in a:
 s=r['latency']['mutation_to_desktop_ms'];lines.append(f"| {r['label']} | {r['mode']} | {r['paired']} | {r['submitted_hz']:.3f} | {r['observed']['observed_changes_per_second']:.3f} | {s['median']:.3f} | {s['p95']:.3f} | {s['max']:.3f} |")
lines+=['','同一模式跨进程仍有明显波动；HostBackdrop HWND 标志本身没有稳定增加一帧。简单替换 WinRT API 的必要性没有得到这些结果支持。这促成了上面的进程内切换，而不是直接采用独立进程的最好数字。','',
'## 初始 API 启动验证','',
'较早的两模式二进制在 ESRV 原始 High 优先级下运行，因此与后续正式 Normal 对照分别报告。DirectComposition 与 WinRT 均成功输出标记。','',
'| 模式 | 配帧 | 绑定→DD 中位数 ms | P95 ms |','|---|---:|---:|---:|']
for r in startup:
 s=r['latency']['mutation_to_desktop_ms'];lines.append(f"| {r['mode']} | {r['paired']} | {s['median']:.3f} | {s['p95']:.3f} |")
lines+=['','这两轮只支持 API 启动与局部时间戳可观测，未控制相位，不能视为性能等价检验。','',
'## 测量范围和验证','',
'- GPU 在 Windows 本机生成移动色块、透明边框及带校验的 frame ID 标记，执行完整纹理复制、EndDraw/Flush 和表面绑定。没有 Linux 捕获、编码、网络、解码或输入阶段。源纹理与显示设备都在 Intel 硬件适配器上（vendor 32902，device 32103，LUID low 30969）。实际 Windows 输出为 6144×3456@60 的虚拟输出，不能作为物理 4K 验收。',
'- CPU render/drawn/begin/copied/ended/mutation/committed 时间戳及 DD 使用同一 Windows QPC（100000000 Hz）。BeginDraw 与 copy、EndDraw 与 Flush 分别为合并的 CPU 区间，不是单项 GPU 时长；WinRT committed 是属性调用返回，并不表示 DWM 呈现完成。',
'- DD 终点为含匹配标记的 `LastPresentTime`；可能对应后续桌面更新，既不是该帧首次呈现凭据，也不是光子时间。观察器通过异步 staging ring 读单条标记扫描线，其干扰仍可能影响帧率。',
'- 所有运行验证 source frame ID 唯一递增、CPU 阶段顺序、观察器 PID 与 QPC 频率匹配、marker input=0、呈现/读回序列递增，以及原始进程结果。八轮有 6518 个有效匹配，启动两轮 1478 个；进程内两轮在固定分段预热后分别 1030 / 821 个。没有负的 mutation→DD 样本；原始长尾保留。',
'- 12 次探针/观察器退出码均为 0，ring abandoned=0，pending_peak≤3；每次前台 HWND 前后均为 66054。窗口使用 NOACTIVATE、SW_SHOWNOACTIVATE，未注入输入、改变用户应用焦点或修改 Linux 输出。标记通过不等于全图像素一致性测试；本轮没有这样的 oracle。',
'- 正式八轮与两轮切换前注册十分钟 SYSTEM 恢复任务，然后将 ESRV PID 2344 及两个已校验创建时间的线程设为 Normal。每轮前后检查 Normal/base=8/无其他 TimeCritical；不是连续监控。finally 恢复 High 与线程 12232/16604 的 TimeCritical，随后移除恢复任务。失败启动也执行了恢复。',
'- [最终实机核验](method/composition-probe-final-state.json)确认原七个 Windows EXE、两个 PDB、接收配置及原 Linux 六项源文件/二进制哈希保持既有基线；隔离目录没有运行中的进程，探针、观察器及恢复任务均已移除。新增诊断 EXE 留在隔离目录，产品后端没有替换。配置归档只保存哈希。','',
'## 代码与复现','',
'本次保留一个独立诊断工具和 CMake 目标，不改产品合成后端。最终源在 [toggle-source](toggle-source/tools/windows_composition_latency_probe.cpp)，八轮受测源另存在 [independent-source-and-method](independent-source-and-method/tools/windows_composition_latency_probe.cpp)。初始两模式源见 [initial.cpp](method/composition-latency-probe-initial.cpp)。','',
'```powershell',
'cmake -S platform/windows-composition-preview -B probe-build -G "Visual Studio 17 2022" -A x64',
'cmake --build probe-build --config Release --target viewflow_windows_composition_latency_probe',
'# 在交互式 Windows 桌面运行；只创建自己的非激活窗口。',
'.\\probe-build\\Release\\viewflow_windows_composition_latency_probe.exe toggle 33000 probe.log',
'# 第二轮使用 toggle-reverse；其他模式：winrt/dcomp/hostflag/sparse/elided。',
'```','',
'运行时找工具自身 PID，用已有 frame observer 对该 PID 观察 30000 ms（`physical4k timer1`）。该观察器参数名不表示物理显示器认证。受测运行通过原交互用户的计划任务启动；[runner](method/run-composition-toggle-probe.py)及 [控制脚本](method/composition-toggle-controls.py)保留了实际主机/隔离目录选择、退出确认和恢复逻辑。重现时需要将脚本中的临时路径、Windows 主机与基线配置路径替换为自己的；不要把本次 ESRV PID/线程身份当作其他机器的配置。','',
'实测二进制为手工 MSVC `/O2 /EHsc /std:c++20` 构建：初始两模式 SHA256 `8F435FBD4099613FD0797C6C580D4EF81DB95DE989298299F25B263D6CEA13E0`；八轮五模式为 `E852DA1B66033246C45378E9A0F79EC73DC29E3EA767576A9F2576EE14A21B9A`；进程内切换为 `83FA9249F2C602C9DA82060269723AE62F50A2B7492E04BF4D79E44EF9A9E215`。观察器全程为 `D57C7377AEFCD603D01626948805949EB78BB9B7C7C8C52CB0604A471841AAEA`。各运行 state 记录实际哈希，源码清单逐项核对；不把不同版本的启动探针合并到正式对照。','',
'[CMake 原生构建](method/composition-probe-cmake-build.log)已在独立新目录通过，仅验证可构建；性能运行用的是上述手工构建，不冒充 CMake 产物已重跑。','',
'原始日志和逐帧匹配为 [runs](runs/comparison.json) 下 `*-probe.log.gz`、`*-desktop.log.gz`、`*-pairs.json.gz`。进程内摘要见 [toggle-comparison.json](runs/toggle-comparison.json)，其配帧保留 `warmup` 字段，便于审计固定排除规则。[分析器](method/analyze-composition-toggle.py)和用到的解析依赖一并归档；解压至运行目录并设置其 root 路径后可重新生成。','',
'## 遇到的问题与后续动作','',
'初始 EncodedCommand 超出 Windows 命令行长度限制，随后改为上传 PowerShell 文件；没有实际测试进程启动。加入 sparse 模式后两次 GUID 链接失败，最终用 `initguid.h` 修正。一次错误地在失败构建后进入控制流程，因 EXE 不存在而启动失败；[失败记录](failed-start/control-state.json)保留其 ESRV 恢复，未计入性能样本。当前控制脚本已在改变优先级前核对成功构建的 EXE 与五项源文件哈希。CMake 第一次因 SSH PATH 中没有 cmake 失败，改用实机已有 VS CMake 绝对路径后构建通过。','',
'下一步应先验证二值 alpha、整数 1:1 对齐时省略背景是否逐像素等价，并验证半透明 alpha、缩放、非整数偏移和交互缩放开始时正确恢复背景；之后才能把候选放进真实远程链路做受控 A/B。当前结果不支持直接关闭所有真实窗口的模糊，也没有证明减少背景工作能提高最终可见帧率。','',
'API 语义参考微软官方：[CreateTargetForHwnd](https://learn.microsoft.com/en-us/windows/win32/api/dcomp/nf-dcomp-idcompositiondevice-createtargetforhwnd) 与 [IDCompositionSurface::BeginDraw](https://learn.microsoft.com/en-us/windows/win32/api/dcomp/nf-dcomp-idcompositionsurface-begindraw)。探针保留独立窗口目标，尊重 BeginDraw 返回偏移，完成整面首次初始化，并在 EndDraw 后更新绑定/提交。','']
(out/'README.md').write_text('\n'.join(lines))
