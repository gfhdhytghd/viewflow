# RequestCommitAsync：保留完整毛玻璃的提交请求对照

2026-09-08。独立 Windows 探针与完整 Linux→Windows 链路分别测试普通 `Compositor.RequestCommitAsync()`。完整链路没有稳定收益，候选保持在隔离证据目录。

**结论：没有稳定收益，未接入生产。** 捕获→所见桌面上界中位数，关闭为 38.556 / 38.533 ms，开启为 38.375 / 39.036 ms；开启后的 P95 为 43.822 / 43.994 ms，未稳定优于关闭的 44.493 / 43.841 ms。原生提交仍约 57.8–58.1 次/秒，4K60、两帧内完整显示仍未验证。

| 完整链路轮次 | native commit/s | DD marker/s | 绘制→DD 上界中位 ms | P95 ms | 捕获→DD 上界中位 ms | P95 ms | 唯一捕获样本数 |
|---|---:|---:|---:|---:|---:|---:|---:|
| request-off-a1-v2 | 58.074 | 38.046 | 46.903 | 53.028 | 38.556 | 44.493 | 1135 |
| request-on-b1-v2 | 58.029 | 39.116 | 39.762 | 45.012 | 38.375 | 43.822 | 1153 |
| request-on-b2-v2 | 57.806 | 38.079 | 42.911 | 48.092 | 39.036 | 43.994 | 1136 |
| request-off-a2-v2 | 58.133 | 37.896 | 41.902 | 47.324 | 38.533 | 43.841 | 1131 |

提交→所见桌面中位数依次为 24.904 / 24.694 / 24.952 / 24.739 ms，没有稳定缩短。绘制→桌面的较大变化还包含采集前相位；不能归因于提交 API。完整绘制→桌面上界最大值依次为 134.261 / 142.599 / 145.055 / 146.863 ms，全部保留。B1 有 13 个 marker 对应重复捕获，仅在要求唯一捕获配对的阶段统计中排除，完整绘制→桌面统计仍包含它们。

两个开启轮最后快照分别验证 3,120 次请求，已完成 3,118 / 3,117，待完成 2 / 3，峰值在途 4 / 5；失败、跳过、同步等待均为 0。关闭轮请求数为 0。快照与帧提交日志逐条对应，不能把末尾未输出的请求推算成已验证数据。[逐轮完整统计与帧配对](integrated/comparison.json)。

## 方法与可解释范围

