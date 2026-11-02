# Viewflow plugin unload crash — 2026-11-01

已完成：定位后端对象销毁原因，修复插件链接和卸载清理。
已验证：48 轮嵌套卸载与重载。测试未调用用户实例的 IPC。

## 原因与对象归属

宿主是 `e5a03b6a5ce64ec4c85954649bad4df083627574`。
其 `DT_NEEDED` 包含 `libaquamarine.so.15`。
旧 `linux-20261018-keyboard1` 的两个插件，以及待加载的
`linux-20261031-robustness/viewflow-capture.so`，均依赖 `libaquamarine.so.14`。
系统 pkg-config 与宿主均报告 Aquamarine 0.15.1，但 SONAME 不同。
因此，仅比较 Hyprland commit 或依赖版本字符串不足以识别此问题。

Aquamarine 的 `backendInUse` 是导出的强引用全局变量。
`.14` 和 `.15` 均定义此变量。
ELF 符号解析使两份库使用同一变量，但两份库分别登记析构函数。
卸载 `.14` 时，其析构函数减少宿主后端的引用计数。
此析构函数不清空全局指针字段。重复加载和卸载会再次减少同一引用计数。
最终，`CBackend` 在宿主仍保留 `m_aqBackend` 时销毁。

已验证：原始 core 的 `backendInUse` 和 `CCompositor::m_aqBackend`
均保留控制块 `0x55674e48d950`，以及旧对象地址 `0x55674e484a10`。
控制块的强引用计数为 0，弱引用计数为 5，数据指针为 null。
`CBackend::hasSession(this=0)` 随后读取地址 `0x1c8`。
这与原始 `damageSurface → scheduleFrame → hasSession` 栈一致。

已验证：嵌套实例的硬件观察点捕获到引用计数归零。
调用栈为 `.14 → __cxa_finalize → CBackend::~CBackend`。
随后实例在 `scheduleFrame → hasSession(this=0)` 崩溃。
见 [析构与崩溃栈](plugin-unload-crash/legacy-backend-trace.txt)。

对象归属与代码证据：

- **后端由 Hyprland 创建**：`Hyprland@e5a03b6a5:src/Compositor.cpp:329`。
- **全局引用属于 Aquamarine**：`/home/wilf/data/aquamarine/src/backend/Session.cpp:27`、`:301`。
- **强引用析构不清空字段**：`/usr/include/hyprutils/memory/SharedPtr.hpp:77`。
- **触发库卸载**：`Hyprland@e5a03b6a5:src/plugins/PluginSystem.cpp:184`。
- **空后端访问**：`Hyprland@e5a03b6a5:src/output/Monitor.cpp:1124`。
- **虚拟输出来自宿主的输出 API**：`tools/display_topology.py:89` 调用 `hyprctl output create headless`。
  两个插件没有创建或销毁 headless output 的代码。
  原始 `HEADLESS-3` 的具体调用脚本或创建者 PID 未确认；现有 core 没有调用者记录。

插件卸载可以先返回 `ok`。Hyprland 随后安排配置重载：
`Hyprland@e5a03b6a5:src/plugins/PluginSystem.cpp:189`。
后续 surface commit 或配置刷新会再次调度帧，此时访问销毁的后端。
原始 core 位于 surface commit 路径，主事件循环无法继续响应加载 IPC。
这解释了后续 load 的超时。具体 IPC 到达时刻没有历史记录。

## 修复与清理审查

`platform/hyprland-plugin/CMakeLists.txt:32` 和
`platform/viewflow-capture/CMakeLists.txt:13` 仅导入宿主头文件。
插件不再链接 pkg-config 的宿主私有库列表。
宿主提供 Aquamarine 和 Hyprland 符号。
两个插件均使用 `-z now`，在登记回调前解析所需符号。
CTest 检查 ELF 依赖；旧插件作为反例时检查失败。

| 对象 | 卸载动作 |
| --- | --- |
| Lua 函数 | `PLUGIN_EXIT` 显式注销；缓存闭包由宿主的 ID 分发器拒绝调用 |
| 初始化失败后的对象 | 初始化作用域回滚；宿主 eject 不调用 `PLUGIN_EXIT`，故插件自行清理 |
| 捕获 stream/group | 重置 commit listener；取消并移除 timer；释放 renderer；停止并 join sender 线程 |
| popup backdrop | 取消并移除 timer；移除 pass hook；销毁 framebuffer、PBO、fence 和共享映射 |
| macOS shadow | 现有清理移除 decoration、延迟移除记录、positioner 缓存和两个当前 render pass 的自定义元素 |
| 主输入 hook、辅助 route | 移除 hook；销毁各 route 的输入对象和 metadata bridge |
| 输入与 metadata | 现有析构释放持有输入、恢复键盘状态、销毁 signal listener、移除原生 FD/timer、关闭 socket |
| recall 与 detach idle | 移除待执行的 event source；清空弱引用和配置 |
| desktop window | 按弱对象、surface、stable ID 和 PID 核对后恢复 workspace、尺寸、位置和浮动状态 |
| 过期控制记录 | 原始窗口状态另存为弱引用；权限记录过期不再丢弃卸载恢复记录 |
| compositor、monitor、output | 插件借用这些对象；插件退出不销毁宿主或脚本拥有的对象 |

窗口状态恢复位于 `platform/hyprland-plugin/src/desktop_window_controller.cpp:311`。
显式 `release(restore=false)` 仍提交用户的新位置。
常规 IPC 卸载在 compositor 线程执行；测试没有从插件自己的回调内重入卸载。

