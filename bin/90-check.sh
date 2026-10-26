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

printf '\n%s服务层%s\n' "$C_BLUE" "$C_RESET"
[[ -n "${NTP_SERVERS:-}" ]] && check_item "时间已同步" _ntp_ok
[[ -n "${FRP_SERVER_ADDR:-}" ]] && check_item "frpc 运行中" _frpc_ok
[[ -n "${VNC_USER:-}" ]] && check_item "VNC 端口监听（${VNC_PORT}）" _vnc_ok

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
