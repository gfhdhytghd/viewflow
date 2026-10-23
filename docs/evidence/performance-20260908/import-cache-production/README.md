# 将验证过的 DMA-BUF 导入缓存接入待部署版本

2026-09-09。**根工作树 GPU encoder 已默认复用导入注册，新 sender 构建及默认开启路径的 4K 检查通过；尚未替换当前桌面服务使用的安装版本。** 这项选择依据重复约 1 ms 的编码节省、存储复用／完整 alpha 检查，以及两档捕获模式的完整链路对照，不代表 4K60、两帧内显示已经达成。

已集成的缓存实现与[当前条件下四轮缓存对照](../import-cache-hyperv-ddc/README.md)采用的实现相同，代码只把开关默认值改为开启。unset/empty 或 `VIEWFLOW_GPU_IMPORT_CACHE=1` 开启，`0` 关闭；其他非空值保持关闭语义。最多四条目，保留存储身份和 FD 引用，每帧仍等待自身 fence、map/unmap、完成 GPU 源读取。完整颜色、alpha、路由及故障恢复均保留。两种性能模式使用相同缓存实现，差异仍是捕获调度。

缓存前一批次采样编码总耗时中位为 6.758 / 6.904 ms，开启为 5.766 / 5.752 ms；局部耗时与最终显示延迟分别报告。随后同一候选的两档配置对照，延迟优先完整中位为 24.18 / 27.17 ms，固定节奏为 37.42 / 39.58 ms，帧率结果有交叉且存在长尾。[两档组合对照](../performance-mode-import-integration/README.md)。因此保留两档选择，而非承诺某档在所有应用上都更快。

## 默认路径验证

- 根工作树 `vf-media-peer` release 构建完成，SHA256 为 `81e605f895442fb2f28b7a62bbb6058feb79022f9eed75fa06bf91d6fff6c210`。
- 未设置 `VIEWFLOW_GPU_IMPORT_CACHE` 时，CTest 7 项全部通过；额外 3840×2400 GPU 集成测试验证完整 alpha、颜色／GOP、native fence、atlas 切换及测试注入过期后的恢复。
- [共享 blur 四轮实验](../shared-blur-brush/README.md)使用同一个新 sender，四轮 source 环境均删除缓存开关覆盖。四轮有效运行记录默认缓存开启、单存储持续命中；末次快照分别有 3,177 / 3,239 / 3,239 / 3,177 次命中，均只有 1 次 miss、1 个条目，无容量淘汰。日志最后快照之外不推算计数。全部画面 marker 有效。
- 原有 64 帧持久存储 oracle 验证相同数字 FD 的不同底层存储、命中时内容更新、容量淘汰及完整 alpha／软件解码颜色；其实现体与当前一致。这是此前执行的证据，本次未重跑该 oracle。[原 oracle 与范围](../dmabuf-import-cache/README.md)。

共享 blur 在其完整对照中没有稳定收益，保持关闭且未写入根 Windows 效果实现；它不构成本次 Linux 缓存集成的前提或默认依赖。

## 构建与安装状态

`method/prepared-state.json` 按实际 `viewflow-desktop.service` 读取 LoadState、ExecStart 与活动状态。服务已加载但当前 inactive，实际 peer 仍为 `/home/wilf/.local/lib/viewflow/desktop/vf-media-peer-main`，哈希 `de5b22c8…`；新构建文件尚未安装到该位置。新 sender 也已验证当前实际 source 配置可解析。当前运行捕获插件和桌面几何保持原值。

源码相对于 `import-cache-hyperv-ddc/source-tree` 的唯一代码差异为缓存默认选择，另更新 NVENC README 说明。`method/source-sha256.json` 保存对应 228 文件哈希，`source` 保存这两个改变后的文件；其他源文件由上述完整候选快照提供。构建、测试和完整运行身份分别保留，不能把已构建误报为已经部署。
