# 已安装的 Windows → Linux 优化与双向模式控制

2026-09-09，额度剩余34%时安装。Windows反向程序已替换为规范构建 **E1543F07…**，默认 **帧率优先**；Linux → Windows 的既有默认 **延迟优先** 保持。Quickshell控制面板现有两个方向各自的两档按钮。

新版本采用异步透明度、R8不透明摘要、编码器输入就绪检查、单窗口自有纹理直接提交与重复画面跳过，并包含缩放恢复、关闭窗口元数据和复制期间尺寸变化的修复。完整39文件Windows构建及六项CTest通过，最终二进制的窗口生命周期和运行中三次切换均通过GPU验证。[构建及四轮完整链路结果](../root-performance-v2/README.md)。

帧率优先两轮为 **32.947／33.509个不同画面/秒**，绘制前至Linux桌面观察的时延估计上界中位 **80.156／78.406ms**，P95 **96.916／95.391ms**。仍未达到60ms，也不等于物理屏幕扫描测量。单帧模式在这台Intel机器上没有显示稳定优势；队列在每次提交前均为空，两档上限未成为这次工作负载的瓶颈。[模式定义](../../../reverse-performance.md)。

已安装程序仍使用原 `receive.json` 中的反向路径及四个坐标，配置字节未变。Linux两个源配置字节未变，现有输入服务保持active；主Linux桌面服务原本inactive，Windows主任务原本Ready，安装没有启动或重启它们。**新反向程序在下次开启穿透时使用**。安装路径上的真实脚本往返选择latency、frame-rate均读回成功，最终为frame-rate；这与此前隔离原生进程内的动态切换验证是不同检查。

Windows完整SHA256：`E1543F0754BAE0741955EF5FBD178262ED10AFE05E3845060E28AAC4121B93D0`。Linux实际安装与测量接收程序均为 `768f11a5fde4145349349cca3cc869981179981055b1eb25527981a2174488be`。显示矩形、缩放和旋转读回一致，未注入鼠标、键盘或焦点操作。

Windows及Linux原文件的备份目录记录于 [install-state.json](method/install-state.json)。首次入口超过Windows命令行长度限制，确认旧文件仍在；改为上传PS1后安装成功。失败入口记录保留在method/install-attempt1。最终程序、控件、配置、服务和显示状态见 [verified-installed.json](method/verified-installed.json)。QML静态检查通过，Quickshell日志有配置加载成功记录；未把该检查当作用户物理点击验收。基础shell.qml的supplementaryInfoVisible绑定循环警告也保留在原始日志，未修改其代码。

部署脚本是针对当时旧哈希与路径的一次性操作，不能当作通用升级命令重跑。日常模式切换使用已安装按钮或项目的 `tools/viewflow-reverse-performance.py`。