## 加载工具

`platform/desktop-app/plugin_safety.py:59` 在调用 hyprctl 前检查 ELF `DT_NEEDED`。
它拒绝直接链接宿主私有库的旧插件，并说明重建与旧插件卸载风险。
Qt 加载按钮、生成的加载命令、desktop-drag 和 multiscreen 工具使用此检查。
打包脚本同时包含独立预检模块。
Qt 保留同名的已加载插件，并明确说明没有热替换。
desktop-drag 停止自己的 daemon 与 output，但保留插件并说明原因。
已加载的旧库无法通过替换磁盘文件修复；工具不自动卸载此状态。

合并 `hyprvariants` 时，必须保留“仅导入宿主头文件”的链接方式。
不得恢复生产插件对 `PkgConfig::HYPRLAND` 库列表的链接。
本次未修改 Super/Command 拖动、最小化、隐藏或代理关闭行为。

## 嵌套验证

测试程序：`tools/tests/plugin-unload-nested.py`。
它自行启动指定二进制，使用独立短路径 runtime 和独立配置。
每次 IPC 均核对 lock 中的 PID，并显式设置 `HYPRLAND_INSTANCE_SIGNATURE`。
测试启动 3 个 kitty 窗口，不注入鼠标或键盘输入。

| 场景 | 轮数 | 每种卸载顺序 | GPU 帧包 | 初始化失败回滚 |
| --- | ---: | ---: | ---: | ---: |
| 原始宿主二进制，无 headless | 24 | 12 | 292 | 2 |
| 同一宿主二进制，有 headless | 24 | 12 | 295 | 2 |

每轮交替加载两组 `.so` 路径，执行两次 load 和两次 unload。
共 96 次成功 load、96 次成功 unload。
每轮包含一个 grid stream，以及同组的两个 commit stream。
24 轮在捕获活动时卸载；24 轮在显式停止捕获后卸载。
检查覆盖：两个卸载顺序、Lua 缓存闭包、插件映射消失、窗口保留、窗口状态恢复、
过期记录恢复、popup backdrop 回读，以及卸载输入插件后捕获继续运行。
两次运行的 backdrop sequence 分别为 94 和 96。
初始化失败回滚通过预占 Lua 名称触发。
缓存 Lua 闭包在同一 IPC batch 内检查，先确认其仍为函数，再检查宿主返回卸载错误。

NVIDIA 的原生嵌套 headless 格式列表无法分配 GBM buffer。
原生尝试产生零尺寸输出，后续配置刷新触发 framebuffer 断言。
有 headless 的正向检查使用 `tools/tests/nested-headless-formats.cpp` 测试库。
该库仅让 headless 使用嵌套 Wayland 后端公布的格式；不修改对象所有权或析构。
该库未安装，也未加入正式插件。
无 headless 的 24 轮检查未使用预加载库。

复现命令，路径按本次构建记录：

```sh
cmake -S platform/hyprland-plugin -B /tmp/viewflow-unloadcrash/build-hypr -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build /tmp/viewflow-unloadcrash/build-hypr -j4
cmake -S platform/viewflow-capture -B /tmp/viewflow-unloadcrash/build-capture -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build /tmp/viewflow-unloadcrash/build-capture -j4
python tools/tests/plugin-unload-nested.py --hyprland /home/wilf/.local/lib/hyprland-hdr/Hyprland --input-plugin /tmp/viewflow-unloadcrash/build-hypr/viewflow-hyprland.so --capture-plugin /tmp/viewflow-unloadcrash/build-capture/viewflow-capture.so --artifacts /tmp/viewflow-unloadcrash/replay --cycles 24
```

测试库构建命令：

```sh
PKG_CONFIG_PATH=/home/wilf/data/aquamarine/.prefix/lib/pkgconfig c++ -std=c++23 -shared -fPIC tools/tests/nested-headless-formats.cpp -I/home/wilf/data/aquamarine/.prefix/include -o /tmp/viewflow-unloadcrash/nested-headless.so $(PKG_CONFIG_PATH=/home/wilf/data/aquamarine/.prefix/lib/pkgconfig pkg-config --cflags --libs aquamarine pixman-1 libdrm)
```

有 headless 时，在测试命令中增加
`--headless --headless-format-preload /tmp/viewflow-unloadcrash/nested-headless.so`。

已验证：插件 CTest 共 21 项通过（12 + 9）。
已验证：加载预检和 Linux 命令生成的 4 项 Python 检查通过。
已验证：`bash tools/tests/desktop-drag-launchers-test.sh` 通过。
已验证：Python 编译检查与 `git diff --check` 通过。
失败：`python -m unittest discover -s platform/desktop-app -p 'test_*.py'` 发现 6 个导入错误；当前 Python 缺少 `PySide6`、`ifaddr`、`spake2`。
未验证：GPU 像素正确性、桌面 GUI 运行、物理输入租约、Mac、真实会话升级、其他插件组合和回调内重入卸载。
用户的 Hyprland、Viewflow 服务、安装目录、配置目录和 Mac 未修改。

[原始二进制检查结果](plugin-unload-crash/native-result.json) ·
[headless 检查结果](plugin-unload-crash/headless-result.json) ·
[构建 SHA256](plugin-unload-crash/build-sha256.txt)。
完整本次日志保留于 `/tmp/viewflow-unloadcrash/`。
