#!/usr/bin/env bash
# 40 依赖安装与时间同步
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
require_cmd apt-get
step_banner 40 "依赖安装与时间同步"

BASE_PACKAGES=(vim curl wget net-tools lsof htop unzip zip tar tcpdump rsync tree jq chrony)

# ---------- 软件源 ----------
if [[ -n "${APT_MIRROR:-}" ]]; then
  changed=0
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
    [[ -f "$f" ]] || continue
    if grep -qE '(archive|security)\.ubuntu\.com' "$f"; then
      backup_file "$f"
      run_sh "sed -i -E 's#https?://(archive|security)\.ubuntu\.com/ubuntu/?#${APT_MIRROR%/}#g' '$f'"
      changed=1
    fi
  done
  if [[ "$changed" == "1" ]]; then
    log_ok "已切换软件源为 ${APT_MIRROR}"
  else
    log_info "软件源无需修改"
  fi
else
  log_info "未配置 APT_MIRROR，保持现有软件源"
fi

# ---------- 安装依赖 ----------
log_info "更新软件包索引"
run apt-get update -y

log_info "安装基础依赖：${BASE_PACKAGES[*]}"
run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${BASE_PACKAGES[@]}"

if [[ -n "${EXTRA_PACKAGES:-}" ]]; then
  # shellcheck disable=SC2086
  log_info "安装额外依赖：${EXTRA_PACKAGES}"
  # shellcheck disable=SC2086
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y ${EXTRA_PACKAGES}
fi

# ---------- 时间同步 ----------
if [[ -n "${NTP_SERVERS:-}" ]]; then
  CHRONY_CONF=/etc/chrony/chrony.conf
  if [[ ! -f "$CHRONY_CONF" ]]; then
    log_warn "未找到 ${CHRONY_CONF}，跳过时间同步配置"
  else
    backup_file "$CHRONY_CONF"
    for s in $NTP_SERVERS; do
      ensure_line "$CHRONY_CONF" "server ${s} iburst"
    done
    run systemctl enable --now chrony
    run systemctl restart chrony
    sleep 3
    if [[ "$DRY_RUN" != "1" ]]; then
      log_info "当前时间源状态："
      chronyc sources -v 2>/dev/null | sed -n '1,12p' || true
      if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
        log_ok "时间已同步"
      else
        log_warn "尚未同步完成，内网 NTP 不可达时可暂不阻塞，但需在现场确认"
      fi
    fi
    log_warn "若为纯内网环境，建议手工注释 chrony.conf 中的 pool 行，避免对外网 NTP 的无谓等待"
  fi
else
  log_info "未配置 NTP_SERVERS，跳过时间同步"
fi

log_ok "步骤 40 完成"
