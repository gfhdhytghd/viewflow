# DMA-BUF 导入缓存：编码收益没有转化为桌面延迟收益

2026-09-08。**四轮对照重复测得约 1.0–1.1 ms 的编码节省，但完整链路没有改善，原型未接入生产。** 捕获→所见桌面上界中位数，关闭为 38.83 / 38.34 ms，开启为 39.03 / 39.27 ms；原生提交速率也未提高。4K60、两帧内显示仍未验证。

| 轮次 | 导入中位 ms（采样） | 整段编码中位 ms（全量） | 捕获→mutation 上界中位 ms | 捕获→DD 上界中位 ms | DD 上界 P95 ms | native commit/s |
|---|---:|---:|---:|---:|---:|---:|
| import-cache-off-a1 | 0.853 | 6.726 | 12.949 | 38.833 | 44.099 | 57.679 |
| import-cache-on-b1 | 0.049 | 5.646 | 11.820 | 39.029 | 43.957 | 57.438 |
| import-cache-on-b2 | 0.047 | 5.741 | 12.069 | 39.267 | 44.038 | 57.002 |
| import-cache-off-a2 | 0.845 | 6.766 | 13.799 | 38.336 | 43.786 | 57.557 |

导入阶段是 fence 后到 CUDA map 完成的 host wall time，包含驱动调用和等待，不是 GPU kernel 独占时间。每轮 GPU 细分统计排除 frame<30 后有 52 条采样；整段编码使用完整 source/wire 时间线。另一个定义包含函数资源收尾的采样 total 中位数为 6.637 / 5.584 / 5.636 / 6.666 ms，两种统计范围不混用。[导入统计](import-comparison.json)、[端点及同帧配对](comparison.json)。

相应 mutation→DD 中位数为 25.221 / 26.185 / 26.161 / 24.821 ms。Windows 收到可提交帧更早，但提交后的观测区间更长；目前不能把后段归因于 DWM CPU，也不能把不同阶段的中位数相加来重建总延迟。下一步仍需要研究后段队列、GPU 合成及显示端点，而不是以局部编码收益代替整个目标。

唯一捕获配对样本分别为 1,185 / 1,151 / 1,199 / 1,137；A1 的 6 个重复捕获 marker 只从要求唯一捕获身份的阶段统计排除，完整绘制→DD 仍保留。捕获→DD 上界最大值分别为 104.147 / 128.763 / 119.301 / 121.384 ms，未删除长尾。

## 为什么测这条路径

前置身份诊断运行 55 秒，3,124 次有效 fstat 读回均为同一组存储身份和布局。该轮导入中位 0.873 ms、整段编码采样中位 6.720 ms；一条被并发日志打断的细分行单独计数并排除，244 ms 的有效导入长尾保留。此轮使用 `VIEWFLOW_GPU_TIMINGS=all`，不是四轮 A/B 的控制组。[前置诊断](runs/import-identity-baseline-01/import-analysis.json)。

当前生产编码器每帧创建 EGLImage、绑定纹理、注册 CUDA，读取完毕后注销。原型最多保留四组 EGLImage、独立 GL 纹理、CUDA 注册和 DMA-BUF FD 引用，按最近使用次序淘汰。键包含设备号、inode、尺寸、stride、offset、fourcc 和 modifier；持有独立 FD 引用以防 inode 被回收重用。fstat 或可选 FD 保留失败时使用普通导入路径。

