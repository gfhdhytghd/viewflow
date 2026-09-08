# 完整毛玻璃：重启后的 4K 远程链路复测

2026-09-08。两轮捕获到所见桌面更新的延迟上界中位数为 **38.98 / 38.61 ms**，原生提交约 **58.03 / 58.58 次/秒**。仍未验证 4K60、两帧内完整显示。没有据此接入新的产品优化，也没有恢复已撤回的背景静音或独立 alpha 遮罩候选。

| 轮次 | native commit/s | DD marker/s | 绘制→捕获中位 ms（唯一配对） | 绘制→所见桌面上界中位 ms | P95 ms | 捕获→所见桌面上界中位 ms | P95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| full-glass-04 | 58.034 | 34.766 | 0.802 | 41.485 | 59.700 | 38.980 | 43.469 |
| full-glass-06 | 58.581 | 37.505 | 14.790 | 53.460 | 58.351 | 38.614 | 43.497 |

完整绘制→桌面统计分别包含 1,036 / 1,118 个 marker；要求唯一 capture 身份的阶段配对为 782 / 1,118 个。第一轮 254 个 marker 被源端重复捕获，保留完整绘制→桌面统计，但不猜测它对应哪一次捕获。不能相减独立总体中位数估计阶段耗时。第一轮完整上界最大 139.931 ms，第二轮 76.282 ms，未删除长尾。[逐轮完整统计和配对](comparison.json)。

DD LastPresentTime 是包含该 marker 的桌面更新时间，可能不是其第一次显示，也不是面板光子时间。DD marker/s 受漏观与读回开销影响，不是已经验证的物理显示帧率；native commit/s 也只是应用提交频率。上界保留双端时钟估计不确定度，不把未知首次显示误差当成已经校准。各阶段独立中位数不能相加重建总延迟。

## 方法与环境

使用新建的独立测试配置、正常 mTLS 和私有证书，不修改原来的隔离配置。Linux 是当前根 Hyprland 0.56.2 的独立 headless 输出，3840×2400@60、scale 2；GPU fixture 逻辑 1920×1200，带捕获边界 3848×2408，atlas 3968×2432，H.264。所有观测 marker 对应的 producer 日志均验证为 3840×2400；启动时的一次临时 DPR 转换不属于观测样本。

fixture 仍绘制全画面运动棋盘、渐变和红线，并用 64 格校验 marker 标识帧。独立副本申请 8-bit alpha；shader 对 128 物理像素边缘输出预乘 alpha=128/255，中心和 marker 为 255。未修改原来的 fixture 源码。这是受测图案定义，不声称完成用户目视验收。[准确源码](method/fixture/main.cpp)。

Windows 为 Intel GPU、6144×3456@60 虚拟输出，观察器只移动自有 proxy 到内容 1:1 对齐的位置，使用 NOACTIVATE。接收端采用 `native-trace-controls-build` 的 `DF6EB3...24A6F2B`，保留默认 sigma=12 的完整毛玻璃路径；普通 Rust receiver 为 `A39CB1...B3C30A`，DD observer 为 `D57C73...41AAEA`。完整二进制 SHA256、PID、进程路径和前后状态均在逐轮 state.json 中。用户及机器环境中未设置 `VIEWFLOW_ATLAS_BLUR_SIGMA`。这不是与重启前相同环境的 A/B，不将跨轮变化归因于某一次重启或某项优化。

每轮源端计划运行 55 秒，异步 DD observer 30 秒、timer1、3-slot ring。保持 capture-events、帧身份、QPC、clock exchanges 和 source/wire timings；关闭 native GPU queries、socket tracing 和 GPU encode 细分日志，不运行 ETW/WPR。源端按时结束 exit=124，receiver 随 peer 关闭 exit=1、watchdog=0；两轮 observer exit=0、invalid=0、pending_peak=2、abandoned=0。全部原始时钟交换复算有效，使用的映射有效期覆盖配对桌面端点，未发现逆序 marker 或负的 capture 上界。

未修改 ESRV 优先级或服务状态。两轮前后 PID 10132 均为 High，这是端点读回，不是连续优先级监测。测试工具不调用输入注入或焦点切换 API；用户活动中的焦点读回并非全程相同，不能声称整个测试期间焦点从未变化。最终测试进程、测试端口占用均为 0，私有任务和自有输出已移除，原有输出与插件保留，configerrors 为空。

## 分阶段发现

| 阶段（host wall time） | 第一轮中位 ms | 第二轮中位 ms |
|---|---:|---:|
| 捕获→编码开始 | 0.250 | 0.313 |
| 编码（含等待） | 6.824 | 6.814 |
| 编码完成→pipe admission | 2.519 | 2.536 |
| pipe admission→decoded | 1.303 | 1.285 |
| decoded→proxy ready | 0.482 | 0.480 |
| committed→所见桌面 | 24.871 | 24.650 |

后段包含队列、GPU、DWM 和观察端点，不能命名为 DWM CPU 时间。捕获后的统计接近，而绘制→捕获相位显著不同。下一步可研究如何稳定跟随内容提交，并继续处理 Windows 提交后的等待；此前[提交触发原型](../capture-commit-cadence/README.md)未形成稳定总延迟收益，不能未经新对照直接采用。

## 测试工具修正与复算

`setup-attempts` 保留四次未进入远程性能采集的启动失败：01 在 monitor 模式异步生效前断言，02 的 GLSL ES 非常量 `const` 初始化错误，03 的全局焦点相等检查失败（读回空窗口），05 发现 fixture 意外成为活动窗口而退出。随后增加模式等待、修正 shader、Qt WindowDoesNotAcceptFocus 以及仅匹配 fixture 的 no_focus 规则。04/06 的场景和 endpoint 二进制相同；06 增加 compositor no_focus 规则，不能把它说成测试脚本逐字节完全相同。没有输入注入来恢复焦点，失败均执行自有资源清理。

`method/run-full-glass.py` 是最终驱动；状态和错误行保留各次执行差异。控制脚本中的主机、临时路径只适用于已验证的当时环境，不能直接照搬 PID 或证书。私钥、CA 和配置不进入证据目录。方法和日志采用 SHA256 清单，二进制仅记录身份。

纯分析复算：将每个 `runs/<label>` 的 `.log.gz` 解压到任意临时根下的同名子目录，并复制该目录的 state.json。执行 `python3 method/analyze-full-glass.py <临时根> full-glass-04 full-glass-06`。分析器优先使用 method 内冻结依赖；不需访问 Windows 或运行桌面输入。
