#!/usr/bin/env bash
# 50 VNC 远程桌面：tigervnc + systemd 托管，仅监听 127.0.0.1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
require_vars VNC_USER VNC_PASSWORD VNC_GEOMETRY VNC_DISPLAY
step_banner 50 "VNC 远程桌面"

(( ${#VNC_PASSWORD} >= 8 )) || die "VNC_PASSWORD 至少 8 位"

id "$VNC_USER" >/dev/null 2>&1 || die "用户不存在：${VNC_USER}"
VNC_HOME="$(getent passwd "$VNC_USER" | cut -d: -f6)"
VNC_PORT=$((5900 + VNC_DISPLAY))

# ---------- 桌面环境检查 ----------
if ! has_cmd startxfce4 && ! has_cmd gnome-session && ! has_cmd startlxde; then
  log_warn "未检测到常见桌面环境（xfce / gnome / lxde）"
  log_warn "如需图形界面请先安装：apt install -y xfce4 xfce4-goodies"
fi

# ---------- 安装 ----------
run env DEBIAN_FRONTEND=noninteractive apt-get install -y tigervnc-standalone-server

# ---------- VNC 密码 ----------
if [[ "$DRY_RUN" != "1" ]]; then
  umask 077
  tmpw="$(mktemp)"
  printf '%s\n' "$VNC_PASSWORD" >"$tmpw"
  install -d -m 700 -o "$VNC_USER" -g "$VNC_USER" "$VNC_HOME/.vnc"
  sudo -u "$VNC_USER" bash -c "vncpasswd -f < '$tmpw' > '$VNC_HOME/.vnc/passwd'"
  chmod 600 "$VNC_HOME/.vnc/passwd"
  chown "$VNC_USER:$VNC_USER" "$VNC_HOME/.vnc/passwd"
  rm -f "$tmpw"
  log_ok "VNC 密码已设置（文件：${VNC_HOME}/.vnc/passwd，权限 600）"
fi

# ---------- 用户级 config ----------
VNC_CONFIG="$VNC_HOME/.vnc/config"
desired_config="geometry=${VNC_GEOMETRY}
depth=24
localhost=yes"
if [[ -f "$VNC_CONFIG" ]] && [[ "$(cat "$VNC_CONFIG")" == "$desired_config" ]]; then
  log_info "~/.vnc/config 已存在且内容一致，跳过"
else
  if [[ "$DRY_RUN" != "1" ]]; then
    backup_file "$VNC_CONFIG"
    printf '%s\n' "$desired_config" >"$VNC_CONFIG"
    chown "$VNC_USER:$VNC_USER" "$VNC_CONFIG"
    chmod 644 "$VNC_CONFIG"
  fi
  log_ok "已写入 ~/.vnc/config"
fi

# ---------- systemd 单元 ----------
UNIT=/etc/systemd/system/vncserver@.service
if [[ -f "$UNIT" ]]; then
  log_info "已存在 ${UNIT}，跳过写入"
else
  if [[ "$DRY_RUN" != "1" ]]; then
    cat >"$UNIT" <<EOF
[Unit]
Description=TigerVNC Server on display %i
After=network.target

[Service]
Type=forking
User=${VNC_USER}
PAMName=login

ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver :%i -geometry ${VNC_GEOMETRY} -depth 24 -localhost yes
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT"
  fi
  log_ok "已写入 ${UNIT}"
fi

run systemctl daemon-reload
run systemctl enable --now "vncserver@${VNC_DISPLAY}.service"

# ---------- 验证 ----------
if [[ "$DRY_RUN" != "1" ]]; then
  sleep 2
  if svc_active "vncserver@${VNC_DISPLAY}.service"; then
    log_ok "VNC 服务运行中（:${VNC_DISPLAY}）"
  else
    log_err "VNC 服务未启动，检查：journalctl -u vncserver@${VNC_DISPLAY}.service -n 50"
    die "VNC 启动失败"
  fi

  if ss -lntp 2>/dev/null | grep -q ":${VNC_PORT}[[:space:]]"; then
    log_ok "端口 ${VNC_PORT} 已监听"
    if ss -lntp 2>/dev/null | grep ":${VNC_PORT}[[:space:]]" | grep -qv '127.0.0.1'; then
      log_warn "检测到 ${VNC_PORT} 监听在非 127.0.0.1 地址，存在暴露风险，请检查"
    fi
  else
    die "端口 ${VNC_PORT} 未监听"
  fi

  log_info "连接方式（推荐 SSH 隧道）："
  log_info "  ssh -L ${VNC_PORT}:127.0.0.1:${VNC_PORT} ${VNC_USER}@<跳板机>"
  log_info "  vncviewer 127.0.0.1:${VNC_PORT}"
fi

log_ok "步骤 50 完成"
