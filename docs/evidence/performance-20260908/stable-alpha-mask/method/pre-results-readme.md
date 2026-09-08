# 完整毛玻璃：独立 alpha 遮罩候选

状态：两个隔离诊断程序已经 Windows 原生编译通过；**尚未取得图像一致性或性能运行结果，未接入产品**。运行准备过程中 Windows 重启，当前没有已登录用户，交互式任务无法启动。已请求用户登录桌面。此前全链路的 4K60 / 两帧内显示目标仍未验证。

## 具体假设

当前稀疏渲染将同一个 `CompositionSurfaceBrush` 同时用作前景和背景效果图的 alpha 来源。每帧切换彩色表面时，即使 alpha 完全相同，背景效果图的输入也会变化。候选让背景图保留一个独立的 alpha 来源，前景继续逐帧更新。它保留相同的高斯模糊、遮罩坐标与实时 `CreateHostBackdropBrush`，不冻结或关闭桌面背景。

这只是假设：尚不能断言 Windows 会因此减少背景重算，也不能声称提高最终 FPS。`SourceIn` 的遮罩只使用输入 alpha，允许单独保留这份信息；Windows 的实际调度和缓存收益仍需原生实验。[微软 Composite 效果](https://learn.microsoft.com/en-us/windows/win32/direct2d/composite)、[CompositionMaskBrush](https://learn.microsoft.com/en-us/uwp/api/windows.ui.composition.compositionmaskbrush?view=winrt-26100)

## 已准备的验证

- [windows_mask_update_probe.cpp](../../../../tools/windows_mask_update_probe.cpp)：3848×2408 GPU 动态前景，四个边界背景节点全程保留，sigma=12。边界 alpha=128、中心和 frame marker 为 255，最外层为 0。只切换背景遮罩引用：每帧变化的彩色表面 / 初始表面的恒定 alpha。前景图案的 alpha 由固定坐标决定，颜色才随 frame ID 变化。两个相反顺序的 33 秒运行，每 240 个实际提交帧切换，每段前 30 帧排除统计。DD 观察器终点仍不是首次显示或光子时间。
- [sparse_alpha_mask_test.cpp](../../../../platform/windows-composition-preview/sparse_alpha_mask_test.cpp)：12 阶段原生图像对照，覆盖前景颜色变化、后方窗口颜色变化、布局重排、alpha 128→64→192→128、缩放 1/0.75/0.5、0.25 像素偏移及恢复。所有三个面板都保留完整模糊。以解析得到的未模糊颜色作为数值对照，不创建关闭模糊的面板。另提供故意不刷新变化 alpha 的负例，预期第 4 阶段失败，用来检查测试是否能发现旧遮罩。

当前 oracle 保留首次/变化时的整张 BGRA 表面，只取其 alpha。它不是产品缓存实现，也不声称节省显存。真正集成时需将不可变 alpha 身份与解码帧绑定，尺寸变化必须失效；未提供可信 alpha 所有者时应更新遮罩，不能错误复用上一帧。实时背景内容发生变化时仍须由 HostBackdrop 正常更新。

## 当前证据

| 项目 | 实际状态 |
|---|---|
| 性能探针原生构建 | 通过，EXE `D43944326F61180A54117A64CFEA856EDE5CB874222FFB37C43D6190619A5B0C` |
| 图像 oracle 原生构建 | 通过，EXE `CA6B442F81FDA6C555279921A3EA6BC58DD5524B5182C1078039D00FD35E5C30` |
| Oracle 编译输入身份 | 38 项文件在 Windows 与本地逐项匹配 |
| 正向 / 负向图像运行 | 尚未执行 |
| 两轮性能运行 | 未完成；首次交互式任务未启动，没有性能日志 |
| 产品代码和效果参数 | 未接入候选，完整背景保留 |

初次 oracle 链接缺少 `user32.lib`，补齐后原生构建通过；失败日志另行保存，没有把失败构建当作测试成功。运行准备时 SSH 中断，后来通过 Windows boot timestamp 确认重启。恢复任务不存在；重启后尝试图形任务时没有已登录用户，任务未真正启动，已清理任务。ESRV 服务随后自动启动是环境变化，本轮没有改变它的优先级。[运行前后的环境](failed-start/controls-state.json)、[失败启动状态](failed-start/probe-mask-ab-state.json)、[最新桌面与清理状态](method/current-desktop-state.json)、[原生 oracle 输入身份](method/oracle-native-identity.json)。

## 登录桌面后执行

所有命令从仓库根目录执行。先运行 `python docs/evidence/performance-20260908/stable-alpha-mask/method/run-oracle.py positive`，再用相同命令将参数改为 `stale-mask`。正例应有 12 个 `verified=1`；负例应明确在 alpha 改变时失败，不能只以任意非零退出码当作有效负例。两种模式都会保留运行日志与任务状态。

之后从仓库根目录运行 `python docs/evidence/performance-20260908/stable-alpha-mask/method/controls.py` 和 `python docs/evidence/performance-20260908/stable-alpha-mask/method/analyze.py`。脚本记录同一 boot 下服务状态与优先级的前后快照；不改变优先级。运行和构建脚本中的 Windows 主机、隔离目录与 `/tmp` 是本次环境，需要在其他环境替换。源码与构建脚本已经归档，临时成功构建清单也保存于 method，重现时应从受测 EXE 重新生成该清单。

下一步的采用条件是：图像正/负例有效，完整背景条件下有可重复的性能收益，再接入真实远程链路测试。构建通过本身不满足这些条件。
