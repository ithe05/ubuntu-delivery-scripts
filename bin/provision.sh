#!/usr/bin/env bash
# ============================================================
# bin/provision.sh — 交付流程主入口
# 按顺序调用各步骤脚本，支持步骤挑选与 dry-run
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
用法: sudo ./bin/provision.sh -c <配置> [选项]

参数:
  -c <file>   配置文件路径，如 conf/node31.env（必填）
  -o <steps>  只执行指定步骤，逗号分隔，如 -o 20,30
  -n          dry-run，只打印将要执行的命令，不做任何修改
  -y          所有确认自动回答 yes（危险操作仍建议逐条确认）
  -h          显示本帮助

步骤:
  10  系统基础配置（主机名 / hosts / 时区）
  20  网络配置（netplan 静态 IP）
  30  数据盘挂载（格式化 / UUID 写入 fstab）
  35  交付制品（解压 deploy_files.zip + FTP 增量同步）  ← 依赖 30
  40  依赖安装与时间同步（apt 源 / 基础工具 / unzip / lftp / chrony）
  50  VNC 远程桌面（tigervnc + systemd）
  60  frp 内网穿透（frpc 配置 + systemd）
  70  固定内核与驱动（apt-mark hold，防驱动失效）
  90  交付自检（对照验收清单逐项检查）

现场典型顺序：10,20,30 → 35 → 40 → 50,60 → 70 → 90
（35 放在 30 之后是因为制品必须落在已挂载的数据盘上）

示例:
  sudo ./bin/provision.sh -c conf/node31.env -n        # 先空跑看一遍
  sudo ./bin/provision.sh -c conf/node31.env -o 10,20  # 只做前两步
  sudo ./bin/provision.sh -c conf/node31.env           # 全流程
EOF
}

CONF=""
ONLY=""

while getopts ":c:o:nyh" opt; do
  case "$opt" in
    c) CONF="$OPTARG" ;;
    o) ONLY="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    \?) log_err "未知选项：-$OPTARG"; usage; exit 2 ;;
    :)  log_err "选项 -$OPTARG 需要参数"; usage; exit 2 ;;
  esac
done

[[ -n "$CONF" ]] || { usage; exit 2; }
[[ -f "$CONF" ]] || die "配置文件不存在：$CONF"

# 转为绝对路径，避免子脚本 cd 后失效
CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"

STEPS=(
  "10:init-system:系统基础配置"
  "20:network:网络配置"
  "30:mount-data:数据盘挂载"
  "35:extract-deploy:交付制品解压与 FTP 同步"
  "40:install-deps:依赖安装与时间同步"
  "50:setup-vnc:VNC 远程桌面"
  "60:setup-frpc:frp 内网穿透"
  "70:lock-kernel:固定内核与驱动"
  "90:check:交付自检"
)

selected() {
  local no="$1"
  [[ -z "$ONLY" ]] && return 0
  [[ ",${ONLY}," == *",${no},"* ]]
}

main() {
  require_root

  printf '\n%s╔══════════════════════════════════════════════════╗%s\n' "$C_BLUE" "$C_RESET"
  printf '%s║  Ubuntu 服务器标准化交付                          ║%s\n' "$C_BLUE" "$C_RESET"
  printf '%s╚══════════════════════════════════════════════════╝%s\n' "$C_BLUE" "$C_RESET"
  log_info "主机：$(hostname)  系统：$(. /etc/os-release && echo "$PRETTY_NAME")"
  log_info "配置：$CONF"
  log_info "日志：${LOG_FILE:-N/A}"
  [[ "$DRY_RUN" == "1" ]] && log_warn "当前为 dry-run 模式，不会产生任何修改"
  [[ -n "$ONLY" ]] && log_info "仅执行步骤：$ONLY"
  echo

  export CONF_FILE="$CONF"
  export DRY_RUN ASSUME_YES LOG_FILE

  local item no script title start=$SECONDS
  for item in "${STEPS[@]}"; do
    IFS=':' read -r no script title <<<"$item"
    selected "$no" || continue
    bash "$SCRIPT_DIR/${no}-${script}.sh"
  done

  local cost=$((SECONDS - start))
  printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_BLUE" "$C_RESET"
  log_ok "交付流程结束，耗时 ${cost}s"
  log_info "日志已保存：${LOG_FILE:-N/A}"
  if [[ -z "$ONLY" || "$ONLY" != *"90"* ]]; then
    log_warn "建议执行自检：sudo ./bin/provision.sh -c $CONF -o 90"
  fi
}

main "$@"
