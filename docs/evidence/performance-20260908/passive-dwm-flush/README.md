# 被动 4K 完整链路与后台 DwmFlush 对照

四轮 off/on/on/off 已完成。**后台 DwmFlush 未表现出稳定的延迟收益，实验保持隔离，不接入产品默认路径。** 实际 4K60、两帧内首次显示仍未证明。本轮同时验证完整网络流的测试代理能够穿透鼠标。

## 完整流与鼠标处理

每组相同 Linux 源、被动 fixture、Rust receiver、原生候选和只读观察器，源持续 55 秒，桌面观察 30 秒。实际 Windows 输出为 HDMI 3840×2400@60；源内容 3840×2400、捕获 3848×2408、atlas 3968×2432。每组要求唯一匹配的 4K 输出，未回退到 6K。

Windows 由启动器显式设置 `VIEWFLOW_ATLAS_DIAGNOSTIC_MOUSE_PASSTHROUGH=1`、`VIEWFLOW_ATLAS_BLUR_SIGMA=12`、背景缓存关闭。四组启动日志均确认 `sigma=12 mode=host-blur` 与鼠标穿透模式；观察器在 1:1 放置后核对 layered/transparent/no-activate 样式，中心和四角共五次只读命中查询均未命中代理。没有输入注入，没有通过改变焦点验证。这将此前小窗口的鼠标验证延伸到完整流；sigma 日志证明所选渲染模式，不能单凭日志证明每个完整网络帧的模糊像素。先前同一渲染实现的[条纹对照](../passive-blur-validation/README.md)单独保留。

Linux 使用 `VIEWFLOW_FIXTURE_PASSIVE=1`，实际二进制与此前空 Wayland input region 测试相同。临时输出与所有原输出在两个坐标方向均隔开至少 32768 逻辑像素。四组 fixture 持续动画，采样时未成为前台窗口；原有屏幕几何和插件列表保持一致，临时输出已删除。

## 候选行为

候选只在保存的源树中新增 `AsyncDwmFlush`，设置 `VIEWFLOW_ATLAS_ASYNC_DWM_FLUSH=1` 时启动一个工作线程。原生完成现有 visual mutation 和绑定后，通知工作线程；工作线程调用 `DwmFlush`。工作线程忙时仅保留最新请求，不累积请求队列。presenter 不等待 DWM 调用结束，不改变接收、解码、输入处理或超时规则。调用返回 HRESULT 被记录，测量中已保存的调用全部成功。

[Microsoft 文档](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmflush)说明该调用等待应用已排队的 DirectX 更新，并不刷新整个会话。本实验中主线程可以继续更新，WinRT 场景还存在隐式批提交，因此请求所携带的 frame id 只是通知关联；没有把返回时刻作为该帧首次显示的证据。`commit_to_api_start_ms`、`api_wait_ms`、`commit_to_api_return_ms` 是调用时序。receipt commit 时钟在已有 trace 时钟前单独采样，复算检查两者与 API 开始的顺序，不把两个采样强行当作同一个时间值。

退出时没有收集到析构汇总计数：原生子进程由 receiver 的既有关闭路径收尾，保存日志中没有 `atlas-dwm-flush-summary`。因此汇总、合并和最后在途请求的总数标为缺失，不推算为零。两组开启分别保存了 2583、2598 条完整 API 调用记录，足以确认实验路径实际执行；这些记录不构成最终关闭计数完整性的证明。

## 四轮结果

| 轮次 | 原生提交/秒 | 不同 marker/完整 30 秒 | marker 跨度覆盖 | 捕获→所见桌面上界中位 / P95 (ms) | mutation→所见桌面中位 (ms) |
|---|---:|---:|---:|---:|---:|
| passivedwm-v1-off-a1 | 58.06 | 46.97 | 99.457% | 47.01 / 53.97 | 32.67 |
| passivedwm-v1-on-b1 | 57.39 | 50.87 | 99.353% | 49.04 / 55.89 | 34.65 |
| passivedwm-v1-on-b2 | 57.25 | 50.57 | 99.312% | 50.60 / 57.20 | 35.85 |
| passivedwm-v1-off-a2 | 57.57 | 50.37 | 99.324% | 51.35 / 58.72 | 36.68 |

两组开启的 API 等待中位分别约 17.22、17.30 ms，P95 约 33.42、32.92 ms。开启组的提交至桌面等待仍未改善；关闭组本身也存在时间变化，不能把这四组解释为精确的固定增减成本。源绘制至捕获的相位随组变化，已分别记录，未通过相加独立中位数拼接端到端延迟。

Desktop Duplication 会漏观中间帧；不同 marker 数除以完整 30 秒，不能命名为真实显示 FPS。`LastPresentTime` 是所见桌面更新时间，既不保证 marker 的首次呈现，也不是光子时间；延迟上界包含时钟不确定度，仍受该结束点限制。API 返回至所见桌面的差值有正有负，不据此改写首次呈现时间。

## 构建、清理与复算

MSVC Release 原生预览、鼠标穿透观察器和启动器编译成功。110 个远端源文件回读匹配保存源树，四轮运行时的源端、fixture 和 Windows 二进制哈希一致。主仓库的默认程序未替换；本轮候选只在隔离目录运行。

四轮源按计划退出，观察任务结果为 0，启动器看门狗未触发；自身进程、任务和 49073 端口均已清理。VDD 配置哈希保留原值，原 ESRV 进程及优先级未变。[最终检查](method/final-state.json)、[源与二进制身份](method/remote-audit.json)、[控制器状态](method/control-state.json)。

[逐轮结果](comparison.json)和 `runs/` 保留原始压缩日志、状态和逐帧关联；`source/` 保存候选，`method/` 保存构建、被动启动、分析与归档代码。`python method/verify-archive.py` 离线重算全部四轮与哈希，不启动窗口。此实验已完成对候选的取舍，整体 4K60、两帧内目标仍需继续工作。
