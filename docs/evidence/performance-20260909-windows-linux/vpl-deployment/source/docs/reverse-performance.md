# Windows → Linux 性能模式

反向源使用硬件 HEVC 编码、异步透明度读取和 GPU 不透明摘要。单个窗口完整覆盖图集时，直接提交程序自有的源纹理，省去一次图集清空和复制。捕获回调仍把借用的 WGC 表面复制到自有纹理，借用表面不会跨回调保留。图像或窗口元数据未变化时跳过重复提交，每秒刷新一次静止场景；关闭、移动、标题和几何确认仍会触发更新。

Intel 显卡的 HEVC 路径优先使用系统已有的 VPL 运行库：颜色转换直接写入程序持有的 NV12 输入，编码完成且驱动释放后才复用。6K 使用两列 HEVC 分块。VPL 初始化不可用时自动回退 Media Foundation；其他显卡及 H.264 保留 Media Foundation 路径。构建使用仓库附带的 MIT 许可 API 头文件，无需安装 VPL SDK。

两种模式保留相同分辨率、码率、颜色编码和精确透明度：

| 模式 | 待完成帧上限 | 调度目的 |
|---|---:|---|
| `frame-rate`（默认） | 4 | 允许颜色编码与透明度读取重叠进行 |
| `latency` | 1 | 限制同时在途的画面，完成后再选取当前源纹理 |

上限只约束新提交，已在途的工作会正常完成。模式切换不重启连接，也不会按画面年龄断开窗口。Intel 6K 的 Media Foundation 对照中，两种上限的每次提交前队列都为空；VPL 当前也仅允许一个颜色任务在途。因此两种模式的上限不保证在这台设备上产生不同的性能。完整结果与其他候选见[测量记录](evidence/performance-20260909-windows-linux/README.md)。

程序默认读取自身可执行文件目录中的 `reverse-performance-mode` 文本文件，内容为 `frame-rate` 或 `latency`。它每 250ms 检查一次；文件缺失或无效时，运行中的程序保留上次模式。没有设置文件的新进程使用默认模式。

现有四个捕获坐标参数保持可用。可以显式选择一次启动的模式，或指定另一个可动态更新的设置文件：

```powershell
viewflow_windows_reverse.exe -6144 -780 0 2676 --performance-mode latency
viewflow_windows_reverse.exe -6144 -780 0 2676 --mode-file C:\Viewflow\reverse-mode
viewflow_windows_reverse.exe --performance-status
```

显式 `--performance-mode` 且未指定 `--mode-file` 时，不读取默认设置文件。`--performance-status` 在创建图形设备、打开桌面或开始捕获前退出，输出配置模式；它不声称另一个正在运行的进程已经应用该设置。

Linux 控制器使用已有的 SSH 登录通道原子替换 Windows 设置文件。将下面的连接信息写入 `~/.config/viewflow/reverse-performance.json`，路径指向实际部署的反向程序；配置中不存储登录密码：

```json
{
  "ssh_host": "user@windows-host",
  "native": "C:\\Viewflow\\viewflow_windows_reverse.exe"
}
```

```sh
python3 tools/viewflow-reverse-performance.py status
python3 tools/viewflow-reverse-performance.py set frame-rate
python3 tools/viewflow-reverse-performance.py set latency
```

Quickshell 的 `ViewflowPerformanceControl.qml` 分别显示两个方向的选择器，公共组件为 `ViewflowPerformanceSelector.qml`。脚本放在同一配置目录的 `scripts/` 中。设置反向模式仅更新 Windows 文件，不重启 Linux → Windows 服务。

诊断时可设置 `VIEWFLOW_REVERSE_DIAGNOSTICS=1` 开启逐帧日志；只有显式开启诊断时，`VIEWFLOW_PROFILE_SOURCE_PID` 才会把捕获范围缩小到指定测试进程。正常运行无需这些变量。透明度摘要在 GPU 不支持时回退到完整异步读取。

编码器对照可设置 `VIEWFLOW_REVERSE_ENCODER=mft` 或 `vpl`；不设置或设为 `auto` 使用默认选择。强制 `vpl` 的初始化失败会直接报告，便于诊断；自动选择才执行 Media Foundation 回退。`encoder_vpl` 日志记录运行库实际采用的 API 版本、尺寸、分块、码率和队列参数，`encoder_backend` 记录最终选择。

Windows 构建的 CTest 覆盖协议、几何同步、WGC 契约、窗口元数据变化与模式解析。`viewflow_reverse_alpha_async_probe.exe` 需要可用的 D3D 硬件设备，显式验证队列复用、全部透明度字节值、非整齐尺寸边缘及 6K 单像素非不透明情况；真实输入验收仍由用户操作。
