# 配置自检（viewflowd doctor）

`viewflowd doctor` 只读检查常见配置错误，并为每一项给出修复提示。它不注入输入、
不切换焦点、不修改身份文件。存在 `[FAIL]` 时退出码非零，便于脚本和服务管理器判断。

```sh
viewflowd doctor --cert peer.pem --key peer.key --ca ca.pem \
  --bind 0.0.0.0:4433 --peer 192.168.1.20:4433 --server-name paired-device
viewflowd doctor ... --format json   # 供桌面应用解析
```

| 检查 | 能识别的问题 |
| --- | --- |
| identity | 文件缺失或无权限读取、PEM 互换、私钥与证书不配对、证书不属于该配对 CA、证书过期或本机时钟偏差、14 天内到期、私钥可被其他用户读取 |
| bind | UDP 端口被另一实例占用、IP 不属于本机、低端口无权限 |
| peer | 无响应（服务未运行或防火墙）、`--server-name` 与证书名不符、两端配对 CA 不同、对端拒绝本机证书、版本不兼容 |
| 平台 | macOS 辅助功能权限；Linux 图形会话环境变量 |

peer 检查会完成一次正常的双向认证握手后立即以 `doctor` 原因关闭，不建立会话。
