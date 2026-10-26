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

# ---------- 关闭 apt 自动更新（默认执行，与现场脚本一致） ----------
# 只 hold 内核拦不住自动升级：apt-daily.timer 每天跑 update + unattended-upgrade，
# 升级其它包后 needrestart 可能触发重启，一重启就暴露内核/驱动风险。
# 所以按现场脚本做四件事：卸包 → 停 timer → mask service → 重写周期配置。
if [[ "${KERNEL_DISABLE_AUTO_UPGRADE:-1}" == "1" ]]; then
  # 1) 卸载 unattended-upgrades（等价于现场脚本的 apt remove -y unattended-upgrades）
  if [[ "${KERNEL_REMOVE_UNATTENDED:-1}" == "1" ]]; then
    if dpkg -s unattended-upgrades >/dev/null 2>&1; then
      log_info "卸载 unattended-upgrades"
      run env DEBIAN_FRONTEND=noninteractive apt-get -y remove unattended-upgrades \
        || log_warn "卸载失败，稍后用 mask 方式兜底"
      log_ok "unattended-upgrades 已卸载"
    else
      log_info "unattended-upgrades 未安装，跳过卸载"
    fi
  elif svc_active unattended-upgrades; then
    run systemctl disable --now unattended-upgrades || log_warn "停用 unattended-upgrades 失败，请手工确认"
    log_ok "已停用 unattended-upgrades（按配置保留安装）"
  else
    log_info "unattended-upgrades 未运行，跳过"
  fi

  # 2) 停用 apt 每日定时器，并 mask 对应服务
  #    单 disable 不够：有些包的 postinst 会直接把 service start 起来，mask 后连手工启动都会被拒绝
  for unit in apt-daily.timer apt-daily-upgrade.timer; do
    if unit_exists "$unit"; then
      run systemctl disable --now "$unit" || log_warn "停用 ${unit} 失败"
      log_ok "已停用 ${unit}"
    else
      log_info "${unit} 不存在，跳过"
    fi
  done
  for unit in apt-daily.service apt-daily-upgrade.service; do
    if unit_exists "$unit"; then
      run systemctl mask "$unit" || log_warn "屏蔽 ${unit} 失败"
      log_ok "已屏蔽 ${unit}"
    else
      log_info "${unit} 不存在，跳过"
    fi
  done

  # 3) 重写周期配置：先删再写，顺手清掉旧文件里的其它周期项
  #    APT_CONF_DIR 仅用于测试/容器场景重定向，默认就是系统路径
  APT_CONF_DIR="${APT_CONF_DIR:-/etc/apt/apt.conf.d}"
  AUTO_UPGRADES="${APT_CONF_DIR}/20auto-upgrades"
  desired='APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";'
  if [[ -f "$AUTO_UPGRADES" ]] && [[ "$(cat "$AUTO_UPGRADES" 2>/dev/null)" == "$desired" ]]; then
    log_info "${AUTO_UPGRADES} 已是目标内容，无需重写"
  elif [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] 将重写 ${AUTO_UPGRADES}：Update-Package-Lists 0 / Unattended-Upgrade 0"
  else
    backup_file "$AUTO_UPGRADES"
    rm -f "$AUTO_UPGRADES"
    install -d -m 755 /etc/apt/apt.conf.d
    printf '%s\n' "$desired" >"$AUTO_UPGRADES"
    chmod 644 "$AUTO_UPGRADES"
    log_ok "已重写 ${AUTO_UPGRADES}（周期更新与无人值守升级均为 0）"
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

  # ---------- APT 自动更新状态（对应现场脚本最后那段 list-timers） ----------
  printf '\n%sAPT 自动更新状态%s\n' "$C_BLUE" "$C_RESET"
  if [[ "${KERNEL_DISABLE_AUTO_UPGRADE:-1}" == "1" ]]; then
    if dpkg -s unattended-upgrades >/dev/null 2>&1; then
      log_warn "unattended-upgrades 仍处于安装状态"
    else
      log_ok "unattended-upgrades 未安装"
    fi

    if systemctl list-timers --all 2>/dev/null | grep -q 'apt-daily'; then
      log_warn "仍有 apt-daily 定时器残留，请手工检查：systemctl list-timers --all | grep apt"
    else
      log_ok "无 apt-daily 定时器，自动更新已关闭"
    fi

    for unit in apt-daily.service apt-daily-upgrade.service; do
      unit_exists "$unit" || continue
      if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        log_warn "${unit} 未被 mask"
      else
        log_ok "${unit} 已屏蔽"
      fi
    done

    if grep -qs 'Unattended-Upgrade "0"' "${APT_CONF_DIR:-/etc/apt/apt.conf.d}/20auto-upgrades"; then
      log_ok "20auto-upgrades 周期升级已置 0"
    else
      log_warn "20auto-upgrades 内容不符合预期，请检查"
    fi
  fi
fi

log_ok "步骤 70 完成"