每一帧仍等待自身 native fence，再调用 CUDA map、取得本次 mapped array、复制/准备像素、unmap，并完成 stream 同步后才结束生产者读取。仅正常准备完成才保留注册；错误或准备阶段过期会清除相关条目。没有缓存 mapped array 指针或帧内容。CUDA 文档明确要求资源映射期间图形 API 不访问该资源，并描述 map/unmap 的同步保证；本原型没有移除这些边界。[NVIDIA 图形互操作文档](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__GRAPHICS.html)、[Linux DMA-BUF 文档](https://www.kernel.org/doc/html/v6.16/driver-api/dma-buf.html)。

完整链路开启轮最后快照均覆盖 3,120 次导入：B1 有 3,112 次命中、8 次 miss，B2 有 3,113 次命中、7 次 miss，均保留一个条目且无容量淘汰。`evictions` 仅统计容量淘汰，错误/过期清理不计入；不能把 entries 直接当作 misses−evictions。最后快照之外的尾部不推算为已验证计数。

## 正确性检查

- CTest 7 项全部通过；另以开启缓存运行原有 3840×2400 GPU 集成测试，检查 GOP/IDR、颜色与 VUI、完整 alpha、C ABI 保留输出、atlas 切换及过期后恢复。
- 最终 GPU oracle 在五块持久导出存储间反复复用同一个数字 FD，并逐帧改变颜色和 alpha。先交替缓冲区触发淘汰，再连续更新同一缓冲区验证命中。缓存开启轮的 64 帧包含 31 次命中、33 次 miss、29 次容量淘汰，最多四个条目。
- 每种模式逐字节核对 589,824,000 个 alpha 值，并独立软件解码检查 64 帧当前颜色。两种模式的完整 H.264 流逐字节一致，SHA256 均为 `1a2dd538cd02f958ea0243a64227b57b5937ea8be40364bca3799a355698e651`。[Oracle 数据](method/oracle-comparison.json)、[关闭流](oracle/oracle-v2-off.h264.gz)、[开启流](oracle/oracle-v2-on.h264.gz)。这是这些合成输入的验证，不是所有应用的视觉验收。

初版 oracle 每次重建导出对象，44 次导入全部 miss，只验证了错误 FD 复用与淘汰，不能证明命中时的内容更新。其源码和日志保留为 V1。最终改为持久导出和逐帧新 fence；首次合并 stdout/stderr 导致记录被插入打断，保存混合日志后，以同一 V2 二进制分别捕获两个流重新执行，两轮完整记录均通过分析。

## 完整链路条件与清理

使用根 Hyprland 的独立输出和原有 capture 插件，GPU fixture 3840×2400、scale 2、半透明 128 像素边缘；捕获 3848×2408、atlas 3968×2432、H.264。Windows 为 Intel GPU、6144×3456@60 输出，保持完整 sigma=12 的毛玻璃。四轮用同一隔离 sender 二进制，`VIEWFLOW_GPU_IMPORT_CACHE=0/1` 控制开关；GPU_TIMINGS=1 采样、source/wire 与 native 身份时间线保持全量，native GPU queries 和 socket tracing 关闭。Windows 同一原生二进制保持 RequestCommitAsync 关闭。

每轮 source 55 秒、异步 DD observer 30 秒，顺序关/开/开/关，四轮共用一个自有输出，结束后移除。正常 mTLS 和既有私有配对配置未绕过；私钥及连接配置未归档。观察器仅以 NOACTIVATE 定位自有 proxy，测试不调用输入注入或焦点切换 API。

DD LastPresentTime 表示包含该 marker 的一次桌面更新时间，可能不是第一次显示，也不是光子时间。所有延迟上界保留时钟不确定度；native commit/s 是应用提交速率，DD marker/s 是观察到的变化速率，均不能当作已验证物理 FPS。

最终审计确认：测试进程、私有 Windows 任务及 49073 端口占用均为 0；自有输出已移除，原有 DP-4 / HEADLESS-13 的几何与插件保持不变，configerrors 为空。四轮 source 按计划 exit=124，receiver 均记录 exit=1、watchdog=0；observer exit=0、invalid=0、readback abandoned=0。ESRV PID 10132 仍为 High，未修改其优先级。生产 encoder 源码与 sender 二进制均与实验前相同。[清理与生产身份审计](method/final-state.json)。

## 文件与复算

`source-before` 保存生产 encoder 改动前副本；`source` 是完整独立 NVENC 源码及最终 oracle，原型开关默认关闭。四轮 sender 在添加 oracle 专用 CMake target 之前构建，准确的原 CMake 文件另存 `method/candidate-built-CMakeLists.txt`；该添加只影响测试目标。二进制身份、源码 SHA256、构建/测试日志均保存于 method。最初隔离构建因复制的 CMake cache 指向旧路径及缺少 protocol 目录失败，补齐隔离源码并删除隔离副本内的旧 cache 后成功，没有修改生产构建目录。

将 runs 中的 `.log.gz` 解压到任意临时根的同名目录，复制 state.json，运行 `python3 method/analyze-endpoint.py <根> <labels...>` 和 `python3 method/analyze-import.py <根> <labels...>`。Oracle 分析可直接对保留的 method 日志和 oracle 压缩流运行 `python3 method/analyze-oracle.py method oracle`。`method/verify-archive.py` 自动解压并精确复算五轮分析、时间线与 oracle，随后验证 SHA256 清单。运行测量的脚本包含当时已验证的主机与私有路径，不应直接复用旧 PID/证书。
