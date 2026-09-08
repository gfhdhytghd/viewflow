# 已撤回：在布局稳定时更新已绑定的 atlas 表面

2026-09-08。针对逐帧更换 CompositionDrawingSurface 并调用画刷 `Surface(...)` 的路径，实际实现并运行了原位更新对照。**没有观察到稳定的桌面帧率或延迟收益，实验代码已撤回，隔离接收端的可执行文件与匹配 PDB 已逐字节恢复。** 4K60、两帧内呈现仍未验证。

## 实际实验路径

同一个原生二进制由 `VIEWFLOW_ATLAS_INPLACE_SURFACE=0/1` 控制，默认关闭。启用时，只有上一帧与当前帧的 stream、epoch、config、revision、atlas 尺寸、tile 映射、patch、opaque 分类、desktop placement/topology/stacking 等字段一致，且现有 sparse scene 可直接复用、实际 HWND 仍可见并具有预期客户区尺寸及位置，才允许重用已绑定的 atlas 表面。帧身份及源时间戳正常前进不妨碍重用。

所有场景准备和几何检查在写入之前完成，之后调用既有 BeginDraw→完整 GPU copy→EndDraw 更新当前表面，跳过画刷 Surface 重绑。任一条件不满足就回到正常的未绑定表面路径，未增加帧准入或会话限制。新旧像素仍由同一帧的不可变布局路由；没有添加 GPU 完成等待或新的性能截止条件。保存了完整[实验主程序](source/main.cpp.experiment)和[映射比较实现](source/stable_surface_layout.h.experiment)。

该实现是已经撤回的实验快照，不是当前生产代码。原位更新可以减少一次表面重绑，但未改变本实验的最终等待；不能仅凭减少调用次数认定性能改善。

## 正确性验证

- Windows MSVC Release 原生构建与现有 atlas frame binding 测试通过。独立布局用例验证 20 种映射变化会回到普通路径，帧身份和时间戳递增仍允许复用。[布局用例](method/stable-surface-layout-test.cpp)、[结果](layout-test.log)
- 扩展已有 GPU 像素 oracle 为 84 个阶段：不同 alpha、透明洞、多区域模糊背景、三种缩放、整数和子像素偏移、布局变化与重复更新。参考侧每次使用独立的新表面；候选侧共 48 次更新已绑定表面而不重绑画刷。所有阶段 mismatches=0、verified=1，原生程序 exit=0。[完整像素日志](method/inplace-pixels.log.gz)、[实际用例源码](method/inplace-pixel-test.cpp)
- 像素 oracle 捕获自己创建的 visual tree，没有捕获用户窗口、注入键鼠或改变焦点。它验证绘图与遮罩正确性，不替代完整流水线性能对照。

## 四轮交错性能对照

源内容为 3840×2400，含边框的捕获为 3848×2408。Windows 实际输出 6144×3456@60，Intel GPU；测试自己的 proxy 以 1:1 像素放置。它不是物理 4K 面板验证。每轮 25 秒视频、20 秒桌面观察；顺序 A1/B1/B2/A2，使用同一个原生二进制与桌面观察器，timer1、alpha 复用和 GPU/socket timing 配置一致。

| 表面更新 / 轮次 | 原生 commit/s | 所见桌面 marker/s | capture→所见桌面上界中位 ms | P95 ms | capture→原生 mutation 上界中位 ms |
|---|---:|---:|---:|---:|---:|
| 原路径 / A1 | 57.89 | 40.89 | 49.69 | 65.60 | 15.38 |
| 原位 / B1 | 58.66 | 40.40 | 49.89 | 66.09 | 15.37 |
| 原位 / B2 | 58.52 | 40.94 | 50.60 | 64.69 | 15.42 |
| 原路径 / A2 | 58.28 | 39.61 | 49.46 | 65.37 | 15.32 |

原位路径的原生提交率略高，但没有一致的桌面观察速率改善，所见桌面延迟中位数也略高。四轮不足以把小幅 native commit/s 差异确认为产品 FPS 收益。没有采用这项改动。[完整对照统计](comparison.json)

