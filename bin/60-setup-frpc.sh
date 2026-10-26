#!/usr/bin/env bash
# 60 frp 内网穿透：frpc 配置 + systemd 托管
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
require_vars FRP_SERVER_ADDR FRP_SERVER_PORT FRP_TOKEN FRP_REMOTE_PORT FRP_LOCAL_PORT
step_banner 60 "frp 内网穿透"

# ---------- 二进制 ----------
if ! has_cmd frpc && [[ ! -x /usr/local/bin/frpc ]]; then
  log_err "未找到 frpc 可执行文件"
  log_err "安装方式（按现场网络选择其一）："
  log_err "  1) 离线包：tar -xzf frp_*.tar.gz -C /tmp && install -m755 /tmp/frp_*/frpc /usr/local/bin/frpc"
  log_err "  2) 在线：wget https://github.com/fatedier/frp/releases/download/<ver>/frp_<ver>_linux_amd64.tar.gz"
  die "请先安装 frpc 后重试"
fi
FRPC_BIN="$(command -v frpc || echo /usr/local/bin/frpc)"

# ---------- 配置 ----------
FRP_DIR=/etc/frp
FRP_CONF="$FRP_DIR/frpc.toml"
run install -d -m 755 "$FRP_DIR"

if [[ "$DRY_RUN" != "1" ]]; then
  backup_file "$FRP_CONF"
  umask 077
  cat >"$FRP_CONF" <<EOF
# 由 ubuntu-delivery-scripts 生成
serverAddr = "${FRP_SERVER_ADDR}"
serverPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

log.to = "/var/log/frpc.log"
log.level = "info"
log.maxDays = 7

[[proxies]]
name = "$(hostname)-${FRP_REMOTE_PORT}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${FRP_LOCAL_PORT}
remotePort = ${FRP_REMOTE_PORT}
EOF
  chmod 600 "$FRP_CONF"
  log_ok "已写入 ${FRP_CONF}（权限 600，含 token）"
fi

# ---------- systemd ----------
UNIT=/etc/systemd/system/frpc.service
if [[ "$DRY_RUN" != "1" ]]; then
  cat >"$UNIT" <<EOF
[Unit]
Description=frp client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRPC_BIN} -c ${FRP_CONF}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
  log_ok "已写入 ${UNIT}"
fi

run systemctl daemon-reload
run systemctl enable --now frpc

# ---------- 验证 ----------
if [[ "$DRY_RUN" != "1" ]]; then
  sleep 2
  if svc_active frpc; then
    log_ok "frpc 运行中"
  else
    log_err "frpc 未启动，日志如下："
    journalctl -u frpc -n 30 --no-pager || true
    die "frpc 启动失败"
  fi

  if journalctl -u frpc -n 50 --no-pager 2>/dev/null | grep -qi "start proxy success"; then
    log_ok "已成功建立映射：${FRP_REMOTE_PORT} ← 127.0.0.1:${FRP_LOCAL_PORT}"
  else
    log_warn "未在日志中看到 start proxy success，请检查 token / 端口 / 服务端可达性"
  fi
fi

log_warn "服务端必须做的一件事：仅允许跳板机访问 ${FRP_REMOTE_PORT}"
log_info "  # frps 所在主机"
log_info "  ufw allow from <跳板机IP> to any port ${FRP_REMOTE_PORT} proto tcp"
log_info "客户端连接：vncviewer ${FRP_SERVER_ADDR}:${FRP_REMOTE_PORT}（仅跳板机可达）"

log_ok "步骤 60 完成"
