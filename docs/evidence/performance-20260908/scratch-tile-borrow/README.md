# 4K prepared tile 显存复用

2026-09-08，Linux NVENC 源端 → Windows 原生接收端，隔离 25 秒 A/B 四轮。内容为 3840×2400，捕获为 3848×2408，alpha atlas 为 3968×2432。**减少了本地资源成本，未证明端到端帧率提升，4K60 / 两帧延迟目标仍未达到。**

## 改动

最后一张非 direct tile 准备完成并同步后，交换编码器已有的两块全画布 RGBA scratch 缓冲区，以只读借用保留 prepared tile；合成目标仍为另一块不同的缓冲区。避免这张 tile 的额外 cudaMallocPitch、整张 device copy 和 cudaFree。多 tile 的其他临时缓冲区仍各自释放，借用指针随当前调用结束，不增加跨帧资源池。所有原有读写同步、生产者所有权释放和过期后恢复保持有效。

默认使用 scratch swap；每进程 `VIEWFLOW_GPU_TILE_COPY=1` 可运行原来的复制路径。四轮使用同一二进制，仅改变此开关，顺序 A1/B1/B2/A2；原有 alpha 输出所有权转移和 Windows alpha 复用均开启。逐帧日志、桌面观察器开启，无 WPR/包捕获并发。

## A/B 结果

以下均为 ms 中位数，剔除 frame<30；commit/s 按首末原生 commit 的 QPC 计算。

| 轮次 | cleanup 后至函数返回 | 编码 host | 捕获→原生修改上界 | 捕获→桌面被看到上界 | 原生 commit/s |
|---|---:|---:|---:|---:|---:|
| 4k-scratch-copy-a1 | 0.163 | 9.775 | 18.492 | 58.979 | 54.830 |
| 4k-scratch-borrow-b1 | 0.006 | 9.474 | 17.311 | 58.817 | 53.955 |
| 4k-scratch-borrow-b2 | 0.006 | 9.807 | 17.917 | 59.681 | 52.285 |
| 4k-scratch-copy-a2 | 0.165 | 9.859 | 17.929 | 59.122 | 54.139 |

清理阶段约节省 0.16 ms，编码配对差约 0.30 / 0.05 ms；B 轮 commit/s 没有提升。因此只认可本地资源成本减少，不把网络/系统波动解释为已证实的收益。日志确认 copy 每帧释放一块 prepared tile、borrow 每帧借用且不释放这块 scratch。两种路径均仍出现约 80 ms GPU 主机调用长尾，没有解决 EGL/CUDA 全部长停顿。

原生 commit 不等于物理呈现帧率；桌面观察可能错过第一次出现，因此其时延仅是观察上界。原始日志和每轮 clock-and-stages、desktop、summary 均保存在子目录；[comparison.json](comparison.json) 包含全部分位数与最长调用的阶段。

## 原生验证

- 原生 CTest 7 项通过；复制基线集成校验通过。
- 3840×2400 的复制与借用两种路径均通过完整 alpha 像素比较及 H.264 解码颜色检查；包含 2/1/0/1/2/0/2 tile 数量切换、近全画布输入及清空 padding 检查。
- 在不同阶段强制干净过期后，后续帧仍正确输出；包含借用完成之后和 NVENC 之后的退出。
- AV1 sparse mode 1/2 的两种路径逐字节比对 alpha、解码 RGBA 和 patch 描述均一致。
- Linux release 构建通过；未向当前桌面注入鼠标/键盘测试，未部署主运行版。

所有轮次源端 124 为计划 timeout；接收端 1 为源端结束后的 peer close，watchdog=0、桌面观察器退出 0，隔离进程和任务已清理。试验当时二进制与 CUDA 源码哈希见 [trial-source-sha256.json](trial-source-sha256.json)；此后新增 socket 诊断的二进制不能冒充此 A/B 版本。

`summarize-trials.py` 从仓库根运行，读取 `/tmp/viewflow-integrated-pair` 和 `/tmp/viewflow-frame-fixture-first` 的同名原始输入；子目录压缩日志可用于重新展开。
