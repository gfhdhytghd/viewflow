# Windows → Linux 毛玻璃调查（2026-09-07）

结论：当前反向路径没有实现目标 Linux 背景上的材质重建。不能把透明度传输成功当作 Acrylic/Mica 正确显示；也不能仅修改 no_blur 就宣布修复。

## 已核对的实现

- `platform/windows-reverse/main.cpp` 的捕获回调直接复制 WGC BGRA 纹理，随后 CopySubresourceRegion 拼入 atlas，没有分离材质与背景。
- `platform/windows-reverse/alpha_plane.cpp` 逐像素提取捕获纹理的 alpha；这不是材质区域检测。
- `platform/reverse-common/wire.hpp` 的 Frame/Tile 传输颜色、alpha、几何等信息，没有材质类型、背景模糊区域、半径、色调或背景来源。
- `platform/linux-reverse/main.cpp:273` 对反向窗口设置 no_blur=true；IME 规则也禁用模糊。接收 shader 只还原 YUV 并输出 RGBA，不采样目标背景。
- 接收 shader 把 RGB 限制在 [0, alpha]，采用预乘颜色的约束；源捕获接口却只声明 bgra8_alpha_preserved_unknown_mode。缺少一般窗口的 alpha 语义验证。若收到直通颜色，clamp 不是预乘转换：例如 R=0.8、a=0.5，clamp 得 0.5，正确预乘为 0.4。这是待测风险，尚未证明是用户当前症状的原因。
- 编码端显式选择 BT.709、有限范围 YUV；接收 shader 使用对应系数。静态检查未发现直接的 601/709 或全/有限范围不匹配，但未进行端到端色卡测量。

## 材质区别与影响

微软文档将 Mica 定义为结合主题与桌面壁纸的不透明材质，Acrylic 为半透明毛玻璃；两者不能统一按透明像素处理。

来源：https://learn.microsoft.com/en-us/windows/apps/develop/ui/system-backdrops

由上述代码推导：

1. 捕获中保留半透明而不含背景模糊的像素，在 Linux 上会直接透出清晰背景。
2. 若 Windows 背景效果已经烘焙进颜色，Linux 无法仅凭颜色和 alpha 换成自身背景；alpha 为 1 时开启本地 blur 也不会穿透前景。
3. 全窗口开启 blur 还可能把透明边角与阴影当作材质区域，且无法恢复 Acrylic 的色调等参数。

上述分支需要实际捕获像素区分，不能假定所有 WGC 窗口行为一致。

## 验证边界和后续实现依据

本轮为代码与官方资料调查，未修改运行配置、注入输入、改变焦点或重启会话。只读枚举曾看到 Word、Excel 的 ViewflowReverse 代理；后续枚举没有代理，未推断其消失原因，也未取得源/目标成对截图。未确认它们使用哪一种材质。

下一步应对用户指出的具体窗口同时记录源 WGC RGBA 与 Linux 输出：统计材质内区 alpha、比较 RGB 与 alpha、区分源端已合成背景和透明前景，并包含普通透明窗口、Mica、Acrylic 三类样本。交互由用户操作。

实现需依据结果选择：已合成材质先保证像素忠实；目标背景 Acrylic 需要可信的材质区域和可分离前景，再在 Linux 合成背景模糊，保留文字、边角和阴影。通用 WGC 是否可提供足够信息仍需实验；当前不能承诺仅通过现有捕获接口实现任意应用的精确材质重建。