B1 的 23 条、B2 的 22 条每 60 帧诊断均记录 applied=1，证明实验路径确实执行。A1/A2 没有启用路径。该诊断是按帧抽样，不代表每一帧都在诊断日志中。[接收端原始日志 B1](4k-inplace1-b1/receiver.log.gz)、[B2](4k-inplace1-b2/receiver.log.gz)

唯一像素身份配对分别为 804/798/762/738；源端对同一 marker 的重复捕获分别 5/0/49/46 条，没有用于延迟统计，也未拿相邻 marker 补配。对应桌面 marker 和正的 LastPresentTime 严格递增，slot 序号严格递增，所有 ring abandoned=0。原始四时间戳交换通过复算，使用的映射有效期覆盖桌面端点，配对 commit→所见桌面与 mutation→所见桌面没有负值。

## 测量限制

桌面观察器会漏读更新，所以所见 marker/s 不是已证明的真实显示 FPS。延迟上界计入跨机时钟不确定度，结束点为读到该像素的 DXGI LastPresentTime，不能保证是 marker 首次出现在桌面的时刻。不能据此直接判断所有帧是否通过两帧目标，也不能把观察器约 11 ms 的 copy/map 跨度从 LastPresentTime 延迟中相减。

实验主程序中，原位路径把实际 bound copy 延迟到所有场景校验之后，但早先的 `copy-ready` 日志仍在场景准备处。因此 **原位路径的 copy-ready 表示准备好了场景元数据，不表示完成了 GPU copy**。分析器明确保存此限制；上表的 capture、mutation、commit、desktop 端点不使用该阶段来推断 copy 完成。GPU copy completion probe 在实际 copy 后提交，仍只有轮询边界，不是 DWM 呈现时间。实验被撤回，没有将这个诊断含义不一致的路径保留到生产代码。

## 控制与恢复

每轮前后实际读回 ESRV 进程和当时两个 TimeCritical 线程的 Normal/base8 状态，并确认没有其他 TimeCritical 线程；没有持续采样整段期间。每组开始前建立了独立 10 分钟 SYSTEM 恢复任务，绑定 PID、进程与线程创建时间，finally 恢复 High + 两个 TimeCritical 后删除任务。未停止、重启或禁用服务。

四轮 source 均按计划结束，receiver 随 peer 关闭，watchdog 未触发，观察器均 exit=0。实验自己的 Linux 输出已移除，前后 monitor 列表与焦点读回一致。最后 Windows 核验见[最终状态](method/inplace-final-state.json)：ESRV Running/Auto、PID 2344、High、两条 TimeCritical 线程，实验进程与计划任务均为 0。

原生主程序、GPU pixel test 的源文件与实验前逐字节一致，新增映射 header 已从构建路径移除；实验源码及二进制/PDB另行冻结。隔离主程序恢复到 `81CB49DD9269A50B7FB6124539F8034EDB094BD54700707E2BDF0F2E1442E0B4`，匹配 PDB 与备份哈希一致。Rust receiver、桌面观察器和源端二进制未因本轮改变。没有替换日常运行版本。[实验二进制清单](method/inplace-experiment-binaries.json)、[恢复核验](method/inplace-restored-binaries.json)

## 复算与参考

每个 trial 目录保存 source/receiver/desktop/runner/cleanup/producer 压缩原始日志、fixture、逐 marker 配对和摘要。method 包含实际构建、运行、独立恢复与分析脚本；绝对路径记录当时的隔离环境，不能不加检查地再次执行恢复或测试脚本。SHA256 清单覆盖本目录文件，清单自身除外。

从仓库根目录复算时，将 source/receiver/desktop 日志解压为 `/tmp/viewflow-integrated-pair/{kind}-{label}.log`，producer 解压为 `/tmp/viewflow-frame-fixture-first/{label}-source.log`，再运行 `method/summarize-inplace.py`，依次传入四个 trial 标签。分析依赖的 `profile_atlas_timeline.py` 与 `summarize_desktop_markers.py` 快照位于 source/tools。

[Microsoft ICompositionDrawingSurfaceInterop::BeginDraw](https://learn.microsoft.com/en-us/windows/win32/api/windows.ui.composition.interop/nf-windows-ui-composition-interop-icompositiondrawingsurfaceinterop-begindraw) 支持更新已有表面的指定区域。API 支持该操作仅说明实现可行，性能与像素正确性由本实验分别验证。
