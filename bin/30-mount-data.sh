#!/usr/bin/env bash
# 30 数据盘挂载：格式化 / 写入 fstab（UUID）/ 挂载验证
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR

load_conf "${CONF_FILE:?}"
require_vars DATA_DEVICE DATA_MOUNT DATA_FSTYPE
require_cmd lsblk blkid findmnt
step_banner 30 "数据盘挂载"

FSTAB=/etc/fstab

# ---------- 安全检查：不能是系统盘 ----------
[[ -e "$DATA_DEVICE" ]] || die "设备不存在：${DATA_DEVICE}（用 lsblk -f 确认）"

root_src="$(findmnt -no SOURCE /)"
root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
data_disk="$(lsblk -no PKNAME "$DATA_DEVICE" 2>/dev/null || true)"
data_disk="${data_disk:-$(basename "$DATA_DEVICE")}"
[[ -n "$root_disk" ]] && [[ "$data_disk" == "$root_disk" ]] \
  && die "数据盘 ${DATA_DEVICE} 与系统盘属于同一块物理盘（${root_disk}），已中止"

# ---------- 已挂载则只补齐 fstab ----------
if is_mounted "$DATA_MOUNT"; then
  log_info "${DATA_MOUNT} 已挂载，检查 fstab 记录"
  if grep -qE "^[^#]*[[:space:]]${DATA_MOUNT}[[:space:]]" "$FSTAB" 2>/dev/null; then
    log_ok "fstab 已有 ${DATA_MOUNT} 记录，无需处理"
    log_ok "步骤 30 完成"
    exit 0
  fi
  uuid="$(blkid -o value -s UUID "$DATA_DEVICE" || true)"
  [[ -n "$uuid" ]] || die "无法获取 ${DATA_DEVICE} 的 UUID"
else
  uuid=""
fi

# ---------- 判断是否需要格式化 ----------
if [[ -z "$uuid" ]]; then
  existing_fs="$(blkid -o value -s TYPE "$DATA_DEVICE" 2>/dev/null || true)"
  if [[ -n "$existing_fs" ]]; then
    log_warn "设备已有文件系统：${existing_fs}"
    [[ "$existing_fs" == "$DATA_FSTYPE" ]] && log_info "类型与配置一致，跳过格式化"
  fi

  if [[ -z "$existing_fs" ]] || [[ "$existing_fs" != "$DATA_FSTYPE" ]]; then
    if [[ "${DATA_ALLOW_FORMAT:-0}" != "1" ]]; then
      die "设备未格式化或类型不符，但 DATA_ALLOW_FORMAT != 1，已中止（防止误清数据）"
    fi
    log_warn "即将格式化 ${DATA_DEVICE}（${DATA_FSTYPE}），该设备上的数据将被全部清空"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$DATA_DEVICE" || true
    confirm "确认格式化 ${DATA_DEVICE}？" || die "已取消"

    case "$DATA_FSTYPE" in
      ext4) run mkfs.ext4 -F -L "${DATA_LABEL:-data}" "$DATA_DEVICE" ;;
      xfs)  run mkfs.xfs -f -L "${DATA_LABEL:-data}" "$DATA_DEVICE" ;;
      *)    die "不支持的 DATA_FSTYPE：${DATA_FSTYPE}（支持 ext4 / xfs）" ;;
    esac
    uuid="$(blkid -o value -s UUID "$DATA_DEVICE" || true)"
    [[ -n "$uuid" ]] || die "格式化后仍未获取到 UUID"
    log_ok "格式化完成，UUID=${uuid}"
  fi

  [[ -n "$uuid" ]] || uuid="$(blkid -o value -s UUID "$DATA_DEVICE" || true)"
fi

# ---------- 创建挂载点 ----------
run mkdir -p "$DATA_MOUNT"

# ---------- 写入 fstab（UUID + noatime） ----------
if grep -qE "^UUID=${uuid}[[:space:]]" "$FSTAB" 2>/dev/null; then
  log_info "fstab 已存在该 UUID 记录，跳过写入"
else
  backup_file "$FSTAB"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] 将写入 fstab: UUID=${uuid} ${DATA_MOUNT} ${DATA_FSTYPE} defaults,noatime 0 2"
  else
    tmpf="$(mktemp)"
    # 移除同一挂载点的旧记录（含错误残留），避免重复挂载
    awk -v m="$DATA_MOUNT" '!(NF >= 2 && $1 !~ /^#/ && $2 == m)' "$FSTAB" >"$tmpf"
    printf 'UUID=%s  %s  %s  defaults,noatime  0  2\n' \
      "$uuid" "$DATA_MOUNT" "$DATA_FSTYPE" >>"$tmpf"
    install -m 644 -o root -g root "$tmpf" "$FSTAB"
    rm -f "$tmpf"
    log_ok "已写入 fstab：UUID=${uuid} → ${DATA_MOUNT}"
  fi
fi

# ---------- 挂载与验证 ----------
is_mounted "$DATA_MOUNT" || run mount -a

if [[ "$DRY_RUN" == "1" ]]; then
  log_warn "[dry-run] 跳过挂载验证"
else
  if is_mounted "$DATA_MOUNT"; then
    log_ok "挂载成功：$(findmnt -no SOURCE,TARGET,FSTYPE "$DATA_MOUNT")"
  else
    die "挂载失败，请检查 fstab 与设备状态（dmesg | tail -30）"
  fi

  if touch "${DATA_MOUNT}/.provision_writetest" 2>/dev/null; then
    rm -f "${DATA_MOUNT}/.provision_writetest"
    log_ok "挂载点可写"
  else
    die "挂载点不可写，请检查权限"
  fi

  log_warn "fstab 已修改，强烈建议执行 sudo reboot 后确认自动挂载"
fi

log_ok "步骤 30 完成"
