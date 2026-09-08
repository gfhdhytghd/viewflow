# GPU 相对调度优先级对照：未采用

2026-09-08，Windows 原生 GPU 解码/合成设备。**驱动接受了相对优先级 7，但四轮交错对照没有显示稳定的呈现延迟或帧率收益。试验代码已撤回，恢复原有设备创建路径；4K60 / 两帧内显示目标仍未验证。**

## 假设与实际控制

此前测量仍有约一到两次刷新间隔的 GPU/呈现等待。本轮仅在 `CreateHardwareDevice` 成功后，对 Viewflow 自有 D3D11 设备设置 `IDXGIDevice::SetGPUThreadPriority(0/7)`，并立即读回前后值。没有更改 DWM、系统 GPU 策略、网卡或服务启动配置。

Microsoft 文档定义相对优先级范围为 -7 到 7，默认值为 0，并要求通过测量判断对应用与系统的影响。本轮没有使用绝对优先级或实时等级。[Microsoft API 契约](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgidevice-setgputhreadpriority)。Sunshine 的 Windows capture 设备初始化也使用相对优先级 7；这只是选择实验值的依据，其 capture 场景不证明 Viewflow 接收端会受益。[Sunshine 实现](https://github.com/LizardByte/Sunshine/blob/master/src/platform/windows/display_base.cpp)

四轮使用同一试验二进制，顺序 **0 A1 / 7 B1 / 7 B2 / 0 A2**。每轮原生日志均且仅有一次优先级记录：`before=0`、`observed=requested`，查询、设置、再次查询的 HRESULT 全部为 0。试验提示拒绝不会导致工作设备或远程会话失败；没有加入新的定时退出条件。

内容为 3840×2400，捕获含边框为 3848×2408；Windows 桌面 6144×3456 @ 60 Hz，内容以 1:1 像素显示。原有 blur=12、alpha 引用/缓存和源端 GPU alpha 比较保留。每轮视频运行 25 秒、异步桌面观察器运行 20 秒，源端阶段计时、socket tracing 与已有 GPU completion 诊断开启；没有 WPR 或包捕获。没有注入输入或激活窗口。

为控制已定位的 CPU 调度干扰，重新查询 ESRV 服务当前 PID 2344、进程创建时间及两条 TimeCritical 线程 12232 / 16604 的创建时间。四轮前后均读回进程 Normal、这两条线程 Normal/base 8，且没有其他 TimeCritical 线程。所有轮次结束后读回原进程 High、两线程 TimeCritical/base 15，并删除独立的定时恢复任务。没有沿用上一轮已经失效的 PID 8108。

## 测量结果

| 轮次 | 原生 commit/s | 桌面标记观察/s | 捕获→被观察桌面上界中位 ms | 上界 P95 ms | mutation→被观察桌面中位 ms |
|---|---:|---:|---:|---:|---:|
| 0 A1 | 56.802 | 39.726 | 50.656 | 64.820 | 34.278 |
| 7 B1 | 57.777 | 39.440 | 51.495 | 66.536 | 35.404 |
| 7 B2 | 57.850 | 41.148 | 50.444 | 65.940 | 34.750 |
| 0 A2 | 58.367 | 40.908 | 50.780 | 65.714 | 34.323 |

两组延迟分布高度重叠；默认优先级 A2 的提交率高于两轮 7，mutation→desktop 也没有因 7 而下降。A1 出现单次很长的停顿，捕获→被观察桌面的上界最大约 387.881 ms，另外三轮最大约 114.622 / 139.057 / 109.274 ms。不能只比较 A1 与 B1，把该次停顿缺席误判为优先级修复。

捕获→native mutation 上界中位约 15.287–15.439 ms。GPU copy completion 的轮询上界中位约 15.996–16.323 ms，各轮下界中位均为 0：此时轮询区间过宽，不能声称实测 GPU 执行刚好耗时 16 ms。部分 completion 的后续轮询晚于桌面观察，产生负的“完成上界→桌面”下界；这只表示该下界不具约束力，不能解释成负的物理延迟。

表中桌面数值仍有[观察器漏采限制](../async-desktop-observer/README.md)。`LastPresentTime` 不是光子凭据，也未证明是标记首次显示时间；原生 commit/s 也不是实际显示 FPS。因此本轮既不支持采用该优先级提示，也不支持宣布 60 fps 或 ≤33.33 ms 达标。

## 身份、校验与恢复

- 四轮分别保留 786 / 778 / 810 / 801 个唯一源 GPU 标记→atlas frame→native commit→桌面像素关联。A2 的 4 个重复捕获标记因身份歧义排除，没有以相邻帧补齐。
- 标记 ID、正数呈现时间戳和异步 readback 序号严格递增；没有负的 commit→desktop、mutation→desktop 或捕获延迟上界。全部关联的桌面时间上界仍位于所选时钟映射有效期内，原始四时间戳校准复算通过。
- 四轮观察器均 `exit=0`、pending 峰值为 2、未完成/丢弃槽位为 0；视频 runner 的 watchdog 均为 0，计划停止后隔离进程和任务清理完成。Linux 临时输出已删除，原输出与焦点观测一致。
- Windows MSVC 原生构建通过，现有 alpha parser 与 frame bindings 检查通过；撤回后重新构建通过。试验的原生 EXE 与匹配 PDB 留在隔离目录供复查，日常运行版本没有部署变更。
- 活跃源码 `platform/windows-video-compositor/video_compositor.cpp` 已逐字节恢复试验前版本；`video_compositor.cpp.experiment` 仅为证据中的历史文本。源端二进制、CUDA 实现、socket trace、观察器源码均与试验前摘要一致。

各轮原始压缩日志、完整分位数、逐帧身份、构建记录、设置读回、恢复记录及 SHA-256 清单均在本目录。`windows-final-state.json` 记录收尾时实际服务进程、线程、隔离进程/任务数量和二进制摘要。没有把调高优先级保留为默认“优化”。
