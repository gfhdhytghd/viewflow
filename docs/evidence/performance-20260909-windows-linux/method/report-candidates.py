from pathlib import Path
import json
b=Path(__file__).resolve().parent.parent;t=b/'transport';p=t/'README.md';text=p.read_text();heading='## Additional copy, alpha, and scheduling comparisons';text=text.split('\n'+heading)[0]
labels=['direct-off-a1','direct-on-b1','direct-on-b2','direct-off-a2','alpha-off-a1','alpha-on-b1','alpha-on-b2','alpha-off-a2','mmcss-off-a1','mmcss-on-b1','mmcss-on-b2','mmcss-off-a2','alpha-render-off-a1','alpha-render-on-b1','alpha-render-on-b2','alpha-render-off-a2','alpha-direct-off-a1','alpha-direct-on-b1','alpha-direct-on-b2','alpha-direct-off-a2','integrated-off-a1','integrated-on-b1','integrated-on-b2','integrated-off-a2']
rows=[]
for n in labels:
 s=json.loads((t/'runs'/n/'summary.json').read_text());rows.append(f"| {n} | {s['desktop_distinct_hz']:.3f} | {s['latency_high_ms']['median']:.3f} | {s['latency_high_ms']['p95']:.3f} | {s['latency_high_ms']['max']:.3f} |")
text+='\n'+heading+'\n\nEach four-row group is A/B/B/A on the same native executable. Encoder quality/speed is 0, the source fixture uses its one-frame waitable queue, and the normal paired transport plus Linux receiver/observer is unchanged. Every additional trial hashes its native executable before and after. All retain full 6K dimensions and exact alpha.\n\n| Trial | Distinct frames/s | Median upper, ms | P95 upper, ms | Maximum upper, ms |\n|---|---:|---:|---:|---:|\n'+'\n'.join(rows)+'\n'
text+='''
The [owned-source direct path](../direct-source-stop/README.md) avoids atlas clear/copy only when one tile exactly covers the atlas. Enabled trials have lower P95 (93.6–96.5 ms versus 110.5–111.0 ms), while distinct throughput is slightly lower (30.3–30.4 versus 30.7 FPS). Medians overlap. This is a measured tradeoff, not a 60 ms result. The texture remains owned by the application; no borrowed WGC frame survives the callback. The later matched synthetic RGB checks and owned-window lifecycle test are described below.

The [compute alpha summary](../alpha-summary-fixed/README.md) passes exact GPU tests, but the four full-chain trials show no repeatable overall benefit. B1 worsens median and P95; B2 has a lower P95 than A2 with lower throughput. Saving CPU alpha copy/comparison cost did not establish an end-to-end gain. It is held out of production. The [render-first alternative](../alpha-summary-render/README.md) passes exact alpha tests; its standalone source run delivers 32.610 distinct frames/s, with alpha enqueue-to-collect median 12.138 ms and pre-draw-to-local-output median 115.348 ms. These standalone measurements exclude live transport/presentation. Its completed full-chain tests without the direct path show a small repeatable throughput increase but overlapping latency results.

[Source-thread MMCSS](../source-mmcss/README.md) actually registers and raises the source main thread's base priority from 6 to 19; all processes remain BelowNormal and scheduled-task priority remains 7. Its measured full-chain results do not establish a repeatable overall gain, so no reverse scheduling default is changed. The standalone source records successful explicit AvRevert on normal exit. Full transport termination is separately recorded; no scope-unwinding claim is inferred from child termination.

The [bounded WGC drain](../wgc-latest/README.md) discarded zero extra frames in all 1,513 source callbacks, giving no evidence for backlog in that fixture workload. It was not adopted. A separate [canonical capture teardown fix](../root-capture-stop/README.md) stops callbacks while source owners remain alive and passes the four existing Windows contract/wire/geometry tests. The isolated earlier 0xC0000409 was not reproduced under two debuggers; the code fix is not claimed as proof of that crash's cause.
'''
text+='''

Combining the owned-source direct path with render-first alpha summary improves both repeated B trials: 31.238–31.533 distinct FPS, median upper 77.932–83.286 ms and P95 upper 95.452–100.310 ms, versus A's 29.822–30.061 FPS, 87.025–89.409 ms and 103.825–105.944 ms. Maximum delays remain in the table; neither configuration meets 60 ms.

The [integrated candidate](../integrated-candidate/README.md) adds lifecycle fixes to that shared combination. Its A/B/B/A varies only whether unchanged capture versions are skipped. B achieves 32.795–33.211 FPS versus A's 30.974–31.266 FPS. Median and P95 overlap across repeats, so skipping duplicates has a repeatable throughput gain but no established latency improvement or penalty. An early comparison against A1 alone suggested a latency penalty; A2 does not support that general conclusion. The final canonical integration and installed controls are described below.

[Matched synthetic quality](../candidate-quality/README.md) compares every RGB pixel at 90 common markers across four source streams. Aggregate PSNR stays near 41.871 dB. This supports fidelity on this generated grid only, not arbitrary text or natural images. [Owned-window lifecycle validation](../lifecycle-v2/README.md) passes all 21 frames through Linux NVDEC/CUDA/GLES with exact alpha, title/move/second-window/resize/hide/close coverage, and single-tile direct versus multi-tile atlas paths. It is an offline decoder test, not live Wayland lifecycle acceptance. It exposed and then verified fixes for a resize with no follow-up capture and a closed handle yielding invalid metadata. Those fixes are in the [canonical 31-file build](../root-lifecycle/README.md), which passed all four Windows CTests at that stage. The later installed 39-file build is described below.
'''
extra_labels=['queue-1-b1','queue-4-a1r','queue-4-a2','queue-1-b2','priority-off-a1','priority-on-b1','priority-on-b2','priority-off-a2','root-frame-a1','root-latency-b1','root-latency-b2','root-frame-a2']
text+='\n## Queue bounds, process priority and installed canonical build\n\nThe queue group runs B/A/A/B, followed by two A/B/B/A groups. All measurements use full 6K and the same paired receiver/observer.\n\n| Trial | Distinct FPS | Median upper ms | P95 upper ms | Maximum upper ms |\n|---|---:|---:|---:|---:|\n'
for label in extra_labels:
 value=json.loads((t/'runs'/label/'summary.json').read_text());lat=value['latency_high_ms'];text+=f"| {label} | {value['desktop_distinct_hz']:.3f} | {lat['median']:.3f} | {lat['p95']:.3f} | {lat['max']:.3f} |\n"