本候选保持原来的 `Compositor`，在视觉属性与表面绑定后请求异步提交。它不创建此前测试过的 `CompositorController`，不等待异步动作，不把请求完成、33 ms 或捕获相位变成会话准入条件。只查询已完成动作并读取结果；待处理动作最多 32 个，达到上限时跳过请求并继续原有隐式提交。API 失败同样保留原有提交路径。微软将此 API 描述为尝试启动一次异步提交周期，并没有承诺显示时限。[微软 API 文档](https://learn.microsoft.com/en-us/uwp/api/windows.ui.composition.compositor.requestcommitasync?view=winrt-26100)。

保留完整背景效果：普通 compositor、Gaussian sigma=12、BALANCED/HARD、两个绘图表面交替更新、当前前景作 alpha 遮罩，四个背景节点 opacity=1。没有采用静态 alpha 表面、背景静音、降分辨率或 SPEED 模糊。独立 probe 的构造器检查四个背景节点和 opacity 读回；它是 API 行为与显示端点探针，不是远程传输性能测量。

独立 probe 各运行 40 秒、2400 帧，正反顺序每 240 帧切换请求关/开，分析排除每个阶段前 30 帧。两轮总共发起 2400 个请求，无失败、无跳过，第一轮结束仍有 2 个异步动作待完成，第二轮全部完成；不把待完成动作算作已完成。请求调用本身中位 0.01156 / 0.01315 ms，P95 0.02160 / 0.02468 ms，最大 0.15566 / 0.30676 ms。没有同步等待。

| 独立 probe | 关：mutation→DD 中位 ms | 开：中位 ms | 关：P95 ms | 开：P95 ms | 关/开样本数 |
|---|---:|---:|---:|---:|---:|
| 正序 | 18.597 | 18.347 | 23.584 | 23.654 | 563 / 426 |
| 反序 | 15.942 | 14.833 | 33.136 | 33.169 | 441 / 548 |

独立 probe 中位改善约 0.25 / 1.11 ms，P95 基本不变。各阶段的帧率只在连续阶段内计算，不把不连续的开启时段拼接计算 FPS。[独立逐阶段数据](independent/comparison.json)。

完整链路沿用[完整毛玻璃复测](../full-glass-retest/README.md)的私有 mTLS 配置与 fixture：逻辑 1920×1200、DPR 2、GPU 画面 3840×2400、半透明 128 像素边缘、捕获 3848×2408、atlas 3968×2432、H.264。原有根 Hyprland capture 插件不变，没有加载采集相位跟随原型。每轮 source 55 秒、DD observer 30 秒；四轮共享一个自有 headless 输出，按关/开/开/关测试，之后移除该输出。每轮新建进程；采用相同的 V2 原生二进制，仅改变 `VIEWFLOW_ATLAS_REQUEST_COMMIT`。

Windows 为 Intel GPU、6144×3456@60 输出；Linux 为 NVIDIA GPU。观察器以 NOACTIVATE 定位自有 proxy；原生提交频率是应用提交速率，DD marker/s 是观察到的变化速率，二者均不是已验证的物理 FPS。DD LastPresentTime 是包含该 marker 的一次桌面更新时间，可能不是第一次显示，也不是面板光子时间。延迟上界保留跨端时钟不确定度，按唯一 marker/capture 身份配对，不相加不同总体的中位数。所有观测 producer 尺寸、时钟有效期、倒序和负区间由分析器检查。

## 统计修正、源码与复算

V1 四轮在退出时没有输出析构统计。启动标志读回有效，但不能据此确认实际 API 请求次数，因此仅保存为[缺少调用计数的初步观测](v1-missing-exit-counter/comparison.json)。V1 源码、脚本与日志独立冻结；不能用 V2 的调用计数补证 V1。

V2 每 120 次提交将累计请求数附加到现有缓冲诊断，在正常运行中写出。分析器逐个校验快照与对应原生提交数量、开启状态、started=completed+pending、失败/跳过/同步等待均为 0。计数报告仅覆盖最后一个成功写出的快照；末尾不足 120 次提交未计入，不能声称获得进程退出时的完整计数。两种模式使用相同快照逻辑。

`source-before/main.cpp` 是候选前的生产源码，`source-integrated` 是隔离完整链路 V2，`source` 是独立 Windows 探针。V2 上传目录全部 101 个文件与本地 SHA256 完全匹配；逐轮 state.json 校验运行的 native 与 runner 二进制身份。方法目录保存构建日志、SHA256 和实际端点路径；FFmpeg 头文件的 C4819 编码警告保留。首次独立构建中 AsyncStatus 命名冲突已用完整 WinRT 命名空间修正，失败日志也保留。

纯分析复算：将 `integrated/<label>` 的 `.log.gz` 解压到任意临时根的同名子目录，复制 state.json，再运行 `python3 method/analyze-integrated.py <临时根> request-off-a1-v2 request-on-b1-v2 request-on-b2-v2 request-off-a2-v2`。独立 probe 复算需将 `independent` 中日志解压后运行 `python3 method/analyze.py <临时目录> probe-request-ab probe-request-ba`。依赖已冻结在 method。运行测量的脚本含当时已验证主机及私有配置路径，不能直接复用旧 PID 或证书；证据包不含私钥或连接配置。

最终审计：四轮 source 按计划 exit=124；A1/B1/A2 的 receiver 随 peer 关闭 exit=1、watchdog=0。B2 的 source 结束后接收进程仍在，控制器 finally 停止自有任务并清理进程，其 runner 没有写出退出码或 watchdog 摘要，不将其记为已确认的正常退出。四轮 observer exit=0、invalid=0、readback abandoned=0，观察区间均完整。所有使用的时钟交换与映射检查通过。Windows 自有测试进程、任务及 49073 端口占用均为 0；自有输出已移除，原有 DP-4 / HEADLESS-13 的几何与插件保持不变，configerrors 为空。ESRV PID 10132 仍为 High；未修改其优先级。测试没有调用输入注入或焦点切换 API，焦点读回不代表整个测试期间用户焦点未变化。生产 main.cpp 与候选前副本逐字节相同。原始证据压缩归档，独立探针和四轮完整链路可从归档精确复算；全部文件由 SHA256 清单覆盖。
