# 40% 时已应用的正式双端组合

2026-09-09。额度剩余40%时已完成安装，默认 **延迟优先**，面板同时提供 **帧率优先**。Windows → Linux 的6K30／60ms优化已开始，另见 [反向基线](../../performance-20260909-windows-linux/baseline/README.md)。

当前采用默认DMA-BUF导入缓存、两档捕获调度，以及Viewflow呈现／解码线程的MMCSS Playback注册。两轮MMCSS开启、延迟优先的完整4K测量为59.40／59.07次桌面标记更新/秒，绘制前→桌面上界中位35.42／26.56ms、最大46.05／44.28ms；相比同批关闭组，更新率和长尾改善。中位有交叉，仍未证明4K60或两帧内首次显示。[完整开关对照](../mmcss-canonical/README.md)。

| 已安装组件 | SHA256 前缀 |
|---|---|
| Linux 主 peer | 81e605f8 |
| 公开命名空间捕获插件 | 22802c4c |
| Windows 主 peer | 8784bd65 |
| Windows 原生呈现器 | 133c6a7e |
| Windows 主启动脚本 | ada29f34 |

七个FFmpeg DLL与原安装版本相同。Windows主脚本只增加当前进程环境变量 `VIEWFLOW_MMCS_PLAYBACK=1`；Task Scheduler Priority仍为7，未调整其他进程或机器调度配置。MMCSS注册失败保留普通调度。Windows接收配置字节未变；Linux源配置仅增加 performance_mode=latency。真实渲染算法、画质、sigma12毛玻璃、显示几何、输入路由和恢复策略保持。

## 模式与运行状态

Quickshell控制面板已接入两个互斥按钮并记录Configuration Loaded。实际CLI往返选择 frame-rate、latency 均验证成功，最终保持latency；没有重启未运行的主服务。[模式往返记录](method/mode-roundtrip.json)。MMCSS完整对照只测了延迟优先；固定节奏入口和两档接线在 [正式组合测试](../production-pair/README.md) 中已验证，不将未测量的固定节奏＋MMCSS组合宣称为已达标。

安装后实际映射的捕获插件inode与目标文件一致，三项Lua捕获API均可用，Hyprland配置无错误。现有配对、Windows输入、macOS HID服务仍active。主Linux桌面服务原本inactive，Windows主任务原本Ready，安装没有主动启动它们；**新的主peer和呈现器会在下次开启窗口穿透时使用**。这与插件已实时加载、面板已加载是不同状态；没有宣称用户操作或物理显示验收已经完成。

## 替换与恢复记录

首次Windows替换因PowerShell把.NET字符串参数的null转换为空字符串而失败，读回确认所有安装文件仍为原版。已改为明确的 `[NullString]::Value`，并通过隔离临时文件的实际原子替换检查。第二次安装时插件重载触发Hyprland重读显示配置，动态HEADLESS-13被重置到1920×1080，几何检查触发文件回退；已立即恢复原3840×2400、位置3072×390。最终流程在加载插件后恢复既有动态虚拟输出，并等待连续稳定读回。物理DP-4保持6144×3456、scale2，未重新分配工作区或注入输入。

最终安装、哈希、模式与几何修正记录见 [installed.json](method/installed.json)；[实际插件映射](method/live-plugin-maps.json)、[最初失败快照](method/install-attempt1-state.json)、[几何变化及回退快照](method/install-attempt2-geometry.json)。主文件备份分别位于Linux用户数据目录及Windows用户Viewflow目录的 performance-backup-20260909。配置备份仅保留在用户本地，未将配对材料归档。

method内脚本针对这次固定路径和安装前哈希，初始stage.py及Check检查是历史部署材料；安装已经完成，不能无条件重跑。当前状态应以installed.json和新的现场读回为准。构建和原始测量依据分别保留在production-pair与mmcss-canonical目录。
