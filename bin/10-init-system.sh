#!/usr/bin/env bash
# 10 系统基础配置：主机名 / hosts / 时区
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
require_vars HOSTNAME TIMEZONE MGMT_IP
step_banner 10 "系统基础配置"

# ---------- 主机名 ----------
if [[ "$(hostname)" == "$HOSTNAME" ]]; then
  log_info "主机名已是 ${HOSTNAME}，跳过"
else
  run hostnamectl set-hostname "$HOSTNAME"
  log_ok "主机名已设置为 ${HOSTNAME}"
fi

# ---------- /etc/hosts ----------
if grep -qE "[[:space:]]${HOSTNAME//./\\.}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
  log_info "/etc/hosts 已包含 ${HOSTNAME}，跳过"
else
  backup_file /etc/hosts
  run_sh "printf '%s\t%s\n' '${MGMT_IP}' '${HOSTNAME}' >> /etc/hosts"
  log_ok "已写入 /etc/hosts：${MGMT_IP} ${HOSTNAME}"
fi

# ---------- 时区 ----------
current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
if [[ "$current_tz" == "$TIMEZONE" ]]; then
  log_info "时区已是 ${TIMEZONE}，跳过"
else
  run timedatectl set-timezone "$TIMEZONE"
  log_ok "时区已设置为 ${TIMEZONE}"
fi

log_ok "步骤 10 完成"
