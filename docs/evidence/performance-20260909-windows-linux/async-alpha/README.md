# 异步alpha初版：已拒绝的性能回归

独立6K测试副本，未应用。AlphaPlane增加四槽staging＋GPU event query，完成后以DO_NOT_WAIT读取；颜色和alpha按同一PTS合并，并按序输出。64×32与6144×3456各两轮四种alpha的GPU精确检查均通过，队列满返回S_FALSE且保留原帧，复用后像素和标签正确。

**完整源端试跑失败，不能作为优化结果。** 仅输出15帧，稳态约0.307FPS；测试结束后源进程未在5秒内退出，runner以124终止。fixture正常退出，所有测试进程均已清理，主程序哈希未变。

已输出的15条记录能全部经Linux GPU解码并验证互补帧标记，GL错误0。但alpha等待随运行增长至数秒；主循环在编码器未接收输入时，仍先清空／复制atlas，再得到S_FALSE。原先同步Map带来的停顿掩盖了这个重复提交路径；改为异步后每毫秒重试增加无效GPU工作。

后续`async-alpha-ready`副本将编码器就绪检查前移至atlas合成之前，保持现有颜色／alpha内容与顺序。该因果判断仍须通过修正后的真实试跑验证。`summary.json`明确标记`run_qualified=false`，所有时序仅作失败诊断。
