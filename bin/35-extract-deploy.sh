#!/usr/bin/env bash
# 35 交付制品：解压数据盘里的 deploy_files.zip + FTP 增量同步
# 依赖：步骤 30 已完成（数据盘挂载到 DEPLOY_MOUNT）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
require_cmd unzip du find
step_banner 35 "交付制品解压与 FTP 同步"

# ---------- 单盘机器：整步跳过 ----------
if [[ "${DEPLOY_SKIP:-0}" == "1" ]]; then
  log_warn "DEPLOY_SKIP=1，跳过本步（单盘工控机无独立数据盘时按现场规范跳过）"
  log_ok "步骤 35 完成（已跳过）"
  exit 0
fi

require_vars DEPLOY_ZIP DEPLOY_DEST

DEPLOY_MOUNT="${DEPLOY_MOUNT:-${DATA_MOUNT:-}}"
DEPLOY_SUBDIR="${DEPLOY_SUBDIR:-deploy_files}"
EXTRACT_TARGET="${DEPLOY_DEST}/${DEPLOY_SUBDIR}"
MARKER="${DEPLOY_DEST}/.deploy_extracted"

# ---------- 前提一：数据盘必须真的挂上 ----------
if [[ -z "$DEPLOY_MOUNT" ]]; then
  die "未配置 DEPLOY_MOUNT（或 DATA_MOUNT），无法确认数据盘是否已挂载"
fi
if ! is_mounted "$DEPLOY_MOUNT"; then
  log_err "数据盘 ${DEPLOY_MOUNT} 未挂载，此刻解压会把制品写进根分区，占用系统盘空间"
  log_err "并且重启后制品会「消失」——因为数据盘挂到该目录后把它盖住了"
  die "请先执行：sudo ./bin/provision.sh -c ${CONF_FILE} -o 30"
fi
log_info "数据盘已挂载：$(findmnt -no SOURCE,TARGET,FSTYPE "$DEPLOY_MOUNT")"

# ---------- 前提二：制品包存在 ----------
if [[ ! -f "$DEPLOY_ZIP" ]]; then
  log_err "未找到制品包：${DEPLOY_ZIP}"
  log_info "常见原因："
  log_info "  1) 数据盘挂载点不是约定的 ${DEPLOY_MOUNT}，制品在别的目录"
  log_info "  2) 厂商镜像里没有带 zip，需要先从公司 FTP/SMB 拉取"
  log_info "  3) 路径写错，用 ls -alh ${DEPLOY_DEST} 确认"
  die "制品包不存在，已中止"
fi
log_info "制品包：${DEPLOY_ZIP}（$(du -h "$DEPLOY_ZIP" | cut -f1)）"

# ---------- 判断是否已解压过 ----------
already=0
if [[ -f "$MARKER" ]]; then
  already=1
elif [[ -d "$EXTRACT_TARGET" ]]; then
  # 没有 marker 但目录存在且非空，视为厂商镜像已自带解压结果
  n="$(find "$EXTRACT_TARGET" -type f 2>/dev/null | wc -l)"
  (( n > 0 )) && already=1
fi

if (( already == 1 )) && [[ "${DEPLOY_FORCE_EXTRACT:-0}" != "1" ]]; then
  log_info "检测到已解压内容：${EXTRACT_TARGET}"
  [[ -f "$MARKER" ]] && log_info "解压标记：$(cat "$MARKER")"
  log_warn "跳过解压。如需强制重新解压：DEPLOY_FORCE_EXTRACT=1"
