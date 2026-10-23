# 测试窗口鼠标穿透与背景模糊验证

用户报告 Windows 棋盘测试窗口看起来只有半透明，并要求测试不要抢走鼠标。已暂停原来的全屏性能对照，修复被动测试窗口的输入处理，并使用有明确条纹的自有背景验证模糊。

## 鼠标处理

原来的 Windows 测试代理使用 `WS_EX_NOACTIVATE`，仍可能挡住鼠标命中。新增显式诊断开关 `VIEWFLOW_ATLAS_DIAGNOSTIC_MOUSE_PASSTHROUGH=1`，在首次显示前设置 layered、transparent、no-activate 样式和恒定 alpha=255。普通交互代理行为不变。[Windows layered window 输入语义](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features#layered-windows)。

本次小窗口 oracle 始终使用上述样式，4 个窗口中心的只读 `WindowFromPoint` 查询均未命中测试窗口，四阶段前台窗口保持不变，未注入鼠标或键盘输入。[运行日志](method/host-backdrop-result.log)。完整流代理的新增开关已经编译，但本轮没有重新运行全屏网络流；不能将小窗口结果称为完整流验收。

Linux fixture 新增 `VIEWFLOW_FIXTURE_PASSIVE=1`，提交空的 Wayland surface input region。实际运行 276 帧，协议日志确认空 region；临时 4K 输出与原有屏幕在两个坐标方向均隔开至少 32768 逻辑像素。fixture 没有成为所采样的前台窗口；用户前台窗口在运行期间有变化，故不宣称 Linux 焦点始终相同。结束后删除自有输出，原显示器几何和插件列表保持一致，无配置错误。[状态](method/passive-fixture-state.json)、[协议日志](method/passive-fixture.log)。

## 模糊证据

以下为实际 3840×2400 HDMI 桌面上读取的三个 256×256 面板，拼接时仅去掉间隙：左为 Gaussian sigma=12 参考，中为当前 `stage_sparse_visuals` 渲染路径，右为仅半透明控制。三者使用相同条纹背景、半透明黑色前景及不透明标记。

![左：模糊参考；中：当前稀疏渲染器；右：仅半透明](method/host-blur-panels.png)

完整面板 RGB 比较中，没有通道差异超过 2/255；内侧 192×192 区域有 110592 个 RGB 通道与仅半透明控制相差超过 5/255。更换背景颜色后响应幅度为 80，重排后仍与参考一致。这证实该渲染路径在本次局部测试确实模糊后方 Windows 背景。棋盘自身是前景内容，本来应保持清晰；此前大窗口没有提供同样清楚的后方条纹对照，不能仅凭前景棋盘判断背景模糊，也不能用本轮反推此前每个网络帧均已正确模糊。

原生启动日志现会打印实际 sigma 与 host-blur/alpha-only 模式，供后续完整链路核对。这里没有测量性能；鼠标穿透样式可能改变 DWM 路径，后续各组应统一使用新设置重新比较。4K60、两帧内显示目标仍未证明。

## 构建、身份与复算

MSVC Release 原生预览和 oracle 构建成功，109 个远端源文件回读均匹配保存源树。Linux 被动 fixture 的实际运行版本也已构建。[构建日志](method/integrated-build.log)、[远端身份与清理检查](method/remote-audit.json)。Windows 测试进程、任务及端口均已清理，VDD 配置恢复原哈希，原 ESRV 进程和优先级保留。

`python method/verify-archive.py` 在本地复算保存像素、校验输入路由记录和哈希，不启动窗口。`method/run-oracle.py` 和 `method/verify-passive-fixture.py` 是本轮现场测试脚本；源构建在 `method/build.py`。完整背景开销对照只完成三组，单独保存于[暂停的实验](../background-cache-ablation/README.md)。
