# hy2-carrier-install
海外承载端(hysteria2 QUIC server)参数化安装脚本。**不含任何密码/密钥**。

## 用法
```
curl -fsSL https://raw.githubusercontent.com/sblg-claw/hy2-carrier-install/master/carrier-server.sh | PASSWORD='<隧道密码>' LISTEN_PORT=46000 SNI=tunnel.hy2carrier bash
```
卸载:末尾 `bash` 换成 `bash -s uninstall`。⚠️ 云 NSG/安全组需放行入站 UDP 端口。
