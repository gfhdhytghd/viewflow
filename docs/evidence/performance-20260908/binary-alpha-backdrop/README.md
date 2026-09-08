# 已撤回：二值 alpha 背景静音实验

2026-09-08。此目录保存历史诊断，不是当前产品配置。用户随后明确要求保留背景效果；后续研究遵守该要求，见[完整毛玻璃研究](../full-glass-kernel/README.md)。二值 alpha 静音及其产品代码已经撤回。

## 实验和结果

候选在确认为纯 0/255 alpha、整数 1:1 对齐时将保留的背景节点透明度设为 0；在缩放、非整数偏移和半透明情况下恢复为 1。独立图像对照包含初始 8 项与生产候选 12 项，参考/候选 RGB 最大差异均为 0。故意在不合格条件下静音的负对照产生差异，覆盖缩放、偏移及 alpha=1/128/254；动态恢复、无新帧 resize 与返回原比例也被检查。图像对照仅针对所列条件，不能证明任意显示环境都等价。[原生图像对照](pixel-oracle/)、[受测源码](source-tested/)。

真实远程链路按 A/B/B/A 运行四轮，A 禁用候选，B 启用。内容 3840×2400、捕获带边界为 3848×2408；Windows 为 Intel GPU 与 6144×3456@60 虚拟输出。每轮源端约 25 秒，桌面观察约 20 秒。原生提交率与最终观察到的标记变化率分别报告。

| 轮次 | 原生提交 /s | DD 标记变化 /s | fixture pre-draw→DD 上界中位 ms | P95 ms |
|---|---:|---:|---:|---:|
| A1 禁用候选 | 57.698 | 40.333 | 60.338 | 78.085 |
| B1 启用候选 | 57.775 | 34.095 | 48.833 | 69.132 |
| B2 启用候选 | 58.503 | 35.041 | 46.108 | 66.486 |
| A2 禁用候选 | 58.361 | 41.747 | 51.768 | 69.341 |

开启候选时标记变化率降低，没有证明 60 FPS 改善；显示上界中位数仍未进入两帧。源端绘制到捕获的启动相位也有变化，不能把上表所有差值归因于背景计算。DD LastPresentTime 是含该标记的桌面更新时间，可能不是该帧第一次显示，也不是光子端点；变化率同样受观察器漏观和 GPU 读回干扰，不能冒称物理显示帧率。[完整逐轮统计](stream-runs/comparison.json)包含时钟不确定度、配帧和分阶段数据；所有原始日志保留在 stream-runs。

测试使用同一候选 EXE `730262942727CDF4BBFD6CE768F4A8C5C6FF6FE23B3D0C59574CE8732A574326`，用进程环境开关控制候选。所有四轮捕获均为原 production capture-events 路径。CPU 分类与 frame binding 测试在 Linux 和原生 Windows 通过，不能替代显示验收。

## HostBackdrop 标志的历史补充对照

两轮仅用于诊断 HWND 标志是否解释隐式额外工作：背景节点均保留、透明度均为 0，每 240 个提交帧切换 HostBackdrop 标志，反序轮调换顺序。它们发生于用户要求保留完整背景之前，**不是完整毛玻璃测试，也不会继续作为优化路线**。

标志开/关的 mutation→DD 中位：正序 16.313/16.603 ms，反序 22.582/22.426 ms，没有稳定收益。两轮原生探针与观察器均 exit=0。原始时序、分段统计、源码和进程状态见 [hostflag-probe](hostflag-probe/comparison.json)。不同轮的进程启动相位和背景实际状态必须保留，不能和完整效果组拼成同一组结果。

## 撤回与状态

生产 `main.cpp`、`sparse_opaque.h`、相关 CPU 测试与 frame binding 文件、CMake 已恢复至候选引入前的内容，新建的产品候选图像测试源也从活动目录移除。工作区其他已有优化保留。[原恢复哈希](method/binary-backdrop-production-restored.json)。重启之后的[只读复核](method/post-reboot-restoration-audit.json)重新确认 Linux 与 Windows 隔离副本六项文件逐一匹配恢复哈希，隔离目录进程数和 ViewflowPerf 任务数均为 0。

历史各轮使用专属非激活窗口，没有注入输入或切换用户焦点。测试前注册到期恢复任务，再临时调整已校验身份的 ESRV 进程/线程；finally 恢复原 High/TimeCritical 并移除恢复任务。四轮结束、临时 Linux 输出移除、规则恢复以及 Windows 任务清理见 [binary-backdrop-state](method/binary-backdrop-state.json)、[owned-output-state](method/owned-output-binary-backdrop-state.json)及 [flag-state](hostflag-probe/composition-flag-state.json)。这些是历史状态证明；不能在机器重启后照搬旧 PID。

Linux 后来重启，临时目录中的辅助文件消失。此目录保存重启前已经复制的源码、日志、图像、分析脚本及状态；补充的恢复复核是重启后的独立记录。不得把未保留下来的最后一次综合审计输出说成仍然存在。

`source-tested` 是已拒绝实验源码快照，仅用于复核。脚本里的主机、临时目录与具体进程身份均是本次环境，不适合不加检查地直接运行。目录内 [sha256.json](sha256.json)记录归档文件，不包含自身。
