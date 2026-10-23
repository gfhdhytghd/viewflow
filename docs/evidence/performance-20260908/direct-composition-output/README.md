# 解码器直接绘制 Windows 合成表面

候选在解码工作线程把 NV12 与独立 R8 alpha 直接绘制到 `CompositionDrawingSurface` 的 `BeginDraw` 纹理。省去常规 BGRA 中间输出与 UI 线程的整张 GPU 拷贝。仅隔离原型的 `VIEWFLOW_ATLAS_DIRECT_OUTPUT=1` 启用；产品默认路径未改变。四轮对照已完成，未表现出稳定的桌面延迟收益，因此保留隔离原型，不接入产品默认路径；4K60、两帧内首次显示仍未证明。

## 实现与所有权

候选限于 sparse atlas。工作线程持有完成回调及表面引用；UI 仅交出已经退下、未绑定的备用表面，当前显示表面维持原绑定。使用真实 `BeginDraw` 偏移设置 viewport，保留原有色彩转换和 alpha shader。结束绘制前解绑 SRV/RTV 并释放临时绘制接口，随后 `EndDraw` 与提交 GPU 命令；传给 UI 的是表面对象，不是已经结束使用期的绘制纹理。准备失败、绘制区域无效或结束绘制失败会回退到同帧的原 BGRA 路径。没有新增延迟门槛或断流条件。

与 `passive-blur-validation/source` 的差异列在 [change-ledger.json](method/change-ledger.json)。构建命名冲突的两次失败日志保留；修正后原生预览与测试程序均通过 MSVC Release 构建。111 个远端源文件与保存树哈希一致。

## 4K 像素与恢复验证

实际 Windows GPU 解码同一个 3840×2400 H.264 I 帧，为七组生成不同空间变化的独立 R8 alpha。每组先保存常规 BGRA 输出，再比较候选的全部 9,216,000 个像素。真实合成表面的读回在 `BeginDraw` 仍有效时完成；该同步读回仅出现在像素测试中，不在性能候选中。

七组覆盖新表面、退下表面复用、非零偏移及未绘制边缘、准备失败、无效区域、结束失败、失败后恢复。七组 RGB 最大差值均为 0，alpha 不匹配为 0，偏移测试的外围填充值不变。三组故障正确返回常规 BGRA 输出，其后恢复直接输出。该测试不创建 HWND，前台窗口前后相同，没有输入注入。[原始像素结果](method/direct-output-result.log)、[任务及二进制身份](method/state.json)。

像素测试验证解码输出和 alpha，不构成完整网络流每个毛玻璃像素的视觉证明；完整流的模糊模式保持既有 sigma=12，背景效果实现未修改。

## 完整被动 4K 对照

同一二进制 off/on/on/off，source 各 55 秒，Desktop Duplication 各观察完整 30 秒。实际输出唯一匹配 HDMI 3840×2400@60，源为 3840×2400、atlas 为 3968×2432。开启组所有已记录的完成帧都携带直接绘制表面，没有回退；关闭组没有直接表面。两组开启分别完成 3092、3142 帧。四组均保持 sigma=12 host-blur、背景缓存关闭、鼠标穿透和 no-activate；观察器中心及四角五次只读命中均未命中测试代理。Linux 被动 fixture 不接收输入，临时输出在两个方向距原屏幕至少 32768 逻辑像素。全部自身进程、任务与端口已清理，原显示器几何、插件列表及 VDD 配置保持不变。

| 轮次 | 原生提交/秒 | 不同 marker/完整 30 秒 | 捕获→所见桌面上界中位 / P95 (ms) | decoded→proxy-ready 中位 (ms) |
|---|---:|---:|---:|---:|
| directoutput-v1-off-a1 | 57.43 | 46.37 | 49.33 / 56.94 | 0.517 |
| directoutput-v1-on-b1 | 57.13 | 48.80 | 48.63 / 56.24 | 0.141 |
| directoutput-v1-on-b2 | 57.99 | 47.77 | 50.05 / 57.59 | 0.142 |
| directoutput-v1-off-a2 | 58.27 | 48.67 | 52.65 / 60.05 | 0.495 |

直接绘制减少了中间资源准备与 UI 阶段工作，开启组资源准备中位约 0.21 ms，decoded→proxy-ready 约 0.14 ms。但绘制表面准备和 EndDraw 已移到工作线程，不能把单个阶段的下降全部计为端到端节省；解码阶段相应包含了这部分工作。`surface copy host` 是旧的阶段名称，直接路径中只包含表面/brush 交接，不能把它当作仍有 GPU 拷贝或 GPU 耗时的证据。最终捕获到所见桌面的上界没有稳定改善。

Desktop Duplication 可能漏掉中间帧；不同 marker 数/30 秒是观测率，不能称作真实显示 FPS。所见桌面时间不保证是该 marker 首次呈现，也不是光子时间。时钟交换、有效期与逐帧身份均离线核对，不能用独立阶段的中位数相加代替端到端测量。

[逐轮数据](comparison.json)、[完整源与二进制审计](method/remote-audit.json)、[最终状态](method/final-state.json)均已归档。`python method/verify-archive.py` 从压缩原始日志重算四轮，不创建窗口。未采用这一候选不改变此前默认实现，也不证明虚拟机计时补丁的效果。
