# 源端不可变 alpha 快照：复用内容相同的输出

2026-09-08，Linux NVENC → Windows 原生接收端，4K 源内容 3840×2400，捕获为 3848×2408，alpha atlas 为 3968×2432。**透明度 CPU 中位耗时减少约 61–62%，源端编码中位数减少约 1.1–1.5 ms；尚未稳定达到 60 次提交/秒，也未证明两帧内首次显示。**

## 改动

GPU 完成 alpha readback 与同步后，逐字节比较 pinned 缓冲区与上一次成功输出的不可变快照。相同时复用 `shared_ptr<const vector<uint8_t>>`；变化时才将新 alpha 复制到独立快照。编码或 cleanup 失败不会发布这个候选快照作为下一次成功输出的缓存。编码器只额外保存最后一个快照的共享所有权，输出对象可以独立保留旧快照，后续 readback 与编码器析构都不能修改它。

C++ 消费者统一通过 `EncodedDmabufFrame::alpha()` 读取共享或复制存储；C ABI 的 info/copy/view 接口与所有权有效期保持原样。Rust `RawAlpha` 继续持有原生 output、保持同线程约束；相同不可变 slice 的指针和长度可直接证明内容相等，不再重复扫描 9.65 MB。不同指针仍用全量比较，generation、尺寸和配置校验仍有效。

默认启用；`VIEWFLOW_GPU_ALPHA_REUSE=0` 使用原来的逐帧复制路径。没有减少 GPU 同步或改变媒体格式。**GPU→pinned 的完整 readback 和原生 CPU 的全量比较仍存在**，本次消除的是相同内容时 pinned→vector 的复制，以及 Rust 的第二次比较。

## 交错 A/B

四轮使用同一个源端二进制，顺序关闭 A1 / 开启 B1 / 开启 B2 / 关闭 A2，每轮 25 秒。source alpha 输出持有、scratch swap、Windows alpha 复用均开启；逐帧日志和桌面观察器开启；socket trace、QUIC 5 ms sampler、WPR、包捕获关闭。未向主桌面注入鼠标键盘。

以下为 frame≥30 的中位数，单位 ms。alpha CPU 必须按同一帧汇总原生比较、实际复制和 Rust cache 比较后再求分布，不能用几个独立中位数相加；分析器拒绝重复阶段、无效时钟和形状不匹配。

| 轮次 | alpha CPU 合计 | 源端 encode host | 捕获→原生修改上界 | 捕获→桌面被观察到上界 | 原生 commit/s |
|---|---:|---:|---:|---:|---:|
| 4k-alpha-share-off-a1 | 1.990 | 9.794 | 17.821 | 60.752 | 49.119 |
| 4k-alpha-share-on-b1 | 0.776 | 8.340 | 16.565 | 54.839 | 55.046 |
| 4k-alpha-share-on-b2 | 0.804 | 8.715 | 16.758 | 58.275 | 51.777 |
| 4k-alpha-share-off-a2 | 2.120 | 9.775 | 17.910 | 58.471 | 53.124 |

开启轮均仅出现 2 次 pinned→vector 复制；关闭轮分别为 1,222 / 1,326 次。Rust cache 比较在开启轮降到约 1 μs 以内，主要剩余成本是原生 9.65 MB 比较。两组编码中位耗时均下降，但第二组原生 commit/s 没有提升；长尾和系统/网络变化仍影响整条流水线，所以不声称已证明持续帧率提升。

第一组桌面观察上界下降约 5.91 ms，第二组只下降约 0.20 ms，同样不能把第一组变化全部归因到本改动。桌面观察器可能错过第一次呈现，commit 也不是物理呈现凭据。完整分位数、copy/reuse 计数见 [comparison.json](comparison.json)，原始压缩日志及校准在各轮子目录。

## 校验

- 原生 CTest 7 项通过。Rust GPU adapter 16 项通过、1 项原有 ignored。
- 3840×2400 复制/复用两种模式都通过原生颜色解码与全量 alpha 像素比较。
- 扩展 C ABI 测试覆盖四个保留输出：相同 alpha、整帧 alpha 变化、仅最后一个字节变化；指针复用只发生于完整相等时。每个旧输出在后续编码以及编码器销毁之后均保持同样的字节，分别析构无悬空引用。
- 覆盖干净过期、NVENC 已提交后过期、后续强制 IDR 恢复，以及 2/1/0 tile 转换、近全画布输入和清空 padding。颜色依旧通过 H.264 解码检查。
- Linux release 构建通过。Windows presenter/receiver 本轮未修改，沿用前轮已验证的隔离版本。

扩展为第四帧时，首次测试漏更新测试端的 IDR 请求，触发 output info 断言；已修正测试请求并重新通过全部原生和两种 4K 路径。失败测试进程被终止后才开始最终验证，性能 A/B 期间没有其他 GPU 测试并行。

所有轮次源端 124 为计划 timeout；Windows 接收端 1 为源端关闭后的 peer close，watchdog=0；桌面观察器退出 0。临时 HEADLESS 输出和自有 fixture 均已清理，原有 monitors JSON 与测试前完全一致；主运行版未部署。源码、二进制、测试日志和最终状态同目录保存。

`run-trials.py` / `owned-output.py` 是本机隔离测试辅助脚本，依赖此前准备的 `/tmp` receiver/fixture 配置；`summarize-trials.py` 从仓库根运行并读取同名 `/tmp/viewflow-integrated-pair` 原始日志。压缩日志可重新展开复算；原始配置属于测试环境，不要直接用其端口/显示名称替换部署配置。
