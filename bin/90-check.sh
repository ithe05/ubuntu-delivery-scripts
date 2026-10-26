#!/usr/bin/env bash
# 90 交付自检：对照验收清单逐项检查，不通过则退出码非 0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
step_banner 90 "交付自检"

# ---------- 判定函数 ----------
_os_ok()      { . /etc/os-release && [[ "$ID" == "ubuntu" ]]; }
_hostname_ok(){ [[ "$(hostname)" == "$HOSTNAME" ]]; }
_ip_ok()      { ip -4 -o addr show 2>/dev/null | grep -qw "$MGMT_IP"; }
_gw_ok()      { ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; }
_mount_ok()   { is_mounted "$DATA_MOUNT"; }
_fstab_ok()   { grep -qE "^[^#]*[[:space:]]${DATA_MOUNT}[[:space:]]" /etc/fstab 2>/dev/null; }
_no_failed()  { [[ "$(systemctl --failed --no-legend 2>/dev/null | wc -l)" -eq 0 ]]; }
_ntp_ok()     { timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; }
_ssh_ok()     { systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; }
_disk_ok()    { local u; u="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"; [[ "${u:-100}" -lt 90 ]]; }
_frpc_ok()    { systemctl is-active --quiet frpc; }
_vnc_ok()     { ss -lnt 2>/dev/null | grep -q ":${VNC_PORT}[[:space:]]"; }
_deploy_files(){ local d="${DEPLOY_DEST:-}/${DEPLOY_SUBDIR:-deploy_files}"; [[ -d "$d" ]] && [[ "$(find "$d" -type f 2>/dev/null | wc -l)" -ge "${DEPLOY_MIN_FILES:-1}" ]]; }
_deploy_zip() { [[ -f "${DEPLOY_ZIP:-}" ]]; }
_kernel_hold(){ apt-mark showhold 2>/dev/null | grep -q '^linux-'; }
# 自动更新已关：无 apt-daily 定时器，且 unattended-upgrades 未安装或已停用
_apt_auto_off(){ systemctl list-timers --all 2>/dev/null | grep -q 'apt-daily' && return 1
                 dpkg -s unattended-upgrades >/dev/null 2>&1 && systemctl is-active --quiet unattended-upgrades && return 1
                 return 0; }

VNC_PORT=$((5900 + ${VNC_DISPLAY:-1}))

printf '%s系统层%s\n' "$C_BLUE" "$C_RESET"
check_item "系统为 Ubuntu"                        _os_ok
check_item "主机名与配置一致（$(hostname)）"      _hostname_ok
check_item "无 failed 的 systemd 单元"            _no_failed
check_item "SSH 服务运行中"                       _ssh_ok
check_item "根分区使用率低于 90%"                 _disk_ok

printf '\n%s网络层%s\n' "$C_BLUE" "$C_RESET"
check_item "管理 IP 已生效（${MGMT_IP}）"          _ip_ok
check_item "网关可达（${GATEWAY}）"               _gw_ok

printf '\n%s存储层%s\n' "$C_BLUE" "$C_RESET"
[[ -n "${DATA_MOUNT:-}" ]] && check_item "数据盘已挂载（${DATA_MOUNT}）"      _mount_ok
[[ -n "${DATA_MOUNT:-}" ]] && check_item "fstab 含持久化记录（${DATA_MOUNT}）" _fstab_ok

printf '\n%s交付制品%s\n' "$C_BLUE" "$C_RESET"
if [[ "${DEPLOY_SKIP:-0}" == "1" ]]; then
  log_info "DEPLOY_SKIP=1，按单盘机器跳过制品检查"
else
  check_item "制品包存在（${DEPLOY_ZIP:-未配置}）"                     _deploy_zip
  check_item "已解压且文件数达标（${DEPLOY_SUBDIR:-deploy_files}）"    _deploy_files
fi

printf '\n%s服务层%s\n' "$C_BLUE" "$C_RESET"
[[ -n "${NTP_SERVERS:-}" ]] && check_item "时间已同步" _ntp_ok
[[ -n "${FRP_SERVER_ADDR:-}" ]] && check_item "frpc 运行中" _frpc_ok
[[ -n "${VNC_USER:-}" ]] && check_item "VNC 端口监听（${VNC_PORT}）" _vnc_ok

printf '\n%s内核与驱动%s\n' "$C_BLUE" "$C_RESET"
check_item "内核已锁定（apt-mark hold）" _kernel_hold
check_item "APT 自动更新已关闭"          _apt_auto_off

# ---------- 汇总 ----------
printf '\n'
if (( CHECK_FAILED == 0 )); then
  log_ok "自检全部通过，可以进入业务部署与验收签署"
  exit 0
else
  log_err "自检未通过项：${CHECK_FAILED} 个，请逐项处理后重跑"
  log_info "常见修复：journalctl -u <服务> -n 50   /   systemctl status <服务>"
  exit 1
fi
