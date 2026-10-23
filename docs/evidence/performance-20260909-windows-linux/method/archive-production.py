"""Archive queue, scheduling, canonical integration and deployment evidence."""
from pathlib import Path
import hashlib,json,shutil
b=Path(__file__).resolve().parent.parent;root=b.parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text())
def write(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def table(labels):
 rows=['| Trial | Distinct FPS | Median upper ms | P95 upper ms | Maximum upper ms |','|---|---:|---:|---:|---:|']
 for label in labels:
  s=read(b/'transport/runs'/label/'summary.json');v=s['latency_high_ms'];rows.append(f"| {label} | {s['desktop_distinct_hz']:.3f} | {v['median']:.3f} | {v['p95']:.3f} | {v['max']:.3f} |")
 return '\n'.join(rows)
for name in ['queue-depth','process-priority','root-performance','root-performance-v2']:
 p=b/name;m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json');assert len(m)==39 and all(sha(p/'source'/k)==h for k,h in m.items())
 count=6 if name.startswith('root-performance') else 1
 assert f'100% tests passed, 0 tests failed out of {count}' in (p/'method/build.log').read_text()
 if name=='root-performance-v2':assert all(sha(root/k)==h for k,h in m.items())
q=['queue-1-b1','queue-4-a1r','queue-4-a2','queue-1-b2'];pr=['priority-off-a1','priority-on-b1','priority-on-b2','priority-off-a2'];prod=['root-frame-a1','root-latency-b1','root-latency-b2','root-frame-a2']
for label in q:
 s=read(b/'transport/runs'/label/'pipeline-occupancy.json');assert set(s['before_submit'])=={'0'}
alpha=b/'root-performance/method';assert read(alpha/'alpha-exact-status.json')['exit']==0
text=(alpha/'alpha-exact.log').read_text();assert text.count('alpha_async_exact ')==6 and text.count('alpha_summary_exact ')==9
for name in ['alpha_plane.cpp','alpha_plane.hpp','compact_alpha_plane.cpp','compact_alpha_plane.hpp','alpha_async_probe.cpp']:
 assert (b/'root-performance/source/platform/windows-reverse'/name).read_bytes()==(b/'root-performance-v2/source/platform/windows-reverse'/name).read_bytes()
life=b/'lifecycle-v3';m=read(life/'method/windows-source-sha256.json');assert m==read(life/'method/windows-remote-source-sha256.json') and all(sha(life/k)==h for k,h in m.items())
for p in (life/'source/platform').rglob('*'):
 if p.is_file():assert p.read_bytes()==(b/'lifecycle/source/platform'/p.relative_to(life/'source/platform')).read_bytes()
for label in ['root','root-v2']:
 s=read(life/'runs'/label/'summary.json');assert s['qualified'] and s['frames']==s['decoded'];assert [x['mode'] for x in s['mode_events']]==['frame-rate','latency','frame-rate','latency']
# The earlier root-level summary remains an explicitly labeled initial-run copy.
assert read(life/'summary.json')==read(life/'runs/root/summary.json')
texts={
 'queue-depth': '# Encoder queue-depth comparison\n\n2026-09-09. All four successful trials use one 39-file native build and retain direct submission, render alpha summary and capture-change skipping. The order is B/A/A/B. The initial depth-4 launcher failed its cloned 0/1 argument validation before any Windows task or peer started; its method, failure and completed nested cleanup are preserved under transport/runs/queue-4-a1.\n\n'+table(q)+'\n\nEvery logged successful submission has pending=0 even with a configured limit of four. The encoder input-ready event already serializes this workload. Thus these samples do not establish a throughput or latency benefit from changing the pending limit. Modes still define different admission bounds; neither is represented as a guaranteed faster result. Source/remote input hashes match and the tracker CTest passes.\n',
 'process-priority': '# Native process priority comparison\n\n2026-09-09. The private candidate requests Normal priority for its own process only. Its main thread and 15 sampled threads move from base 6 to 8; ten lower-priority threads move from 4 to 6. The task remains priority 7. All changes are private to the bounded native child, with no registry or installed program change.\n\n'+table(pr)+'\n\nThe repeated distributions overlap and median/P95 reverse direction, so Normal process priority is not adopted. The 39-file local and Windows source maps match; the tracker test passes. Actual process/thread snapshots are in each transport state.json.\n',
 'root-performance': '# Initial canonical performance integration\n\n2026-09-09. This historical 39-file canonical snapshot integrates encoder readiness and speed 0, asynchronous alpha, render-first compact alpha, owned-source direct submission, capture-version/metadata tracking and the lifecycle fixes. Diagnostic logs and fixture PID filtering are opt-in. It also adds validated legacy coordinates, frame-rate/latency options, a watched mode file and a status command that exits before opening the desktop or creating a graphics device. Six Windows CTests pass. The exact-alpha hardware probe validates 33 frames at three dimensions, including every byte value and the single nonopaque edge pixel.\n\nThe source-to-recorded-stream-to-Linux-GPU lifecycle run passes all '+str(read(life/'runs/root/summary.json')['decoded'])+' frames, including three observed live mode changes. This initial binary was not installed: root-performance-v2 additionally avoids sending a cleared tile when resize races metadata/copy and initializes a diagnostic VARIANT. The controller test initially looked for a compiler-inlined option string; it now checks the retained status printf format before invoking a legacy program. Actual legacy refusal and settings roundtrip are archived.\n',
 'root-performance-v2': '# Installed canonical reverse performance build\n\n2026-09-09. The 39 source files match the canonical workspace and the Windows stage. All six CTests pass. Relative to the initial integration, a copy/metadata resize race retries the frame while preserving the last presented image; the encoder diagnostic VARIANT is initialized. The alpha implementation and exactness probe sources are byte-identical to the initial build that passed the 33-frame GPU probe. This final binary independently passes the full lifecycle/GPU test, including live mode changes.\n\n'+table(prod)+'\n\nThese final full-chain trials use the watched mode file through the real controller, including native polling overhead. The native is identical in all arms, direct/alpha/capture-change routes are verified, and each test restores its previous private setting. The installed Linux native and the measured Linux native have identical SHA256 768f11a5fde4145349349cca3cc869981179981055b1eb25527981a2174488be. Mode distributions overlap; no 60 ms claim is made.\n\nThe Windows native SHA256 is E1543F0754BAE0741955EF5FBD178262ED10AFE05E3845060E28AAC4121B93D0. It is now installed at the existing configured path; see ../production-deployment/README.md.\n',
 'lifecycle-v3': '# Canonical lifecycle and live settings changes\n\n2026-09-09. The same nonactivating owned-window fixture now runs the canonical native with opt-in diagnostics. Both runs change modes frame-rate → latency → frame-rate → latency through the real SSH controller while capture continues. Every emitted record passes Linux NVDEC/CUDA/GLES upload and exact alpha, and all seven title/move/add/resize/hide/close phases are observed. This is recorded-stream lifecycle validation, not live Wayland or physical-input acceptance.\n\n'+ '\n'.join(f"- {name}: {read(life/'runs'/name/'summary.json')['decoded']} decoded frames; {read(life/'runs'/name/'summary.json')['resize_recoveries']} resize recoveries." for name in ['root','root-v2'])+'\n\nThe resize recovery count is observed, not forced: a resize can deliver a new frame without needing the 500 ms retry. The earlier lifecycle-v2 trace exercises that retry. Phase timestamps follow Win32 actions, so signed differences are not action-to-output latency. Per-run summaries are authoritative; root-level summary.json is the preserved initial root run. The Linux probe sources match the previously compiled probe.\n'
}
for name,text in texts.items():(b/name/'README.md').write_text(text)
# Preserve verification outputs for the code and controls actually installed.
p=b/'production-deployment';installed=read(p/'method/install-state.json');verified=read(p/'method/verified-installed.json');assert installed['installed'] and verified['windows']['hash']==installed['windows']['hash']
assert installed['windows']['status']['mode']==verified['windows']['status']['mode']=='frame-rate'
for src,dest in [('/tmp/viewflow-reverse-production-install.log','method/install-attempt1/launcher.log'),('/tmp/viewflow-reverse-production-install-v2.log','method/install.log'),('/tmp/viewflow-reverse-production-verify.log','method/verify.log')]:
 if Path(src).exists():shutil.copy2(src,p/dest)
(p/'README.md').write_text('''# 已安装的 Windows → Linux 优化与双向模式控制

2026-09-09，额度剩余34%时安装。Windows反向程序已替换为规范构建 **E1543F07…**，默认 **帧率优先**；Linux → Windows 的既有默认 **延迟优先** 保持。Quickshell控制面板现有两个方向各自的两档按钮。

新版本采用异步透明度、R8不透明摘要、编码器输入就绪检查、单窗口自有纹理直接提交与重复画面跳过，并包含缩放恢复、关闭窗口元数据和复制期间尺寸变化的修复。完整39文件Windows构建及六项CTest通过，最终二进制的窗口生命周期和运行中三次切换均通过GPU验证。[构建及四轮完整链路结果](../root-performance-v2/README.md)。

帧率优先两轮为 **32.947／33.509个不同画面/秒**，绘制前至Linux桌面观察的时延估计上界中位 **80.156／78.406ms**，P95 **96.916／95.391ms**。仍未达到60ms，也不等于物理屏幕扫描测量。单帧模式在这台Intel机器上没有显示稳定优势；队列在每次提交前均为空，两档上限未成为这次工作负载的瓶颈。[模式定义](../../../reverse-performance.md)。

已安装程序仍使用原 `receive.json` 中的反向路径及四个坐标，配置字节未变。Linux两个源配置字节未变，现有输入服务保持active；主Linux桌面服务原本inactive，Windows主任务原本Ready，安装没有启动或重启它们。**新反向程序在下次开启穿透时使用**。安装路径上的真实脚本往返选择latency、frame-rate均读回成功，最终为frame-rate；这与此前隔离原生进程内的动态切换验证是不同检查。

Windows完整SHA256：`E1543F0754BAE0741955EF5FBD178262ED10AFE05E3845060E28AAC4121B93D0`。Linux实际安装与测量接收程序均为 `768f11a5fde4145349349cca3cc869981179981055b1eb25527981a2174488be`。显示矩形、缩放和旋转读回一致，未注入鼠标、键盘或焦点操作。

Windows及Linux原文件的备份目录记录于 [install-state.json](method/install-state.json)。首次入口超过Windows命令行长度限制，确认旧文件仍在；改为上传PS1后安装成功。失败入口记录保留在method/install-attempt1。最终程序、控件、配置、服务和显示状态见 [verified-installed.json](method/verified-installed.json)。QML静态检查通过，Quickshell日志有配置加载成功记录；未把该检查当作用户物理点击验收。基础shell.qml的supplementaryInfoVisible绑定循环警告也保留在原始日志，未修改其代码。

部署脚本是针对当时旧哈希与路径的一次性操作，不能当作通用升级命令重跑。日常模式切换使用已安装按钮或项目的 `tools/viewflow-reverse-performance.py`。
''')
for name in ['queue-depth','process-priority','root-performance','root-performance-v2','lifecycle-v3','production-deployment']:
 p=b/name;files=sorted(x for x in p.rglob('*') if x.is_file() and '__pycache__' not in x.parts and x!=p/'sha256.json');write(p/'sha256.json',{str(x.relative_to(p)):sha(x) for x in files});print(name,len(files))
print('production evidence verified and archived')
