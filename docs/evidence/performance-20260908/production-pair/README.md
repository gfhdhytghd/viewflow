# 正式双端版本的 4K 两档模式资格测量

2026-09-09。正式源码构建的 Linux sender、Windows receiver 与原生呈现器已完成四轮完整链路测量。延迟优先的绘制前→桌面观测上界中位为 **25.02 / 32.87 ms**；帧率优先为 **47.98 / 42.98 ms**。帧率优先的桌面不同 marker 更新率约 59.3–59.43/s，延迟优先约 56.73–58.4/s。两档均保留完整画质与 sigma=12 背景模糊，均存在超过两帧的长尾，**4K60、两帧内首次显示尚未证明**。

| 轮次 | 原生提交/s | 完整 30 秒内不同 marker/s | 绘制前→DD 上界中位 / P95 / 最大 ms | 绘制→捕获中位 ms |
|---|---:|---:|---|---:|
| prodpair-v1-frame-a1 | 59.829 | 59.300 | 47.983 / 49.103 / 66.129 | 14.402 |
| prodpair-v1-latency-b1 | 59.261 | 56.733 | 25.015 / 26.238 / 124.323 | 0.462 |
| prodpair-v1-latency-b2 | 59.440 | 58.400 | 32.872 / 34.037 / 117.936 | 0.304 |
| prodpair-v1-frame-a2 | 59.705 | 59.433 | 42.975 / 44.301 / 109.215 | 5.375 |

此处采用完整请求 30 秒作为更新率分母。DD LastPresentTime 是包含所见 marker 的一次桌面更新，未证明第一次显示，也不是光子或真实输入延迟。保留成对时钟估计的不确定度；分段统计及完整时间线见 [comparison.json](comparison.json)。两档的唯一调度变量是实际 source config 的 `performance_mode`，记录核对真实捕获 API、stream ID 与 grid/commit 计数。四轮均无无效 marker。

## 正式源码与构建

Linux sender 为当前源码的 `81e605f8…`，默认启用 DMA-BUF 导入缓存，无环境变量覆盖；缓存每帧仍重新同步和读取内容。Windows receiver 为 `8784bd65…`，native 为 `6e32b93a…`，303 个源文件及远端编译输入逐项哈希一致。正式构建去除了仅存在于旧实验分支的直接输出试验入口，不启用共享 blur brush 或背景图像缓存。构建、源码、二进制及七个配套 FFmpeg DLL 身份保存在 [构建审计](method/build-audit.json)。Linux 缓存默认值的功能验证见 [生产缓存记录](../import-cache-production/README.md)。

34 项原生 CTest 全部通过。实际 3840×2400 输出上的四阶段背景 oracle 均通过：背景颜色变化、条纹模糊、patch 删除和重排；RGB 容差 2 内全部匹配，背景变化响应 80，模糊差异通道数 110592。hit-test 不接收鼠标，测试未注入输入，四阶段前台窗口均保持一致。原始 BGRA 和 oracle 日志归档于 method。

## 条件与实际安装范围

Linux 使用隔离嵌套 compositor 的 3840×2400 fixture、scale 2、3968×2432 atlas；Windows 观察器锁定唯一实际 3840×2400 输出。55 秒 source、30 秒异步 DD observer，完整 sigma=12，普通 surface-copy 路径。测试 runner 设置 `VIEWFLOW_WINDOWS_INPUT_SERVICE=1`，与实际主任务脚本一致；这不能证明真实键鼠或输入服务物理验收。亮度查询修复、Hyper-V 计时设置及 Intel 遥测进程优先级保持不变。测量期间没有并行编译或其他 GPU 测试。

该批次检验的是正式构建的两档模式，不能把它与旧实验二进制的跨批次波动当作单因素因果对照。旧实验的两档结果见 [前次缓存组合测量](../performance-mode-import-integration/README.md)。选择正式组合是为了交付完整、可重建的实现；并不声称所有轮次都快于每个历史候选。

实际 Linux 主服务启动参数指向 `~/.local/lib/viewflow/desktop/vf-media-peer-main`；Windows 主任务脚本指向 `C:\Users\wilf\Viewflow\desktop-test` 的 peer 和 native。本批次只构建并测试隔离路径，尚未替换这些安装文件。实际配置和启动脚本的旧哈希见 [安装前审计](method/windows-before.json)，配置的非凭据形状见 [配置范围](method/production-config-shape.json)。主机 Linux 物理输出是 6144×3456；本次 4K fixture 测量不证明整个 6K 主桌面的性能。部署原生呈现器时须一起处理七个已审计的 DLL。

169 帧双流 smoke 检查了持有一流时另一流继续前进、停止一流不损坏另一流、空组恢复及旧固定节奏入口。四轮结束后隔离任务、进程、49073 端口均为零，嵌套 compositor 已退出，自有输出移除；原根插件、显示器几何与 VDD 配置保持一致。

运行 `python3 method/verify-archive.py` 会离线解压复算四轮记录，核对真实模式、哈希、测试和清理状态，不启动窗口。私有配对材料不归档。
