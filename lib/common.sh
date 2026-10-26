#!/usr/bin/env bash
# ============================================================
# lib/common.sh — 公共函数库
# 由 bin/*.sh 通过 source 引入，不单独执行
# ============================================================

if [[ -n "${_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
_COMMON_SH_LOADED=1

# ---------- 颜色（非终端环境自动降级为无色） ----------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[36m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''; C_RESET=''
fi

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# ---------- 日志 ----------
_log_init() {
  local dir="${LOG_DIR:-/var/log/provision}"
  if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
    dir="/tmp"
  fi
  if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="$dir/provision-$(date +%Y%m%d-%H%M%S).log"
  fi
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""
}
_log_init

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
  local level="$1" color="$2"; shift 2
  local msg="$*"
  if [[ "$DRY_RUN" == "1" && "$level" == "OK" ]]; then
    msg="${msg}  （dry-run 未执行）"
  fi
  printf '%s%s%s %s[%-5s]%s %s\n' "$C_DIM" "$(_ts)" "$C_RESET" "$color" "$level" "$C_RESET" "$msg"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s [%-5s] %s\n' "$(_ts)" "$level" "$msg" >>"$LOG_FILE"
  fi
}

log_info() { _log INFO  "$C_BLUE"   "$@"; }
log_ok()   { _log OK    "$C_GREEN"  "$@"; }
log_warn() { _log WARN  "$C_YELLOW" "$@"; }
log_err()  { _log ERROR "$C_RED"    "$@"; }

die() { log_err "$@"; exit 1; }

log_cmd() {
  printf '%s         $ %s%s\n' "$C_DIM" "$*" "$C_RESET"
  [[ -n "${LOG_FILE:-}" ]] && printf '           $ %s\n' "$*" >>"$LOG_FILE"
  return 0
}

step_banner() {
  local no="$1" title="$2"
  printf '\n%s━━━━━━  [%s] %s  ━━━━━━%s\n' "$C_BLUE" "$no" "$title" "$C_RESET"
  [[ -n "${LOG_FILE:-}" ]] && printf '\n===== [%s] %s =====\n' "$no" "$title" >>"$LOG_FILE"
}

on_error() {
  local line="$1"
  log_err "执行失败（第 ${line} 行）：${BASH_COMMAND}"
  log_err "完整日志：${LOG_FILE:-N/A}"
  log_err "已中止。修复后可直接重跑，脚本幂等，已完成步骤会自动跳过。"
  exit 1
}

# ---------- 执行封装（支持 dry-run） ----------
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s         [dry-run] %s%s\n' "$C_YELLOW" "$*" "$C_RESET"
    return 0
  fi
  log_cmd "$*"
  "$@"
}

# 需要管道、重定向等 shell 语法时使用
run_sh() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s         [dry-run] %s%s\n' "$C_YELLOW" "$1" "$C_RESET"
    return 0
  fi
  log_cmd "$1"
  bash -c "$1"
}

# ---------- 交互与校验 ----------
confirm() {
  local prompt="${1:-确认继续？}"
  if [[ "$ASSUME_YES" == "1" ]]; then
    log_warn "$prompt   → 已通过 -y 自动确认"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "$prompt   → dry-run 跳过确认"
    return 0
  fi
  local ans=""
  read -r -p "${prompt} [y/N] " ans </dev/tty || ans=""
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "需要 root 权限执行，请使用 sudo"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c（请先安装）"
  done
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_vars() {
  local v missing=()
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} > 0 )); then
    die "配置缺少必填项：${missing[*]}（请检查 conf 文件）"
  fi
}

# ---------- 文件与配置 ----------
load_conf() {
  local f="${1:-}"
  [[ -n "$f" ]] || die "未指定配置文件"
  [[ -f "$f" ]] || die "配置文件不存在：$f"
  # shellcheck disable=SC1090
  set -a
  source "$f"
  set +a
  log_info "已加载配置：$f"
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local b="${f}.bak.$(date +%Y%m%d%H%M%S)"
  run cp -a "$f" "$b"
  log_info "已备份 $f → $b"
}

# 幂等追加一行（已存在则跳过）
ensure_line() {
  local file="$1" line="$2"
  [[ "$DRY_RUN" != "1" ]] && touch "$file"
  if [[ "$DRY_RUN" != "1" ]] && grep -qxF -- "$line" "$file" 2>/dev/null; then
    log_info "已存在，跳过：$file"
    return 0
  fi
  run_sh "printf '%s\n' $(printf '%q' "$line") >> $(printf '%q' "$file")"
  log_ok "已写入：$file"
}

# ---------- 系统状态判断 ----------
is_mounted() { mountpoint -q "$1"; }

svc_active() { systemctl is-active --quiet "$1"; }

# systemd 单元是否存在（用于区分「不存在」和「未启用」）
unit_exists() {
  systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q "^${1}[[:space:]]"
}

# ---------- 验收检查 ----------
CHECK_FAILED=0

check_pass() {
  printf '%s  [PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
  [[ -n "${LOG_FILE:-}" ]] && printf '  [PASS] %s\n' "$*" >>"$LOG_FILE"
}

check_fail() {
  printf '%s  [FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"
  [[ -n "${LOG_FILE:-}" ]] && printf '  [FAIL] %s\n' "$*" >>"$LOG_FILE"
  CHECK_FAILED=$((CHECK_FAILED + 1))
}

check_item() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    check_pass "$desc"
  else
    check_fail "$desc"
  fi
}
