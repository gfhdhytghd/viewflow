# 正式组合的 MMCSS 线程调度对照

2026-09-09。四轮全部使用延迟优先捕获及默认导入缓存。仅打开 Viewflow 呈现／解码线程的 MMCSS Playback 注册后，桌面不同标记更新率为 **59.4 / 59.07 次/秒**，完整延迟上界最大 **46.05 / 44.28 ms**；关闭组分别为 57.33 / 58.93 次/秒、96.66 / 145.68 ms。中位有交叉，第一开启组仍为 35.42 ms，**4K60、两帧内首次显示仍未证明**。这项结果支持在 40% 收敛时采用应用自身的多媒体调度；不调整第三方进程或网卡。

| 轮次 | 原生提交/s | 不同 marker / 完整30秒 | 绘制前→桌面上界中位 / P95 / 最大 ms |
|---|---:|---:|---|
| mmcss-v1-off-a1 | 59.536 | 57.333 | 29.106 / 30.449 / 96.662 |
| mmcss-v1-on-b1 | 59.998 | 59.400 | 35.419 / 36.573 / 46.045 |
| mmcss-v1-on-b2 | 59.927 | 59.067 | 26.560 / 27.902 / 44.279 |
| mmcss-v1-off-a2 | 59.795 | 58.933 | 28.339 / 29.559 / 145.681 |

同一 Linux peer `81e605f8…`、固定 capture commit60、同一 Windows receiver `8784bd65…`，同一 MMCSS 候选 native `133c6a7e…` 与 runner `9e97417f…`。唯一控制为 runner 的 `VIEWFLOW_MMCS_PLAYBACK=0/1/1/0`。所有窗口均被动、不激活、鼠标穿透；源 3840×2400、scale2、atlas3968×2432，Windows 唯一实际4K输出，保持完整 sigma12 和普通 surface-copy 路径。源55秒、桌面观察30秒，原生计数不代替物理FPS，DD时间不是首次显示或光子时间。所有标记有效，导入缓存开启，原始长尾保留。

## 作用范围及读回

实际主任务 ViewflowMain-Active 与私有测试任务的 Task Scheduler Priority 均为7。按照 [Microsoft 的任务优先级映射](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-priority)，这是 BelowNormal；实际测试进程也读回 BelowNormal。开启组的两个注册线程均成功，优先级读回19；关闭组未注册。启动时线程快照与记录的两个TID逐项对应。该发现没有触发未测量的正式任务 Priority 修改。

采用 [AvSetMmThreadCharacteristicsW](https://learn.microsoft.com/en-us/windows/win32/api/avrt/nf-avrt-avsetmmthreadcharacteristicsw) 注册 Playback，并以 [AvSetMmThreadPriority](https://learn.microsoft.com/en-us/windows/win32/api/avrt/nf-avrt-avsetmmthreadpriority) 请求同类任务的 High 相对优先级。任务索引初始为0；API失败时继续普通调度，不关闭流。RAII作用域定义了同线程的 AvRevert 调用，但本次网络结束后 Rust 原生子进程清理由 kill_on_drop 终止，**没有观察到完整作用域析构或成功的 AvRevert 日志**。归档只证明注册成功及最终进程已退出，不把进程终止冒充显式恢复调用测试。

MMCSS服务原本Running/Auto，Playback配置为Medium、Priority3；前后配置与网卡高级属性完全一致。没有修改注册表、网卡、QEMU或第三方线程优先级。读取服务配置及任务属性时的少量只读诊断并非持续调度跟踪；测量期间没有编译或其他GPU测试。

## 源码与功能边界

304个源文件与远端编译输入逐项哈希一致。相较已完成34项CTest和四阶段背景像素验证的 [正式组合](../production-pair/README.md)，仅新增 `mmcss_scope.h`，在主呈现线程和MTA解码线程各加入一个作用域。绘图、解码、透明度、背景模糊和输入算法源码保持一致；没有宣称本次重新运行了那34项测试或像素oracle。完整4K链路、标记校验及169帧双流smoke均通过。

结束后私有任务、进程、端口均清空，嵌套输出已移除，原几何、根插件和VDD配置保持一致。`method/verify-archive.py` 离线复算四轮，核验两线程实际注册、线程快照、终止和配置前后状态、源码及文件哈希。候选采用和部署记录见 [应用状态](../production-deployment/README.md)。
