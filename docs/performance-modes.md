# 性能模式

Linux → Windows 的源配置支持 `performance_mode`：

| 配置值 | 选项 | 捕获策略 |
|---|---|---|
| `frame-rate` | 帧率优先（默认） | 按固定共同时间表捕获，保持设置的 `fps`。 |
| `latency` | 延迟优先 | 新内容提交后及时捕获；合并密集提交，并保留静态补采。 |

两种模式保留完整画质、透明度和毛玻璃，不改变显示几何、认证、输入路由或故障恢复。省略字段的既有配置继续使用 `frame-rate`。`latency` 需要支持 `window_stream_start_commit` 的 Viewflow 捕获插件，不适用于旧 HyprCapture 后端。

本机在剩余额度40%时应用默认导入缓存、捕获模式和Windows呈现／解码线程的MMCSS调度。最终延迟优先组合的两轮桌面更新率为59.40／59.07次/秒，绘制前→桌面上界中位35.42／26.56ms，最大46.05／44.28ms。仍未证明4K60或两帧内首次显示；固定节奏＋MMCSS组合尚无单独完整测量，选项名称不保证每次都获得更优结果。[最终调度对照](evidence/performance-20260908/mmcss-canonical/README.md)、[已应用状态](evidence/performance-20260908/production-deployment/README.md)。

性能模式通过配置文件选择，控制中心不提供模式按钮。本机配置文件为 `~/.config/viewflow/desktop-source.json`，在现有 JSON 对象中设置字段：

```json
"performance_mode": "latency"
```

改为 `"frame-rate"` 即选择帧率优先。保留文件中的其他字段。手动编辑后，下次启动桌面服务时生效；如需立即应用到正在运行的服务，执行 `systemctl --user restart viewflow-desktop.service`，连接会重建。本机当前配置为 `latency`。

也可以使用下列命令编辑同一个配置文件。切换工具从 systemd 的有效启动参数读取实际配置和 peer 路径，包括 drop-in 覆盖。它先验证捕获 API 和新配置，再原子保存；正在运行的桌面服务会重连，未运行的服务只保存下次启动设置。失败时恢复原配置，并尝试恢复原服务。

```sh
python3 tools/viewflow-performance.py status
python3 tools/viewflow-performance.py set frame-rate
python3 tools/viewflow-performance.py set latency
```

上述配置只改变正向窗口捕获。Windows → Linux 使用独立的[反向性能配置文件](reverse-performance.md)。

当前桌面的后台亮度重复查询已单独修复，保留面板打开与调整后的按需读取，消除每十秒一次 225–246 ms 的编码停顿；这项修复同时适用于两档捕获模式，未改变模式默认值。[对照及应用记录](evidence/performance-20260908/periodic-ddc-stall/README.md)。
