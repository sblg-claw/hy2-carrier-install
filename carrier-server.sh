#!/usr/bin/env bash
# ============================================================================
# hy2-carrier-server.sh —— 海外承载端(hysteria2 QUIC server)
# ----------------------------------------------------------------------------
# 角色:四川中转 ↔ 海外之间 QUIC+brutal 隧道的「服务端」。
#       四川侧 hysteria2 client 用 tcpForwarding 把 anytls(TCP) 流量塞进 QUIC
#       隧道过境,本端(海外)收到后在本地 dial 到目标端口(现有 nginx/rel 转发入口
#       或最终落地),下游一切不动。
# 收益:跨境这一跳从裸 TCP 换成 QUIC + brutal 定速拥塞控制,晚高峰抗丢包。
#
# 用法:
#   PASSWORD=<隧道密码> LISTEN_PORT=46000 bash hy2-carrier-server.sh
#   (PASSWORD 留空则自动生成并在结尾打印;两端必须一致)
#
# 卸载:bash hy2-carrier-server.sh uninstall
# ============================================================================
set -euo pipefail

HY2_VER="${HY2_VER:-app/v2.12.2}"
LISTEN_PORT="${LISTEN_PORT:-46000}"        # QUIC/UDP 监听口(避开本机已用口 + 云 NSG/安全组放行)
PASSWORD="${PASSWORD:-}"                    # 隧道认证密码;留空自动生成
SNI="${SNI:-tunnel.hy2carrier}"            # 自签证书 CN/SNI(client 端要一致)
BIN=/usr/local/bin/hysteria
CFG_DIR=/etc/hy2carrier
UNIT=/etc/systemd/system/hy2carrier-server.service

[ "$(id -u)" = 0 ] || { echo "需 root 运行"; exit 1; }

if [ "${1:-}" = "uninstall" ]; then
  systemctl disable --now hy2carrier-server 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  rm -rf "$CFG_DIR"
  echo "已卸载 hy2carrier-server(保留 $BIN)"
  exit 0
fi

arch=$(uname -m); case "$arch" in
  x86_64) A=amd64;; aarch64) A=arm64;; *) echo "不支持的架构 $arch"; exit 1;; esac

[ -z "$PASSWORD" ] && PASSWORD=$(head -c18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c24)

# 1. 装 hysteria2 二进制(GitHub release 直下,失败则报错退出)
if [ ! -x "$BIN" ]; then
  url="https://github.com/apernet/hysteria/releases/download/${HY2_VER}/hysteria-linux-${A}"
  echo "[1/5] 下载 hysteria2: $url"
  curl -fsSL --retry 3 -o "$BIN" "$url"
  chmod +x "$BIN"
fi
echo -n "[1/5] hysteria 版本: "; "$BIN" version 2>/dev/null | awk '/^Version/{print $2}' | head -1

# 2. 自签证书(隧道自用,client 端 insecure:true)
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG_DIR/server.crt" ]; then
  echo "[2/5] 生成自签证书 CN=$SNI"
  openssl ecparam -genkey -name prime256v1 -out "$CFG_DIR/server.key" 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$CFG_DIR/server.key" \
    -out "$CFG_DIR/server.crt" -subj "/CN=${SNI}" 2>/dev/null
fi

# 3. server 配置
echo "[3/5] 写 server 配置 :$LISTEN_PORT"
cat > "$CFG_DIR/server.yaml" <<EOF
listen: :${LISTEN_PORT}
tls:
  cert: ${CFG_DIR}/server.crt
  key: ${CFG_DIR}/server.key
auth:
  type: password
  password: ${PASSWORD}
# brutal 拥塞控制由 client 侧 bandwidth 驱动,server 不覆盖(false=尊重 client 带宽声明)
ignoreClientBandwidth: false
EOF

# 4. systemd
echo "[4/5] 安装 systemd 单元 hy2carrier-server"
cat > "$UNIT" <<EOF
[Unit]
Description=hy2carrier QUIC carrier server
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=${BIN} server -c ${CFG_DIR}/server.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

# 4b. UDPspeeder FEC servers(分片并行,4 实例 47000-47003 → 本地 hy2 46000;churn 重建自动装回)
#     FEC key 复用 PASSWORD。SPEEDER_SERVERS=0 可关。
if [ "${SPEEDER_SERVERS:-4}" -gt 0 ] 2>/dev/null; then
  SPBIN=/usr/local/bin/speederv2
  if [ ! -x "$SPBIN" ]; then
    spurl="https://github.com/wangyu-/UDPspeeder/releases/download/20230206.0/speederv2_binaries.tar.gz"
    tmp=$(mktemp -d); curl -fsSL --retry 3 -o "$tmp/s.tgz" "$spurl" && tar xzf "$tmp/s.tgz" -C "$tmp" && cp "$tmp/speederv2_${A}" "$SPBIN" && chmod +x "$SPBIN"; rm -rf "$tmp"
  fi
  if [ -x "$SPBIN" ]; then
    for i in 0 1 2 3; do
      sp=$((47000+i))
      cat > /etc/systemd/system/udpspeeder-server-$i.service <<EOF
[Unit]
Description=UDPspeeder FEC server $i
After=network-online.target
[Service]
ExecStart=${SPBIN} -s -l0.0.0.0:${sp} -r127.0.0.1:${LISTEN_PORT} -f4:2 -k "${PASSWORD}" --mode 0 --timeout 8
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
      command -v ufw >/dev/null 2>&1 && ufw allow "${sp}/udp" >/dev/null 2>&1 || true
    done
  fi
fi

systemctl daemon-reload
[ "${SPEEDER_SERVERS:-4}" -gt 0 ] 2>/dev/null && systemctl enable --now udpspeeder-server-0 udpspeeder-server-1 udpspeeder-server-2 udpspeeder-server-3 >/dev/null 2>&1 || true
systemctl enable --now hy2carrier-server >/dev/null 2>&1 || systemctl restart hy2carrier-server

# 5. 本机防火墙(云厂商 NSG/安全组需另行放行 UDP)
command -v ufw >/dev/null 2>&1 && ufw allow "${LISTEN_PORT}/udp" >/dev/null 2>&1 || true
command -v firewall-cmd >/dev/null 2>&1 && { firewall-cmd --add-port="${LISTEN_PORT}/udp" --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; } || true

sleep 1
echo "[5/5] 服务状态: $(systemctl is-active hy2carrier-server)"
echo "=================================================================="
echo " 海外承载已部署"
echo "   QUIC 监听      : 0.0.0.0:${LISTEN_PORT}/udp"
echo "   隧道密码 PASSWORD = ${PASSWORD}"
echo "   SNI            = ${SNI}"
echo "   ⚠️ 云厂商 NSG/安全组务必放行 入站 UDP ${LISTEN_PORT}"
echo "   client 端用相同 PASSWORD / SNI 连  本机公网IP:${LISTEN_PORT}"
echo "=================================================================="