else
  # ---------- 解压 ----------
  run mkdir -p "$DEPLOY_DEST"
  log_info "解压到：${DEPLOY_DEST}（约需数分钟，制品通常数 GB）"

  if [[ -n "${DEPLOY_ZIP_PASS:-}" ]]; then
    # 注意：-P 会把口令放进进程参数，同机其他用户短暂可见
    # 安全要求高的现场，把 DEPLOY_ZIP_PASS 留空，走下面的交互式输入
    run unzip -o -P "$DEPLOY_ZIP_PASS" "$DEPLOY_ZIP" -d "$DEPLOY_DEST"
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      log_warn "[dry-run] 将执行：unzip -o ${DEPLOY_ZIP} -d ${DEPLOY_DEST}（交互式输入口令）"
    else
      log_info "未配置 DEPLOY_ZIP_PASS，将进入 unzip 交互式口令输入"
      # 不加 -P，由 unzip 自己提示，口令不落命令行
      unzip -o "$DEPLOY_ZIP" -d "$DEPLOY_DEST" || die "解压失败（口令错误或包损坏）"
    fi
  fi

  # ---------- 解压结果校验 ----------
  if [[ "$DRY_RUN" != "1" ]]; then
    [[ -d "$EXTRACT_TARGET" ]] || die "解压完成但未找到 ${EXTRACT_TARGET}，请确认包内目录名是否为 ${DEPLOY_SUBDIR}"
    file_count="$(find "$EXTRACT_TARGET" -type f | wc -l)"
    [[ "$file_count" -ge "${DEPLOY_MIN_FILES:-1}" ]] \
      || die "解压后文件数异常（${file_count} 个），疑似包不完整"
    log_ok "解压完成：$(find "$EXTRACT_TARGET" -type f | wc -l) 个文件，$(du -sh "$EXTRACT_TARGET" | cut -f1)"

    # 关键子目录/文件校验（空格分隔的相对路径）
    if [[ -n "${DEPLOY_VERIFY_PATHS:-}" ]]; then
      for p in $DEPLOY_VERIFY_PATHS; do
        if [[ -e "${EXTRACT_TARGET}/${p}" ]]; then
          log_ok "校验通过：${p}"
        else
          log_err "校验失败：缺少 ${EXTRACT_TARGET}/${p}"
          CHECK_FAILED=$((CHECK_FAILED + 1))
        fi
      done
      (( CHECK_FAILED == 0 )) || die "解压内容与预期不符，已中止"
    fi

    printf 'extracted_at=%s\nzip=%s\nfiles=%s\n' \
      "$(date '+%F %T')" "$DEPLOY_ZIP" "$file_count" >"$MARKER"
    log_ok "已写入解压标记 ${MARKER}"
  fi
fi

# ---------- FTP 增量同步 ----------
if [[ -z "${FTP_HOST:-}" ]]; then
  log_info "未配置 FTP_HOST，跳过 FTP 同步"
  log_ok "步骤 35 完成"
  exit 0
fi

if ! has_cmd lftp; then
  log_warn "未安装 lftp，尝试安装"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y lftp \
    || die "安装 lftp 失败（现场多为内网，请从离线包安装后重试）"
fi

FTP_LOCAL_DIR="${FTP_LOCAL_DIR:-${EXTRACT_TARGET}}"
FTP_PARALLEL="${FTP_PARALLEL:-4}"
FTP_USER="${FTP_USER:-anonymous}"
FTP_PASS="${FTP_PASS:-}"

[[ -d "$FTP_LOCAL_DIR" ]] || die "本地同步目录不存在：${FTP_LOCAL_DIR}（必须先解压，FTP 才能找到落点）"

# mirror 的语义：以远端为准。远端有的补到本地，本地多出来的不删。
LFT_CMD="set net:max-retries 3; set net:timeout 20; mirror --verbose --continue --only-missing --ignore-time --parallel=${FTP_PARALLEL} ${FTP_REMOTE_DIR} ${FTP_LOCAL_DIR}; bye"

log_info "同步方向：ftp://${FTP_HOST}${FTP_REMOTE_DIR}  →  ${FTP_LOCAL_DIR}"
log_info "同步策略：--only-missing（只补缺失），--continue（断点续传），并行 ${FTP_PARALLEL}"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s         [dry-run] lftp -u %s,**** -e "mirror %s %s" ftp://%s%s\n' \
    "$C_YELLOW" "$FTP_USER" "$FTP_REMOTE_DIR" "$FTP_LOCAL_DIR" "$FTP_HOST" "$C_RESET"
else
  # 口令不写进日志
  log_cmd "lftp -u ${FTP_USER},**** -e \"<mirror ${FTP_REMOTE_DIR} ${FTP_LOCAL_DIR}>\" ftp://${FTP_HOST}"
  if [[ -n "$FTP_PASS" ]]; then
    lftp -u "${FTP_USER},${FTP_PASS}" -e "$LFT_CMD" "ftp://${FTP_HOST}" \
      || die "FTP 同步失败，检查 FTP_HOST / 账号口令 / 远端目录是否存在"
  else
    lftp -u "${FTP_USER}" -e "$LFT_CMD" "ftp://${FTP_HOST}" \
      || die "FTP 同步失败（可能需要口令，配置 FTP_PASS 或改用匿名账号）"
  fi

  synced="$(find "$FTP_LOCAL_DIR" -type f | wc -l)"
  log_ok "同步完成：本地共 ${synced} 个文件，$(du -sh "$FTP_LOCAL_DIR" | cut -f1)"

  if [[ -n "${FTP_MIN_FILES:-}" ]] && (( synced < FTP_MIN_FILES )); then
    log_err "文件数低于预期（${synced} < ${FTP_MIN_FILES}），远端目录可能不完整"
    die "FTP 同步结果校验失败"
  fi
fi

log_warn "现场提醒：解压必须在 FTP 同步之前完成，mirror 的落点就是解压出来的目录"
log_ok "步骤 35 完成"
