# 源端 alpha 输出所有权：消除一次全量复制

2026-09-08。承接上一轮校准和火焰图，采用同一二进制、同一 3840×2400 源 fixture 与 Windows 接收端，交错比较原有复制模式和不可变原生输出持有模式。每轮 25 秒，WPR 未录制；保留同样的逐帧诊断、alpha CPU 计时及桌面观察器。

## 改动与正确性

`vf_gpu_dmabuf_output_view_raw_alpha` 返回 output 自己的不可变缓冲区；Rust `RawAlpha` 保存 output 所有权，借用 slice 不超出 owner 生命周期，且类型禁止跨线程发送/共享。缓存命中时新输出按原生析构路径释放；未命中时旧缓存替换。未将 C++ allocation 交给 Rust Vec 析构，也未改变 CUDA 同步与 pinned readback。

这消除了 `cabi_to_rust` 的每帧 9,650,176 字节复制。第一段 pinned→vector 复制及全量 cache 比较仍存在。缓存最多保留一个原生 output，因此还保留该输出原有的压缩颜色字节；其大小仍受原有 output bound 限制。

为了可重复对照，`VIEWFLOW_ALPHA_OUTPUT_COPY=1` 使用原有复制路径；默认或 `0` 使用原生所有权模式。日志明确打印 `alpha-output-storage mode=...`。每次模式切换启动独立进程。

## 重复组结果

以下均为每轮分布的中位数，单位 ms。alpha 总 CPU 先按同一帧求和，再取中位数；view 模式只包含保留的两项操作，日志中 C ABI 全量复制记录为零。

| 轮次 | alpha CPU | encode host（含等待） | capture→应用 mutation | capture→所见桌面 |
|---|---:|---:|---:|---:|
| A2 复制 | 3.276 | 11.559 | 28.234 | 64.568 |
| B2 原生持有 | 2.129 | 10.310 | 26.183 | 63.926 |
| A3 复制 | 3.326 | 11.519 | 27.484 | 64.201 |
| B3 原生持有 | 2.120 | 10.198 | 26.486 | 63.711 |

局部 alpha CPU 减少约 35–36%，encode host 减少约 1.25–1.32 ms。桌面观测端点仅降低约 0.49–0.64 ms，不能据此宣称整条链路明显提速或已到两帧目标。GPU 排队、原生 alpha 展开/比较、桌面合成与观察器干扰仍存在。

A1/B1 也保存，但 A1 期间运行过一次 0.47 秒的独立 Rust GPU 接口测试，因此不用于主要性能结论。更早的首次 fixture 启动因测试窗口规则处于停用状态，尺寸校验未通过，在启动传输之前退出；启用仅针对 fixture 的既有规则后才进入上述对照。最终恢复该规则为停用，fixture 数量为零。

“所见桌面”使用 marker 与 DXGI LastPresentTime；观察器可能错过首次出现，不是真正首呈现或光子时间。保留上一报告的限制；观察到 marker 的速率不能当作实际显示 FPS。详见 [对照统计](comparison.json) 与每轮压缩日志。

## 验证

- Linux Release/native GPU build 通过。
- Rust 编码适配测试 16 通过、1 项 GPU 大画布测试保留 ignored。
- 原生 C ABI 与 CUDA/NVENC 集成测试 2 通过。新增验证保留多个输出，跨越后续编码和 encoder 析构后，指针及全部 alpha 内容仍与原始快照一致。
- Rust→native owned-buffer GPU 接口测试单独显式运行，1 通过；确认为 native-owned-view。
- 六轮完整隔离会话均由计划的 25 秒 source timeout 收尾，receiver 报 peer close（exit 1），watchdog=0，测试进程及计划任务清理成功。不是接收端退出码 0 的声称。
- 当前工作树 `git diff --check` 通过。代码与测试二进制哈希见 [tested-source-sha256.json](tested-source-sha256.json)。本轮未替换正在使用的桌面部署。

下一步优先将复用扩展到 Windows pipe 解压和 GPU alpha cache，再做独立 A/B；这项源端优化不能替代完整目标验证。
