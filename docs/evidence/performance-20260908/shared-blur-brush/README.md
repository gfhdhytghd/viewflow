# 复用 Windows HostBackdrop blur brush

**原生像素与实际复用路径均通过；完整链路性能没有稳定改善，候选保持关闭，不接入生产效果图。** 开启两轮的完整延迟中位为 25.24 / 29.43 ms，关闭为 28.50 / 38.56 ms；但桌面更新率有交叉，原生提交速率几乎不变，且关闭轮本身相差约 10 ms，不能把全部差异归因于复用。4K60、两帧内首次显示仍未证明。

| 轮次 | 原生提交/秒 | 完整 30 秒内不同 marker/秒 | 绘制前→DD 上界中位 / P95 / 最大 ms |
|---|---:|---:|---|
| sharedblur-v1-off-a1 | 59.313 | 57.167 | 28.504 / 29.770 / 112.360 |
| sharedblur-v1-on-b1 | 59.372 | 55.933 | 25.237 / 26.537 / 108.729 |
| sharedblur-v1-on-b2 | 59.298 | 58.767 | 29.433 / 30.452 / 114.038 |
| sharedblur-v1-off-a2 | 59.107 | 58.500 | 38.559 / 39.865 / 122.501 |

捕获→桌面上界中位为 28.15 / 24.94 / 29.06 / 38.12 ms，绘制→捕获中位均约 0.28–0.40 ms。所有画面 marker 有效；最后关闭轮有一个重复捕获 marker，只从要求唯一身份的分段统计排除，完整端到端统计保留。慢回执 >20 ms 分别为 9 / 8 / 8 / 11 次，网络／接收调度长尾仍在。

本测试测的是完整端点与应用阶段，不包含独立的 DWM GPU 重算计数。当前结果既不能证明复用减少了 DWM 计算，也不能把所有关／开差异都解释为 blur 算法差异。[原始端点及阶段统计](comparison.json)、[默认导入缓存统计](import-comparison.json)。

2026-09-09。该候选把 GaussianBlur 从每个 patch 的 alpha 合成图中提取出来，由同一稀疏场景的多个 masked brush 引用一个 blur brush。保留 sigma=12、BALANCED、HARD，仍直接采样当前 HostBackdrop；没有保存背景截图、降低背景更新率或近似模糊核。

微软的 [SetSourceParameter](https://learn.microsoft.com/en-us/uwp/api/windows.ui.composition.compositioneffectbrush.setsourceparameter?view=winrt-26100) 接收 CompositionBrush，并把它关联到效果源参数；[源参数文档](https://learn.microsoft.com/en-us/uwp/api/windows.ui.composition.compositioneffectsourceparameter?view=winrt-26100)说明了该关联。复用 brush 对象是否减少实际 GPU 重算需要测量，不能从对象数量直接推出性能收益。

## 原生像素及路线验证

候选以 `VIEWFLOW_SHARED_BLUR=0/1` 选择完整图／复用图，默认关闭。原生测试在实际 3840×2400 显示器上创建自有、不激活、鼠标穿透的窗口；三块 256×256 面板分别为独立旧参考、当前候选、不加额外模糊的对照。四个阶段验证两次纯色背景变化、32 像素条纹、删除一个 patch 并重新打包 atlas。

最终两次运行均返回 0。每个阶段读取当前场景，断言两个 masked patch 绑定同一场景的 backdrop 输入；关闭时该输入为原始 HostBackdrop，开启时是独立 blur brush，`actual_shared=0/1` 与请求一致。所有 RGB 通道在现有 2/255 容差内，四个阶段 `mismatched_channels=0`，没有从图中删除背景效果；条纹阶段与不模糊对照有 110,592 个 RGB 通道差异超过 5，背景响应值 80。

保存的条纹阶段完整面板数据在关闭／开启两轮逐字节一致；两者与独立参考均只有最大 1/255、平均 0.03646/255 的 RGB 差异。这个逐字节结论仅针对保存的条纹阶段，其他阶段按实际运行的 2/255 容差检查，不扩大为所有应用的视觉验收。

![左：独立参考；中：复用 blur 候选；右：未额外模糊对照](oracles/shared/host-blur-panels.png)

第一版像素测试虽然通过，但只记录请求开关，未读取实际 brush 绑定，不能单独证明候选路径生效。其源码、二进制身份及结果保存在 `method/oracle-v1-no-route-readback.cpp`、`source-v1-sha256.json` 和 `oracles-v1-no-route-readback`。补充路线断言后仅重建 oracle，再用新输出目录完整运行两组；没有覆盖旧证据。最终 oracle 与性能用原生呈现器使用同一版效果头文件。

## 性能方法及源码范围

以 Hyper-V 计时器修复后测量使用的完整原生源快照为基线，111 文件中仅修改效果头文件和 oracle。该快照包含默认关闭的直接绘制实验，与根工作树有若干既有差异，清单保存于 `baseline-root-differences.json`；本候选没有把旧快照整体写回根工作树。修改的 `sparse_shared_visuals.h` 在基线与根工作树原本逐字节相同。远端已上传源码全部 111 个 SHA256 与本地一致。

同一个新原生呈现器与同一个 GUI runner 进行关／开／开／关四轮。runner 固定普通输出、完整 sigma=12 blur、背景缓存关闭、GPU 查询关闭，只改变 `VIEWFLOW_SHARED_BLUR`。每轮记录实际 blur 场景创建日志，不能仅凭 runner 环境变量认定执行了候选。

Linux 使用已接入默认导入缓存的新 sender，source 环境中删除 `VIEWFLOW_GPU_IMPORT_CACHE` 覆盖，实际缓存命中日志独立验证默认生效。四轮均为延迟优先、60 Hz，source 55 秒、DD 观察 30 秒，保持隔离嵌套 compositor、3840×2400 GPU fixture、scale 2、atlas 3968×2432。Hyper-V 与按需亮度读取设置保持已应用状态，Intel 遥测优先级保持原值。

本轮所有编译、GPU 正确性检查和原生像素测试均在四轮性能测量之前完成。DD LastPresentTime 代表含该 marker 的一次桌面更新时间，可能不是第一次显示，保留成对时钟模型的不确定度。报告分别保留完整绘制前→桌面、捕获→桌面和原生提交速率，DD 不同 marker 数除以完整请求 30 秒；不以提交速率或短 marker 跨度替代物理 FPS。

`method/verify-archive.py` 离线复算原始时间线与导入统计，核对实际分支、源码、二进制、像素路线、被动窗口检查与清理状态，再检查 SHA256。测量脚本包含当时私有路径，重用前须重新核对主机状态；配对私钥和配置明文不归档。

四轮结束后确认私有测量进程、任务及 49073 端口占用为 0，原 VDD 配置哈希一致。自有输出及嵌套 compositor 已退出，原监视器几何与根插件保持不变；Intel 遥测仍为同一 PID 的 High。生产 Windows 呈现器与捕获插件均未替换。
