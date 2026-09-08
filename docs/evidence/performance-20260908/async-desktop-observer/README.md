# Windows 桌面观察器：异步读取与同步对照

2026-09-08，Linux → Windows 隔离测试。内容为 3840×2400，捕获含四像素边框为 3848×2408；Windows 桌面为 **6144×3456 @ 60 Hz**，Intel 硬件适配器。内容以 1:1 像素放在该桌面上。没有改变显示模式，没有注入输入或激活窗口。

**异步读取已通过 Windows 原生编译和四轮实际标记对照，但没有证明整体帧率提高或达到两帧延迟目标。** 同步与异步观察器均漏采桌面更新；下表是桌面标记的观察率，不是实际显示 FPS。`LastPresentTime` 是桌面呈现时间戳，不是屏幕光子时间，也不保证是该标记第一次出现的时间。

## 结果

| 轮次 | 原生 commit/s | 观察到的标记/s | 同步 copy+Map 等待中位 ms | 异步成功 Map+解码中位 μs | 捕获到被观察桌面的上界中位 ms |
|---|---:|---:|---:|---:|---:|
| 同步 A1 | 56.090 | 37.428 | 9.547 | — | 55.829 |
| 异步 B1 | 57.906 | 40.262 | — | 11 | 53.127 |
| 异步 B2 | 57.947 | 39.678 | — | 11 | 54.916 |
| 同步 A2 | 58.074 | 39.450 | 9.042 | — | 52.809 |

异步轮与最后一轮同步结果接近，不能从 A1 单独推出稳定的 FPS 增益。异步的 `copy_map_us` 中位仍为 **16.718 / 17.416 ms**：它包含 GPU 排队和延后检查，不能用成功 Map 的 11 μs 代替整段 readback 延迟。所有这些计时均为 QPC 壁钟区间，**不是采样得到的 CPU 消耗时间**。

两轮异步分别完成 804 / 785 次 acquisition，槽位使用峰值均为 2，遇到 GPU 尚未完成 1196 / 1213 次，最终未遗留或丢弃 pending 槽位。首张未形成有效标记的图像各拒绝一次；成功解码 803 / 784 次，其中标记变化 797 / 784 次。所有正数呈现时间戳与标记 ID 严格递增。

通过源端实际 GPU 标记、atlas frame、原生 commit 和桌面像素关联，异步轮分别得到 **788 / 784 个唯一身份样本**。B1 有 9 个源端重复捕获标记，已排除身份歧义；没有用近邻帧补配。全部唯一关联的 commit 在桌面观察时间之前，捕获延迟上界和 mutation→desktop 区间均无负值。逐帧记录位于各轮 `identity-pairs.json.gz`。

异步轮捕获→native mutation 的上界中位约 15.811 / 16.435 ms，mutation→被观察桌面中位约 36.265 / 37.657 ms。这个后半段包含 GPU 排队、合成和观察器漏采，不能全部归因于 DWM CPU，也不能仅凭这份测量断言真实首次显示延迟就是 53–55 ms。时钟原始交换逐条复算通过；两轮校准不确定度中位约 ±0.151 / ±0.155 ms。

## 实现与所有权

[`tools/windows_frame_observer.cpp`](../../../../tools/windows_frame_observer.cpp) 使用三个独立 staging 槽位。每个槽位保存其 acquisition 序号、`DXGI_OUTDUPL_FRAME_INFO`、采样坐标和 acquire 时间，按提交顺序读取；只有成功 Map、解码和 Unmap 后才可复用。尺寸变化不会覆盖其他 pending 槽位。

桌面资源的 Copy 命令在 `ReleaseFrame` 前发出，之后不再调用使用该桌面资源的图形操作；释放发生在下一次 Acquire 之前。`Flush` 只提交命令，**不表示 GPU 已完成**。只有 `Map(..., D3D11_MAP_FLAG_DO_NOT_WAIT, ...)` 成功后才读取像素；`DXGI_ERROR_WAS_STILL_DRAWING` 保留槽位并继续采集。槽位耗尽时暂缓新的 acquisition，不覆盖未完成拷贝。退出时有限等待已有 readback，并显式记录未完成数量；这仅是观察器收尾，不是远程会话退出策略。

以上契约对应 Microsoft 的 [Map 文档](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-map)、[ReleaseFrame 文档](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutputduplication-releaseframe)及 [Flush 文档](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-flush)。实际输出 `DesktopImageInSystemMemory=0`，不能通过直接 MapDesktopSurface 绕过 GPU 读取。

`physical4k` 观察模式现在允许至少能容纳 3840×2400 的桌面，且检查客户区确实为 3848×2408；名称沿用现有命令参数，不能据此宣称物理 4K 显示器测试。同步控制版本只做相同的放置与尺寸检查改动，保留原同步读取算法。两种版本使用相同 MSVC Release 参数编译，完整命令、源文件与二进制摘要已保存。

## 控制条件、失败记录与清理

四轮均暂时固定 Intel ESRV 进程为 Normal、已定位的线程为 Normal（base 8），每轮前后独立读回验证，避免把此前已复现的 TimeCritical 调度冲突混入观察器对照。测试有独立的定时恢复任务；结束后已验证恢复原进程 High、原线程 TimeCritical（base 15），服务继续 Running / Auto，恢复任务删除。此结果依赖临时控制条件，并不是当前常规服务已稳定达到 60 fps 的证明。

第一轮旧放置检查因没有恰好 3840×2400 的桌面而返回 `exit=14`。发现后终止了剩余对照，在下一轮创建 fixture 前使其显式失败并恢复优先级；保留在 `placement-failure/`，未列入性能结果。随后修正共同放置条件，从 A1 开始重做完整四轮；新 harness 同时检查观察器自身退出码和实际标记，避免仅凭视频进程成功判定测量成功。

测试收尾的 `windows-final-state.json` 验证隔离目录进程数和本轮临时任务数均为 0；Linux 临时输出已删除、原输出和焦点观测恢复一致。源端二进制、CUDA 实现、socket tracing 源文件，以及 Windows receiver / native presenter 摘要与上一轮一致。只有本观察工具和证据变更。Windows 原生构建成功，四轮观察器均 `exit=0`，视频 runner 无 watchdog，`git diff --check` 通过。旋转显示模式和设备丢失恢复没有在本轮实际触发。

保存补充时钟有效期检查后，再次查询原 PID 8108 时发现该进程已不存在，导致使用固定历史 PID 的保存脚本第二次查询失败。随后只读查询确认 ESRV 服务现为 PID 2344，仍 Running / Auto、High，隔离进程与临时任务仍为 0，所有相关二进制和源文件摘要一致；见 `windows-later-state.json`。新进程启动晚于四轮测试和成功恢复原设置的时间。本轮没有调用服务停止、启动、重启或终止该进程，原因未作归因，也未修改新进程。原恢复结果与稍后状态分别保留；后续对照必须重新解析当前进程和线程身份，不能复用 8108/10144。

原始压缩日志、分析脚本、唯一身份配对、构建脚本、临时优先级恢复记录及哈希清单共同提供复查依据。下一步仍需减少呈现路径等待，或取得更完整的首次呈现证据；不能把更换观察器当作完成 4K60 / ≤33.33 ms。
