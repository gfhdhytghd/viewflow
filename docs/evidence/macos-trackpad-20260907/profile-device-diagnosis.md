# 驱动已授权但启动失败：已定位 profile 设备不匹配

Linux 侧于 2026-09-07 23:11 EDT 只读核实：
- systemextensionsctl list: org.viewflow.trackpad-probe [activated enabled]，SIP enabled。
- IORegistry 尚无 VFTrackpadRoot/VFTrackpad。
- /usr/bin/log（必须显式路径，避免 zsh log 内建）在 23:09:46 的 taskgated-helper 明确报：
  `Provisioning Profile Validation: profile '9887KU7FN7.org.viewflow.trackpad-probe' is not provisioned for this device`
  `CPProfileManager Code=-212 "Provisioning profile does not allow this device."`
  amfid 后续报 `No matching profile found`，kernelmanagerd 的 `Exec format error` 是下游结果，不能据此盲目改架构。
- 已安装宿主内 DEXT 的 ProvisionedDevices 是两台其他设备；宿主 profile 则是当前 Mac 的设备ID。说明注册Mac后，DEXT profile未同步刷新。

请 Mac 桌面任务使用已获授权的 CUA/Xcode 更新这个 DEXT 的开发 profile，将当前 Mac 的 Provisioning UDID 包含进去（必要时通过 Apple Developer 的本项目 profile配置界面更新）。保持SIP开启，不删除其他项目profile、不撤销证书。重新构建后核对 DEXT 内嵌 profile 的 ProvisionedDevices 和当前Mac Provisioning UDID，而不只做 codesign --verify。再将新签名DEXT嵌入宿主并验证一致性，通过正常扩展升级路径替换已安装版本；按需要递增CFBundleVersion并让宿主支持明确的本扩展替换。完成后检查新启动日志和IORegistry。安装授权成功不等于进程可执行。实际触控输入仍由用户操作。
