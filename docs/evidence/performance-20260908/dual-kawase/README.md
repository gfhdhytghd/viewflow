# Dual Kawase 离屏试验

按用户要求实现并测试五点下采样、八点上采样的 D3D11 Dual Kawase。此处是通用权重的最初实现，**不是后续按本机 Hyprland 参数和实际步长移植的版本**；后者见 [30 Hz 后台背景缓冲](../background-buffer/README.md)。

Windows Intel 32902/32103，3840×2160 同一合成图，每个模式 80 个预热后 GPU 时间戳样本。无窗口、输入或真实背景抓取，保存源码、CSV、完整 BGRA gzip、PNG、程序哈希和退出状态。

| 方法 | GPU 中位 ms | 与 Gaussian Balanced 的 RGB 平均差（0–255） | 最大差 |
|---|---:|---:|---:|
| Gaussian Balanced | 3.404 | 0 | 0 |
| Gaussian SPEED | 3.101 | 0.462 | 8 |
| Dual，3 层，offset=2 | 6.634 | 0.406 | 6 |
| Dual，4 层，offset=1 | 6.790 | 1.269 | 15 |
| Dual，4 层，offset=1.25 | 6.742 | 1.288 | 21 |

[原始汇总](summary.json)。3 层方案在该图上的效果接近原算法，但此实现更慢。

另一次 [线性末级试验](linear-finish/summary.json)把最后一级全分辨率八次采样改为单次双线性采样：3 层版本降至 4.078 ms，RGB 平均差 0.437、最大差 5；仍慢于该轮 Gaussian Balanced 的 3.398 ms。这不能证明 Dual Kawase 在所有设备/实现上更慢，也不能替代真实背景链路的对照。当前未部署该版本。
