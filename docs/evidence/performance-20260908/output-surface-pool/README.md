# Windows 输出纹理池：局部节省，桌面延迟未稳定改善

四轮关闭／开启／开启／关闭对照，输出纹理池把资源准备中位耗时从 0.610 / 0.616 ms 降为 0.172 / 0.174 ms，完整 Submit 从 1.230 / 1.232 ms 降为 0.767 / 0.771 ms。复用与内容校验通过，但捕获到桌面延迟没有稳定改善。原型保留在本证据目录，未改动生产实现或默认配置；**4K60、两帧内显示仍未证明**。

改变的是 `GpuVideoCompositor::Composite` 中每帧 BGRA8 输出纹理和 RTV 的创建。四槽池仅复用已经没有帧持有的资源；被保留的帧、裁剪区域继续持有同一个 owner。池满时走普通分配，不等待、不丢帧、不关闭会话。纹理内容仍由同一 NV12/R8 shader 每帧重画，原生 surface copy、完整背景模糊、编码质量和协议均未改动。

| 轮次 | 资源准备 ms | 解码/合成 Submit ms | 原生 commit/s | 桌面标记变化/s | 捕获→桌面上界中位 ms | P95 ms | 有效身份样本 |
|---|---:|---:|---:|---:|---:|---:|---:|
| pool-off-a1 | 0.610 | 1.230 | 56.155 | 35.781 | 38.490 | 44.843 | 1067 |
| pool-on-b1 | 0.172 | 0.766 | 56.286 | 37.377 | 39.757 | 44.250 | 1116 |
| pool-on-b2 | 0.174 | 0.771 | 57.957 | 35.407 | 38.583 | 43.950 | 877 |
| pool-off-a2 | 0.616 | 1.232 | 57.727 | 37.198 | 38.535 | 44.156 | 1108 |

资源准备与 Submit 是 frame≥30 的主机调用耗时，包含 API 内部等待，不能称为纯 GPU 执行时间。两次开启最后记录分别为 3,059 / 3,151 次获取、1 次创建、3,058 / 3,150 次复用、0 次满池回退。原始计数与各阶段分布保存在 [comparison.json](comparison.json)。

| 轮次 | 捕获→原生修改上界中位 ms | 原生修改→桌面中位 ms | 绘制开始→桌面上界中位 ms | 绘制开始→桌面 P95 ms |
|---|---:|---:|---:|---:|
| pool-off-a1 | 13.814 | 24.790 | 49.098 | 55.532 |
| pool-on-b1 | 11.132 | 28.175 | 45.706 | 50.401 |
| pool-on-b2 | 11.403 | 27.286 | 54.502 | 60.411 |
| pool-off-a2 | 13.688 | 24.920 | 47.100 | 52.469 |

捕获到原生修改提前了，但没有转化为更早的桌面观测。后半段包含排队、GPU、系统合成和观察器行为，不能只凭这一段命名为 DWM CPU 开销。不同列的中位数不可相加。下一步优先检查能否消除输出 BGRA 中间纹理与后续 surface copy，直接绘入合成表面；本轮没有实现或测量该方案。

测试使用同一 Linux sender、同一 Windows 原生候选二进制，仅 `VIEWFLOW_VIDEO_OUTPUT_POOL=0/1` 不同。内容为 3840×2400、scale=2、128 像素半透明边缘；捕获含边框 3848×2408、atlas 3968×2432。使用正常 mTLS 配对，原 H.264 质量、sigma=12 的完整模糊、背景布局保持不变。Windows 为 Intel GPU（vendor 32902/device 32103）、6144×3456@60 输出。每轮源端运行 55 秒、桌面观察 30 秒，native GPU queries 与 socket tracing 关闭。Linux 未使用此前 DMA-BUF 缓存候选。

时钟交换和每帧校准映射均复核通过；数据来自 Windows Desktop Duplication，不是光子或最早扫描输出时间。原生 commit/s 不是物理显示 fps，桌面标记变化/s 是观察器捕捉到的变化频率。B2 有 180 个重复采集身份，从捕获阶段配对中明确排除，仍保留在绘制→桌面统计和原始日志；该轮捕获配对 877、绘制配对 1,057，不能把这两个样本集合当作相同。其余三轮无重复身份。所有观察器 invalid=0、abandoned=0，长尾未裁掉。

