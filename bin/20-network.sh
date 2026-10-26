#!/usr/bin/env bash
# 20 网络配置：netplan 静态 IP（支持 VLAN）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
require_vars MGMT_IFACE MGMT_IP MGMT_PREFIX_LEN GATEWAY DNS_SERVERS
require_cmd ip netplan
step_banner 20 "网络配置"

TARGET_IFACE="$MGMT_IFACE"
[[ -n "${VLAN_ID:-}" ]] && TARGET_IFACE="${MGMT_IFACE}.${VLAN_ID}"

if ! ip link show "$MGMT_IFACE" >/dev/null 2>&1; then
  log_err "网卡不存在：${MGMT_IFACE}"
  log_err "可用网卡：$(ip -br link | awk '{print $1}' | tr '\n' ' ')"
  die "请修正 conf 中的 MGMT_IFACE"
fi

# ---------- 组装 DNS 列表 ----------
dns_yaml=""
IFS=',' read -r -a dns_arr <<<"$DNS_SERVERS"
for d in "${dns_arr[@]}"; do
  d="${d// /}"
  [[ -z "$d" ]] && continue
  dns_yaml+="${dns_yaml:+, }${d}"
done
[[ -n "$dns_yaml" ]] || die "DNS_SERVERS 解析为空"

# ---------- 渲染 YAML ----------
NETPLAN_FILE="/etc/netplan/99-provision.yaml"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [[ -z "${VLAN_ID:-}" ]]; then
  cat >"$tmp" <<EOF
# 由 ubuntu-delivery-scripts 生成，请勿手工修改
network:
  version: 2
  renderer: networkd
  ethernets:
    ${MGMT_IFACE}:
      dhcp4: false
      optional: true
      addresses: [${MGMT_IP}/${MGMT_PREFIX_LEN}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${dns_yaml}]
EOF
else
  cat >"$tmp" <<EOF
# 由 ubuntu-delivery-scripts 生成，请勿手工修改
network:
  version: 2
  renderer: networkd
  ethernets:
    ${MGMT_IFACE}:
      dhcp4: false
      optional: true
  vlans:
    ${TARGET_IFACE}:
      id: ${VLAN_ID}
      link: ${MGMT_IFACE}
      dhcp4: false
      addresses: [${MGMT_IP}/${MGMT_PREFIX_LEN}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${dns_yaml}]
EOF
fi

log_info "目标接口：${TARGET_IFACE}  地址：${MGMT_IP}/${MGMT_PREFIX_LEN}  网关：${GATEWAY}"

if [[ "$DRY_RUN" != "1" ]]; then
  backup_file "$NETPLAN_FILE"
  install -m 600 -o root -g root "$tmp" "$NETPLAN_FILE"
  log_ok "已写入 ${NETPLAN_FILE}"
  run netplan generate
fi

# ---------- 应用 ----------
if [[ "${NETPLAN_APPLY:-1}" != "1" ]]; then
  log_warn "NETPLAN_APPLY=0，仅生成配置未应用"
  log_warn "确认无误后执行：sudo netplan try"
  log_ok "步骤 20 完成（未应用）"
  exit 0
fi

log_warn "即将应用网络配置，SSH 连接可能中断"
log_warn "请确认已具备 BMC 带外或 VNC 通道作为兜底"
confirm "确认应用网络配置？" || die "已取消，配置已写入但未应用"

run netplan apply

# ---------- 验证 ----------
sleep 2
if ip -4 addr show dev "$TARGET_IFACE" 2>/dev/null | grep -qw "$MGMT_IP"; then
  log_ok "地址已生效：${MGMT_IP}"
else
  log_err "地址未生效，请通过 BMC / VNC 登录检查"
  die "网络配置应用失败"
fi

if ping -c 2 -W 2 "$GATEWAY" >/dev/null 2>&1; then
  log_ok "网关可达：${GATEWAY}"
else
  log_warn "网关不可达：${GATEWAY}，请检查 VLAN / 交换机端口 / 网关地址"
fi

log_ok "步骤 20 完成"