text+='''

Queue-depth tests have pending=0 before every submission, including the four-frame arms. The MFT input-ready event already limits this workload, so the changed admission bound does not establish an improvement. The initial depth-four launcher rejected its argument before starting Windows capture; its separate failed-run directory preserves the cleanup and is excluded from the 43 measured trials.

Normal process priority changes the observed thread bases (15 threads from 6 to 8 and ten from 4 to 6), while scheduled-task priority remains 7. Repeated performance distributions overlap; no process-priority change is installed.

The final canonical E1543F07 build includes the verified shared optimizations, metadata/resize recovery, and watched frame-rate/latency mode settings. Six CTests and both canonical lifecycle/GPU runs pass. Its frame-rate arms deliver 32.947 and 33.509 distinct FPS, with median upper 80.156 and 78.406 ms and P95 upper 96.916 and 95.391 ms. The latency arms overlap and do not prove lower latency. Limits are admission policies, not guaranteed measured benefits on this encoder.

This exact Windows binary and the controls are now [installed](../production-deployment/README.md), while the existing source/pair configurations and services retain their previous states. The measured Linux native is byte-identical to its installed counterpart. The full four-arm comparison uses the actual mode-file controller and includes native file polling. Startup mode, direct/alpha routes, frame occupancy, hashes, clock envelopes and cleanup are verified. Physical scanout and interactive gesture acceptance remain outside this fixture measurement.
'''
p.write_text(text)
p=b/'README.md';text=p.read_text().replace('最新检查额度剩余36%', '最新检查额度剩余34%');heading='## 整帧拷贝、透明度与调度复测';text=text.split('\n'+heading)[0]
text+='\n'+heading+'''

先前31轮完整链路的原始数据与[24轮候选对照表](transport/README.md#additional-copy-alpha-and-scheduling-comparisons)均已归档。自有源纹理直接提交与R8透明度摘要组合，两次开启测得31.24–31.53FPS，延迟估计中位78–83ms、P95为95–100ms，均优于这组对应关闭测试；仍未达到60ms。

在加入生命周期修复的相同程序上，跳过未变化画面使不同画面帧率从30.97–31.27提高到32.80–33.21FPS；四轮延迟区间重叠，尚不能确认稳定收益或代价。四种源流在相同90个画面标记上逐RGB像素比较，合成图案PSNR均约41.871dB；自然图像和文字质量还未据此验证。

静止窗口缩放后停止更新、窗口关闭后短暂发布错误元数据两个问题已修复。单窗口、多窗口、标题、位置、缩放、隐藏和关闭的21帧记录均通过Linux GPU解码、上传和逐像素透明度验证；这是离线生命周期检查，未替代实际Wayland窗口验收。当时31文件Windows构建及四项测试通过；下方记录了后续39文件规范构建及实际安装。

完整6K30/60ms目标仍未完成；当前规范版本及两个性能选项已安装，后续继续优化时延。源程序绘制前时间与最终桌面观察之间的时延估计，不等于物理屏幕扫描时延。
'''
text=text.replace('源端优化候选尚未覆盖已安装Windows反向程序，后者哈希前缀仍6ec79a73。','这些历史源端测量期间，已安装程序仍为6ec79a73；当前规范版安装见下方。')
text=text.replace('后续继续优化编码输出节奏、测量捕获至实际Linux画面的完整链路，并接入反向帧率优先／延迟优先选项。','目前两档控制和规范版已经安装，继续优化编码器与完整链路时延。')
if '当前已安装的Windows反向程序' not in text:
 text=text.replace('[双端GPU基线]', '当前已安装的Windows反向程序为 **E1543F07…**，默认帧率优先，两轮规范版完整链路为 **32.947／33.509FPS**、时延估计上界中位 **80.156／78.406ms**。两个方向各自提供帧率优先／延迟优先；主会话保持未启动，下一次开启使用新版。[部署与回退记录](production-deployment/README.md)。\n\n[双端GPU基线]',1)
text+='''

## 规范集成、调度复测与安装

完整链路现有43轮有效测量，新增队列、进程调度和规范构建的12轮[对照](transport/README.md#queue-bounds-process-priority-and-installed-canonical-build)。单帧／四帧上限下提交前队列均为空，未证明这项限制带来收益；进程Normal优先级的重复分布也交叉，因此不提高默认进程优先级。

最终39文件规范构建通过六项Windows测试，窗口生命周期与运行中三次模式切换通过GPU验证。复制期间尺寸变化会重做当前帧，避免发送被清空的透明窗口。程序已安装到原配置路径，完整SHA256为E1543F0754BAE0741955EF5FBD178262ED10AFE05E3845060E28AAC4121B93D0；已安装控制器的真实模式往返通过。源配置、原输入服务及显示矩形保持，主会话将在下次开启时使用新版。

本阶段仍未达到60ms。继续优化时保留已部署版本，并遵守额度剩余10%之前停止实验、应用已测最佳版本与两个选项的要求。
'''
p.write_text(text)
print('candidate reports refreshed')
