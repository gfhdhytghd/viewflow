from pathlib import Path
import json,hashlib
b=Path(__file__).resolve().parent.parent
rows=json.loads((b/'comparison.json').read_text())
lines=['| 按运行顺序 | 原生提交/秒 | 桌面不同帧数÷30秒 | 捕获→所见桌面中位 / P95 ms | 跳过重复模糊 |','|---|---:|---:|---:|---:|']
for r in rows:
 q=r['bounds']['unique_capture_stage_samples']['capture_to_desktop_upper_ms']
 skip='—'
 if r['background_snapshots']:
  z=r['background_snapshots'][-1];skip=f"{z['unchanged']}/{z['compared']} ({100*z['unchanged']/z['compared']:.1f}%)"
 lines.append(f"| {r['label'].removeprefix('display-diff-v1-')} | {r['native_commit_hz']:.2f} | {r['desktop']['changes_per_requested_second']:.2f} | {q['median']:.2f} / {q['p95']:.2f} | {skip} |")
report='''# 背景变化检测：计算减少，整链路仍有退步

30 Hz、15 Hz 各两轮候选与前后关闭缓存的对照均完成。GPU 精确比较跳过约 92%–97% 的重复模糊，但桌面观测更新率仍低于关闭缓存，延迟上界中位更高。本候选保留在独立实验目录，未接入当前工作区的接收器；原生背景缓存继续默认关闭。4K60、两帧内显示仍未证明。

缓存边界遵守用户要求：缓存矩形不超出当前显示器。固定窗口外保留适量移动和模糊余量，屏幕之外不扩展缓存；跨边界部分仍走原有实时背景。几何实现和前一轮数据见[原生背景缓存](../native-background-cache/README.md)。

## 实现与正确性

GPU 比较完整背景与上次实际模糊处理的输入，只读回 4 字节变化标记。候选使用逐像素精确比较，RGB 和 alpha 均不允许差异。相同时保留已有缓存表面，避免重新模糊和发布；变化时使用现有 Hyprland 0.56.2 算法（radius=5、passes=4）。参考图仅在实际处理后更新，原始捕获帧在 GPU 工作完成前保持存活，整个过程在后台线程异步完成。前台不等待比较结果。

Windows 硬件 D3D11 测试通过 32 项：129×65 和 3839×2399 两种尺寸，精确比较和允许 RGB 一个码值差异的单独实验模式各 8 项。覆盖相同输入、微小变化、累积变化、末尾像素、工作组边界、负向变化和 alpha 变化。允许误差模式未接入此候选。[单独测试日志](method/unit.log)

原生窗口测试中，初始静止背景 83 次比较全部复用；后方本地窗口从红变绿后正确刷新。移动、缩放、透明洞、透明区域恢复、闲置余量收缩及显示器边界测试均通过，8 次几何重建无错误，前台焦点保持不变，没有输入注入。[原生测试日志](method/native-background-result.log)

纹理条纹核验覆盖完整 1132×1132 区域。移回相同位置后，原始纹理因 0/0.01 像素刷新偏移最多相差 1 个码值，已模糊缓存逐字节一致；这不表示对任意图案两次模糊结果必然一致，也未使用该误差来跳过本候选的精确比较。[像素比较](method/worker-pixel-comparison.json)

## 八轮整链路对照

源内容为 3840×2400，捕获含边框为 3848×2408，atlas 为 3968×2432。八轮 Windows 观察器均报告同一 6144×3456 @60 输出，窗口客户端为 -4,-4,3848,2408；缓存为 4238×2798，未超出显示器。这里测量的是 4K 内容置于当前 6K 虚拟输出，不能外推为物理 4K 显示器或 macOS 的测试结果。

先完成 30 Hz 四轮，再按用户顺序运行 15 Hz 四轮。八轮使用同一份原生接收器和 Linux 源端/图案程序；每四轮内连同启动器的文件哈希也一致。15 Hz 使用独立启动器，两个启动器的源码和哈希分别保留。关闭缓存时为现有实时背景；开启时为显示范围内的 Hyprland 缓存，并按选定频率检查真实背景。

'''+ '\n'.join(lines)+'''

表内桌面更新计数统一除以请求的完整 30 秒，不用短标记区间放大速率。八轮图案均持续推进，标记覆盖均超过请求区间的 99%，没有沿用上一阶段的停帧或短观测样本；时钟映射、逐帧身份、观察器有效性及清理检查通过。完整统计见[comparison.json](comparison.json)。

原生提交率不是屏幕刷新率，Desktop Duplication 观察器也可能漏掉中间帧；延迟端点是被观察到的桌面更新时间，并非首次扫描输出或光子时刻。因此这些值支持同条件下的候选退步结论，不能作为真实首呈现的精确延迟或 4K60 达标证明。

重复模糊明显减少而总体仍退步，说明单靠消除这项工作不足以解决当前后台捕获/比较/合成路径的开销。未做各子阶段独立消融，不能据此单独归因到 WGC 或比较着色器。没有为了达标关闭局部背景、改变焦点、注入输入或调整生产遥测进程优先级。

## 复现与归档

[build.py](method/build.py)、[build-unit.py](method/build-unit.py)、[run-oracle.py](method/run-oracle.py)保存构建与原生验证入口。[run-integrated-ab.py](method/run-integrated-ab.py)和[run-integrated-ab15.py](method/run-integrated-ab15.py)分别运行两组对照。复现应使用新的隔离目录，构建后更新对应二进制哈希；配对配置仍由本地运行环境提供，不包含在归档中。

本阶段实际使用了生产器持续性检查：每两秒检查进程、所属输出的可见工作区和图案日志是否仍推进；异常时保留诊断并仅清理测试资源，不恢复或改变用户工作区。[108 个源文件哈希](method/source-sha256.json)、[远端源文件核对](method/remote-source-hashes.json)、[最终状态](method/final-state.json)保存身份与清理证据。

运行 `PYTHONDONTWRITEBYTECODE=1 python docs/evidence/performance-20260908/background-change-detection/method/verify-archive.py` 可离线重算八轮分析与时间线、原始像素比较、几何/分区测试，核对身份、观测完整性与全部归档哈希。原始运行日志压缩保存在 runs 下，未复制配对密钥、运行配置或可执行文件。
'''
# Keep factual report assertions tied to the archived observations.
assert len(rows)==8 and all(r['desktop']['marker_span_fraction']>.99 for r in rows)
(b/'README.md').write_text(report)
r=b.parent
p=r/'report-source.md';s=p.read_text();line='**背景精确变化检测：** 在显示范围限制内跳过约 92%–97% 的重复模糊后，30 Hz、15 Hz 各两轮完整候选仍有整链路退步，缓存保持默认关闭。八轮均为完整动态观测，4K60、两帧内仍未证明。见[对照与原始证据](background-change-detection/README.md)。\n\n'
if not s.startswith('**背景精确变化检测：**'):p.write_text(line+s)
p=r/'report.html';s=p.read_text();line='<p><strong>背景精确变化检测：</strong>跳过约 92%–97% 的重复模糊后，30 Hz、15 Hz 各两轮完整候选仍有整链路退步，缓存保持默认关闭。八轮均为完整动态观测，4K60、两帧内仍未证明。<a href="background-change-detection/README.md">对照与原始证据</a>。</p>\n'
if '<strong>背景精确变化检测：</strong>' not in s:p.write_text(s.replace('<p><strong>原生背景缓存：</strong>',line+'<p><strong>原生背景缓存：</strong>'))
p=r/'sha256.json';d=json.loads(p.read_text())
for n in ['report-source.md','report.html']:d[n]=hashlib.sha256((r/n).read_bytes()).hexdigest()
p.write_text(json.dumps(d,indent=2)+'\n')
manifest={str(p.relative_to(b)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(b.rglob('*')) if p.is_file() and p!=b/'sha256.json'}
(b/'sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('updated result report and',len(manifest),'archive hashes')