所有权与 GPU 校验：

- `GpuVideoCompositor::Create` 默认保持普通独立纹理分配。只有显式 opt-in 的 frame owner 调用者才能使用池，裸 COM 别名本身不构成池的 lease。原生 MTA 完成结果、身份重映射和裁剪都保留整个帧，当前帧的 copy 排队结束后才会提交下一帧工作。
- [硬件池测试](source/tools/output-pool-test.cpp)保留五张 3840×2400 帧，验证不同纹理和满四槽后回退；逐像素核对 BGRA。裁剪保留父帧 owner，释放裁剪后可复用；尺寸变化和设备变化测试通过。
- 16 次先排队 copy、释放帧、复用同一纹理并写入新颜色，之后才读回。每次目的纹理保持旧颜色、新纹理保持新颜色；两张 4K 纹理全量 BGRA 检查。同步读回仅用于测试。
- [实际 H.264 解码测试](source/tools/output-pool-decoder-test.cpp)在关闭／开启两种模式各提交 24 帧 3840×2400 图像，逐帧变化 alpha，所有 alpha 像素精确匹配。两模式完整 BGRA 的 FNV64 校验和逐帧相同；这是校验和比较，未保存全量 BGRA 做字节差分。保留前五帧后，后续绘制不改变其像素；开启最后为 created=7、reused=17、fallback=3。
- 关闭模式额外只保留第 1 帧裸 COM 纹理引用，释放帧 owner 后继续提交至第 24 帧，最后读回仍为第 1 帧，覆盖旧接口语义。独立 oracle 是平色 H.264 输入加变化的 alpha，不代表所有应用画面已人工验收。

GPU 复用依据是同一 immediate context 中有序提交的读取、后续覆盖，而不是把 Flush 当作完成屏障。[CopySubresourceRegion](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-copysubresourceregion)与 [Flush](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-flush)均为异步；[D3D11 context 文档](https://learn.microsoft.com/en-us/windows/win32/direct3d11/overviews-direct3d-11-devices-intro)说明 immediate context 的命令执行方式。跨设备 copy 不在该合同内，现有区域复制函数会核对实际设备。

[MSVC 构建记录](method/integrated-build.log)、[GPU 测试](method/test-pool.log)、[解码校验](method/decoder-comparison.json)、[原生/runner 二进制哈希](method/integrated-binary-hashes.json)、[测试二进制哈希](method/test-binary-hashes.json)和 [104 个远端源文件核对](method/integrated-source-sha256.json)已保存。两个新增 oracle 文件在原生构建后上传，仅用于测试；产品编译所用源文件没有在运行间修改。

[最终检查](method/final-state.json)确认独占 HEADLESS-21、fixture、计划任务和接收端进程已清理，已有 DP-4/HEADLESS-13 几何及插件保持原状，用户/系统 blur 环境变量为空，esrv_svc 原优先级未改变。四个生产源文件与 source-before 逐字节一致，原 sender 哈希未变。没有注入鼠标、键盘或焦点操作。

四轮源端均为计划的 timeout 退出 124，观察器 exit=0。B1/B2/A2 的 runner 记录接收端 exit=1/watchdog=0；**A1 在源端计时结束后仍记录到接收端存活，随后由控制器清理私有 task/job，没有接收端退出码记录**。因此不声称 A1 自然结束。该轮 30 秒桌面观测已完成、日志包含后续提交，性能数据保留，并在 analysis 中标注终止方式。

原始日志压缩保存在 `runs/`，每轮有 analysis 与时间线。配对私钥、运行配置和可执行文件未复制入证据目录。运行 `python3 docs/evidence/performance-20260908/output-surface-pool/method/verify-archive.py` 可从归档日志精确复算四轮分析与时间线，并核验清单；它不会重新启动桌面测试。
