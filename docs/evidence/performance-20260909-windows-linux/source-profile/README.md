# 6K Windows源端基线：同步透明度读回

2026-09-09。独立副本，未替换当前安装的Windows反向程序。使用已有非主屏虚拟输出`[-6144,-780,0,2676]`，GPU绘制6144×3456被动窗口；`WS_EX_NOACTIVATE`及`SW_SHOWNOACTIVATE`，开始和结束前台窗口相同。源程序仅收录本次fixture PID。源端捕获、HEVC、alpha及VFRV封装保持原算法，增加分段计时。测试程序在30秒后关闭输入管道；源端和fixture均退出0，无watchdog、无残留进程。主任务仍Ready。

剔除输出开始后的5秒预热，输出293帧，**11.997FPS**。全程343条VFRV记录在Linux原GpuDecoder中解码、CUDA→GL导入并读取24位互补帧标记，343帧全部有效、无倒退、GL错误0、尺寸均6144×3456。稳态没有把重复画面算作新帧。

| 源端阶段 | 中位数 | P95 |
|---|---:|---:|
| 编码提交调用 | 2.998ms | 3.539ms |
| alpha同步读回 | 51.827ms | 68.527ms |
| alpha比较／编码 | 2.955ms | 5.263ms |
| 编码提交至取到输出 | 82.533ms | 100.723ms |
| VFRV封装及写本地文件 | 0.069ms | 0.180ms |
| 标记绘制前至对应输出写完 | 193.845ms | 243.358ms |

**以上不是完整链路结果**：Windows输出写本地文件，尚未经过QUIC及Linux Wayland实际呈现。最后一项由解码标记身份匹配fixture的QPC记录，包含绘制提交、DWM/WGC及源端工作；不是物理扫描时间。WGC报告的时间戳在261个回调中晚于回调内QPC读数，因此没有用其差值宣称捕获延迟。

下一步测试异步alpha读回，保留逐帧alpha／颜色对应。这里的固定不透明窗口仅是第一项负载；透明内容、变化的alpha及完整链路仍需验证。

`method/source-sha256.json`与`remote-source-sha256.json`记录Windows构建前上传的33文件快照。其中Linux文件当时未参与Windows编译；随后为离线解码增加record_probe及CMake目标，实际Linux输入单独记录于`method/linux-source-sha256.json`。Windows编译输入未修改。完整归档哈希见`sha256.json`，分析器可直接重算`summary.json`。

追加离线验证：`runs/decode-alpha.log`使用同一记录重新解码343帧，并确认传输alpha全为255；额外检查未参与Windows源端的计时。更新后的record_probe源码及构建日志一并归档。
