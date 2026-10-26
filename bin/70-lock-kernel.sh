#!/usr/bin/env bash
# 70 固定内核与驱动：阻止内核/头文件被自动升级，避免厂商驱动失效
#
# 为什么要做这一步：
#   工控机上的显卡、采集卡、串口卡驱动依赖当前内核版本（dkms 编译或厂商 .deb）。
#   apt 自动升级一旦把 linux-image 拉高一个小版本，重启后模块编译失败或签名不匹配，
#   表现是花屏、黑屏、VNC 进不去，而且现场没有显示器时几乎无法自查。
#   所以交付前必须把内核锁死，把「上次能跑的那套」固定下来。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
require_cmd apt-mark
step_banner 70 "固定内核与驱动"

RUNNING_KERNEL="$(uname -r)"
log_info "当前运行内核：${RUNNING_KERNEL}"

# ---------- 待锁定的包 ----------
# 默认锁定：运行中内核的 image/headers/modules + 元包（元包被升级会连带拉新内核）
DEFAULT_PKGS=(
  "linux-image-${RUNNING_KERNEL}"
  "linux-headers-${RUNNING_KERNEL}"
  "linux-modules-${RUNNING_KERNEL}"
  "linux-modules-extra-${RUNNING_KERNEL}"
  "linux-generic"
  "linux-image-generic"
  "linux-headers-generic"
  "linux-signed-generic"
)
# 配置项可覆盖：KERNEL_HOLD_PACKAGES="包1 包2"
if [[ -n "${KERNEL_HOLD_PACKAGES:-}" ]]; then
  # shellcheck disable=SC2206
  TARGETS=(${KERNEL_HOLD_PACKAGES})
  log_info "使用配置指定要锁定的包（KERNEL_HOLD_PACKAGES）"
else
  TARGETS=("${DEFAULT_PKGS[@]}")
fi

# ---------- 只锁真正装了的包，不锁不存在的 ----------
installed=()
skipped=()
for p in "${TARGETS[@]}"; do
  if dpkg -s "$p" >/dev/null 2>&1; then
    installed+=("$p")
  else
    skipped+=("$p")
  fi
done

if (( ${#installed[@]} == 0 )); then
  die "没有找到任何可锁定的内核包，请手动确认：dpkg -l | grep linux-image"
fi

(( ${#skipped[@]} > 0 )) && log_info "本机未安装、已跳过：${skipped[*]}"

# ---------- 已是 hold 状态则不重复操作 ----------
current_hold="$(apt-mark showhold 2>/dev/null || true)"
todo=()
for p in "${installed[@]}"; do
  if grep -qxF "$p" <<<"$current_hold"; then
    log_info "已锁定，跳过：${p}"
  else
    todo+=("$p")
  fi
done

if (( ${#todo[@]} > 0 )); then
  log_info "即将锁定：${todo[*]}"
  run apt-mark hold "${todo[@]}"
  log_ok "已锁定 ${#todo[@]} 个内核相关包"
else
  log_ok "所有目标内核包均已处于锁定状态，无需变更"
fi

# ---------- 关闭自动升级（可选，默认开） ----------
if [[ "${KERNEL_DISABLE_AUTO_UPGRADE:-1}" == "1" ]]; then
  if systemctl list-unit-files 2>/dev/null | grep -q '^unattended-upgrades.service'; then
    if svc_active unattended-upgrades; then
      log_warn "unattended-upgrades 正在运行，将停止并禁用（仅锁内核不够，它仍会升级其它包并可能重启）"
      run systemctl disable --now unattended-upgrades || log_warn "停止 unattended-upgrades 失败，请手工确认"
      log_ok "已禁用 unattended-upgrades"
    else
      log_info "unattended-upgrades 未运行，跳过"
    fi
  else
    log_info "本机未安装 unattended-upgrades，跳过"
  fi

  AUTO_UPGRADES=/etc/apt/apt.conf.d/20auto-upgrades
  if [[ -f "$AUTO_UPGRADES" ]] && grep -qE 'Unattended-Upgrade[[:space:]]+"1"' "$AUTO_UPGRADES"; then
    backup_file "$AUTO_UPGRADES"
    run_sh "sed -i -E 's/(Unattended-Upgrade[[:space:]]+)\"1\"/\\1\"0\"/' '$AUTO_UPGRADES'"
    log_ok "已关闭 apt 周期自动升级（${AUTO_UPGRADES}）"
  else
    log_info "${AUTO_UPGRADES} 未开启周期升级，无需修改"
  fi
fi

# ---------- 验证 ----------
if [[ "$DRY_RUN" != "1" ]]; then
  printf '\n%s当前 hold 列表%s\n' "$C_BLUE" "$C_RESET"
  apt-mark showhold 2>/dev/null | sed 's/^/  /' || true

  held_kernel="$(apt-mark showhold 2>/dev/null | grep -c '^linux-' || true)"
  if (( held_kernel > 0 )); then
    log_ok "内核已锁定（${held_kernel} 个包），升级不会替换当前内核"
  else
    die "未检测到任何 linux-* 处于 hold 状态，请检查 apt-mark 输出"
  fi

  log_warn "已锁定的内核不会被升级。将来要升级内核，必须先：apt-mark unhold <包名> 再升级，"
  log_warn "并在升级后重新验证显卡/采集卡驱动（nvidia-smi / dmesg | grep -i 驱动名），否则不要重启"
fi

log_ok "步骤 70 完成"
