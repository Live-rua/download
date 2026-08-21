#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/install.sh"
OLD_PREFIX="${OLD_SAMBA_PREFIX:-/usr/local/samba}"
TEST_USER="${SAMBA_MIGRATION_TEST_USER:-wuhongguang}"
TEST_SHARE="${SAMBA_MIGRATION_TEST_SHARE:-ledong_share}"
STATE_FILE="/root/.samba32-to-411-migration-state"
MODE=""
FORCE_ACTIVE=0

usage() {
  cat <<'USAGE'
Kylin V10 SP3 aarch64 Samba 3.2 -> 4.11 原机平滑迁移脚本

用法：
  sudo bash migrate-samba32-to-411.sh --prepare [选项]
  sudo bash migrate-samba32-to-411.sh --apply [选项]
  sudo bash migrate-samba32-to-411.sh --rollback

阶段：
  --prepare   只读审计 + 完整备份 + install.sh --dry-run；不停止旧 Samba，不安装 RPM。
  --apply     安装 Samba 4.11 RPM，迁移 SID/tdbsam 用户密码库，校验后切换 TCP 445。
              默认要求没有活动 SMB 会话；启动后用指定账号做真实 smbclient 登录验证。
  --rollback  停止新 smb.service，并尝试重新启动原 /usr/local/samba Samba 3.2。

选项：
  --old-prefix PATH       旧源码 Samba 前缀，默认 /usr/local/samba
  --test-user USER        切换后登录验证用户，默认 wuhongguang
  --test-share SHARE      切换后验证共享，默认 ledong_share
  --force-active-sessions 允许有活动 SMB 会话时强制切换（不推荐）

密码不会写入仓库、命令行参数或迁移报告。--apply 会在终端安全提示输入测试用户密码，
并用临时 0600 凭据文件调用 smbclient，脚本退出时自动删除该文件。

设计目标：
  * IP、共享名、共享路径不变
  * Linux 用户、UID/GID 不变
  * Samba 用户、NT 密码哈希、用户 SID 不变
  * 本机 SID 不变
  * 共享目录文件权限不变
  * 旧 /usr/local/samba 完整保留作为回退路径
  * 最低协议切换为 SMB2_02，不再依赖 SMB1/NT1
USAGE
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare|--apply|--rollback)
      [[ -z "$MODE" ]] || die "只能指定一个模式"
      MODE="${1#--}"
      shift
      ;;
    --old-prefix)
      [[ $# -ge 2 ]] || die "--old-prefix 缺少参数"
      OLD_PREFIX="$2"
      shift 2
      ;;
    --test-user)
      [[ $# -ge 2 ]] || die "--test-user 缺少参数"
      TEST_USER="$2"
      shift 2
      ;;
    --test-share)
      [[ $# -ge 2 ]] || die "--test-share 缺少参数"
      TEST_SHARE="$2"
      shift 2
      ;;
    --force-active-sessions)
      FORCE_ACTIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -n "$MODE" ]] || { usage >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行"

AUTH_FILE=""
cleanup_secret() {
  if [[ -n "$AUTH_FILE" && -f "$AUTH_FILE" ]]; then
    shred -u "$AUTH_FILE" 2>/dev/null || rm -f "$AUTH_FILE"
  fi
}
trap cleanup_secret EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

build_value() {
  local bin="$1" key="$2"
  "$bin" -b 2>/dev/null | awk -F': ' -v k="$key" '$1 ~ "^[[:space:]]*" k "$" {print $2; exit}'
}

init_old_paths() {
  OLD_SMBD="$OLD_PREFIX/sbin/smbd"
  OLD_NMBD="$OLD_PREFIX/sbin/nmbd"
  OLD_PDBEDIT="$OLD_PREFIX/bin/pdbedit"
  OLD_NET="$OLD_PREFIX/bin/net"
  OLD_TESTPARM="$OLD_PREFIX/bin/testparm"
  OLD_SMBSTATUS="$OLD_PREFIX/bin/smbstatus"
  OLD_SMBCONTROL="$OLD_PREFIX/bin/smbcontrol"
  OLD_SMBCLIENT="$OLD_PREFIX/bin/smbclient"

  [[ -x "$OLD_SMBD" ]] || die "找不到旧 smbd: $OLD_SMBD"
  [[ -x "$OLD_PDBEDIT" ]] || die "找不到旧 pdbedit: $OLD_PDBEDIT"
  [[ -x "$OLD_NET" ]] || die "找不到旧 net: $OLD_NET"
  [[ -x "$OLD_TESTPARM" ]] || die "找不到旧 testparm: $OLD_TESTPARM"

  OLD_CONFIG="$(build_value "$OLD_SMBD" CONFIGFILE)"
  OLD_PRIVATE_DIR="$(build_value "$OLD_SMBD" PRIVATE_DIR)"
  OLD_LOCKDIR="$(build_value "$OLD_SMBD" LOCKDIR)"
  [[ -n "$OLD_CONFIG" && -f "$OLD_CONFIG" ]] || die "无法确定旧 smb.conf"
  [[ -n "$OLD_PRIVATE_DIR" && -d "$OLD_PRIVATE_DIR" ]] || die "无法确定旧 PRIVATE_DIR"
  OLD_PASSDB="$OLD_PRIVATE_DIR/passdb.tdb"
  [[ -f "$OLD_PASSDB" ]] || die "旧 tdbsam 数据库不存在: $OLD_PASSDB"
}

check_platform() {
  [[ "$(uname -m)" == "aarch64" ]] || die "仅支持 aarch64/ARM64"
  [[ -f /etc/os-release ]] || die "缺少 /etc/os-release"
  . /etc/os-release
  [[ "${ID:-}" == "kylin" && "${VERSION_ID:-}" == "V10" ]] || die "仅支持 Kylin Linux Advanced Server V10"
}

old_version() {
  "$OLD_SMBD" -V 2>/dev/null | head -n1
}

active_session_count() {
  if [[ ! -x "$OLD_SMBSTATUS" ]]; then
    echo 0
    return
  fi
  "$OLD_SMBSTATUS" 2>/dev/null | awk '
    /^PID[[:space:]]+Username/ {seen=1; next}
    seen && /^-+$/ {next}
    seen && /^[[:space:]]*$/ {exit}
    seen && $1 ~ /^[0-9]+$/ {count++}
    END {print count+0}
  '
}

list_old_users() {
  "$OLD_PDBEDIT" -L 2>/dev/null | cut -d: -f1 | LC_ALL=C sort -u
}

password_fingerprint() {
  local pdbedit_bin="$1"
  "$pdbedit_bin" -L -w 2>/dev/null \
    | awk -F: 'NF >= 4 {print $1 ":" $2 ":" $4}' \
    | LC_ALL=C sort \
    | sha256sum \
    | awk '{print $1}'
}

sid_fingerprint() {
  local pdbedit_bin="$1"
  LC_ALL=C "$pdbedit_bin" -L -v 2>/dev/null | awk '
    /^Unix username:/ {u=$0; sub(/^Unix username:[[:space:]]*/, "", u)}
    /^User SID:/ {s=$0; sub(/^User SID:[[:space:]]*/, "", s); if (u != "") print u ":" s}
  ' | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

linux_identity_fingerprint() {
  local tmp p uid gid groups shell u
  tmp="$(mktemp)"
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    p="$(getent passwd "$u" || true)"
    [[ -n "$p" ]] || { printf '%s:MISSING\n' "$u" >>"$tmp"; continue; }
    uid="$(printf '%s\n' "$p" | cut -d: -f3)"
    gid="$(printf '%s\n' "$p" | cut -d: -f4)"
    shell="$(printf '%s\n' "$p" | cut -d: -f7)"
    groups="$(id -G "$u" 2>/dev/null | tr ' ' ',' || true)"
    printf '%s:%s:%s:%s:%s\n' "$u" "$uid" "$gid" "$groups" "$shell" >>"$tmp"
  done < <(list_old_users)
  LC_ALL=C sort "$tmp" | sha256sum | awk '{print $1}'
  rm -f "$tmp"
}

extract_share_paths() {
  LC_ALL=C "$OLD_TESTPARM" -s "$OLD_CONFIG" 2>/dev/null | awk -F' = ' '
    /^[[:space:]]*path = / {
      p=$2
      if (p !~ /%/ && p ~ /^\//) print p
    }
  ' | LC_ALL=C sort -u
}

share_metadata_fingerprint() {
  local tmp path
  tmp="$(mktemp)"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ -e "$path" ]]; then
      printf 'ROOT\0%s\0' "$path" >>"$tmp"
      find "$path" -xdev -printf '%y|%m|%U|%G|%s|%p\n' 2>/dev/null | LC_ALL=C sort >>"$tmp"
    else
      printf 'MISSING\0%s\0' "$path" >>"$tmp"
    fi
  done < <(extract_share_paths)
  sha256sum "$tmp" | awk '{print $1}'
  rm -f "$tmp"
}

write_state() {
  local backup="$1" status="$2"
  umask 077
  cat > "$STATE_FILE" <<__STATE__
BACKUP_DIR='$backup'
OLD_PREFIX='$OLD_PREFIX'
TEST_USER='$TEST_USER'
TEST_SHARE='$TEST_SHARE'
STATUS='$status'
__STATE__
  chmod 600 "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "没有找到迁移状态文件: $STATE_FILE"
  local bad
  bad="$(grep -Ev "^(BACKUP_DIR|OLD_PREFIX|TEST_USER|TEST_SHARE|STATUS)='[^']*'$|^[[:space:]]*$" "$STATE_FILE" || true)"
  [[ -z "$bad" ]] || die "迁移状态文件格式异常，拒绝加载"
  . "$STATE_FILE"
  init_old_paths
}

create_backup() {
  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="/root/samba32-to-411-$ts"
  mkdir -p "$backup"
  chmod 700 "$backup"

  log "创建迁移备份: $backup" >&2
  tar --acls --xattrs --numeric-owner -cpf "$backup/usr-local-samba.tar" "$OLD_PREFIX"
  cp -a "$OLD_CONFIG" "$backup/smb.conf.old"
  cp -a /etc/passwd /etc/group /etc/shadow /etc/gshadow "$backup/" 2>/dev/null || true
  if [[ -d /etc/samba ]]; then
    tar --acls --xattrs --numeric-owner -cpf "$backup/etc-samba-before.tar" /etc/samba
  fi
  if [[ -d /var/lib/samba ]]; then
    tar --acls --xattrs --numeric-owner -cpf "$backup/var-lib-samba-before.tar" /var/lib/samba
  fi

  old_version > "$backup/samba-version-before.txt"
  "$OLD_TESTPARM" -s "$OLD_CONFIG" > "$backup/smbconf-before.txt" 2>&1
  "$OLD_PDBEDIT" -L -v > "$backup/users-before.txt" 2>&1
  "$OLD_NET" getlocalsid > "$backup/localsid-before.txt" 2>&1
  if [[ -x "$OLD_SMBSTATUS" ]]; then
    "$OLD_SMBSTATUS" > "$backup/smbstatus-before.txt" 2>&1 || true
  fi
  find "$OLD_PREFIX" -type f -name '*.tdb' -print | LC_ALL=C sort > "$backup/tdb-files-before.txt"
  ldd "$OLD_SMBD" > "$backup/old-smbd-ldd.txt" 2>&1 || true
  rpm -qa | LC_ALL=C sort > "$backup/packages-before.txt"

  printf '%s\n' "$(password_fingerprint "$OLD_PDBEDIT")" > "$backup/password-fingerprint-before.txt"
  printf '%s\n' "$(sid_fingerprint "$OLD_PDBEDIT")" > "$backup/user-sid-fingerprint-before.txt"
  printf '%s\n' "$(linux_identity_fingerprint)" > "$backup/linux-identity-fingerprint-before.txt"
  printf '%s\n' "$("$OLD_NET" getlocalsid 2>/dev/null | awk '{print $NF}')" > "$backup/local-sid-before.txt"
  list_old_users > "$backup/usernames-before.txt"
  extract_share_paths > "$backup/share-paths.txt"

  chmod -R go-rwx "$backup"
  printf '%s\n' "$backup"
}

preflight() {
  check_platform
  init_old_paths
  require_cmd awk
  require_cmd sha256sum
  require_cmd tar
  require_cmd getent
  require_cmd rpm
  require_cmd ss
  require_cmd diff

  local version backend
  version="$(old_version)"
  [[ "$version" == *"3.2."* ]] || warn "检测到旧 Samba 版本不是 3.2.x: $version"

  "$OLD_TESTPARM" -s "$OLD_CONFIG" >/dev/null
  backend="$($OLD_TESTPARM -s "$OLD_CONFIG" 2>/dev/null | awk -F' = ' '/^[[:space:]]*passdb backend = /{print $2; exit}')"
  [[ "$backend" == tdbsam* ]] || die "当前脚本只支持旧 passdb backend = tdbsam，实际: ${backend:-unknown}"

  getent passwd "$TEST_USER" >/dev/null || die "Linux 测试用户不存在: $TEST_USER"
  list_old_users | grep -Fxq "$TEST_USER" || die "Samba 测试用户不存在: $TEST_USER"
  "$OLD_TESTPARM" -s "$OLD_CONFIG" 2>/dev/null | grep -Fq "[$TEST_SHARE]" || die "测试共享不存在: $TEST_SHARE"
  [[ -x "$INSTALL_SCRIPT" ]] || die "必须从完整离线包目录运行，找不到: $INSTALL_SCRIPT"
}

prepare_mode() {
  preflight
  local backup sessions
  backup="$(create_backup)"
  sessions="$(active_session_count)"

  {
    echo "old_version=$(old_version)"
    echo "old_config=$OLD_CONFIG"
    echo "old_private_dir=$OLD_PRIVATE_DIR"
    echo "old_passdb=$OLD_PASSDB"
    echo "test_user=$TEST_USER"
    echo "test_share=$TEST_SHARE"
    echo "old_user_count=$(list_old_users | wc -l)"
    echo "old_local_sid=$(cat "$backup/local-sid-before.txt")"
    echo "password_fingerprint=$(cat "$backup/password-fingerprint-before.txt")"
    echo "user_sid_fingerprint=$(cat "$backup/user-sid-fingerprint-before.txt")"
    echo "linux_identity_fingerprint=$(cat "$backup/linux-identity-fingerprint-before.txt")"
    echo "active_sessions=$sessions"
  } > "$backup/prepare-summary.txt"

  log "执行离线 RPM 事务 dry-run（不会修改系统）"
  bash "$INSTALL_SCRIPT" --dry-run | tee "$backup/install-dry-run.txt"

  write_state "$backup" prepared
  log "PREPARE 完成"
  echo "备份目录: $backup"
  cat "$backup/prepare-summary.txt"
  if (( sessions > 0 )); then
    warn "当前检测到 $sessions 个 SMB 会话；--apply 默认会拒绝强制断开。"
  fi
}

read_test_password() {
  [[ -t 0 ]] || die "--apply 需要交互式终端输入测试账号密码"
  local p1
  printf '请输入 Samba 测试用户 %s 的当前密码: ' "$TEST_USER" >&2
  IFS= read -r -s p1
  printf '\n' >&2
  [[ -n "$p1" ]] || die "测试密码不能为空"
  AUTH_FILE="$(mktemp /root/.samba-migration-auth.XXXXXX)"
  chmod 600 "$AUTH_FILE"
  {
    printf 'username = %s\n' "$TEST_USER"
    printf 'password = %s\n' "$p1"
  } > "$AUTH_FILE"
  unset p1
}

verify_old_login() {
  [[ -x "$OLD_SMBCLIENT" ]] || { warn "旧 smbclient 不存在，跳过切换前登录验证"; return 0; }
  log "验证测试账号在旧 Samba 3.2 上可以登录"
  "$OLD_SMBCLIENT" "//127.0.0.1/$TEST_SHARE" -A "$AUTH_FILE" -c 'ls' >/dev/null
}

stop_old_samba() {
  log "停止旧 Samba 3.2，释放 TCP 445"
  if [[ -x "$OLD_SMBCONTROL" ]]; then
    "$OLD_SMBCONTROL" all shutdown >/dev/null 2>&1 || true
  fi
  sleep 1
  local pids
  pids="$(pgrep -x smbd || true) $(pgrep -x nmbd || true)"
  if [[ -n "${pids// /}" ]]; then
    kill -TERM $pids 2>/dev/null || true
  fi
  for _ in $(seq 1 20); do
    if ! ss -lnt 2>/dev/null | grep -Eq '[:.]445[[:space:]]'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_old_samba() {
  log "尝试恢复旧 Samba 3.2"
  systemctl disable --now smb.service >/dev/null 2>&1 || true
  systemctl disable --now smbd.service >/dev/null 2>&1 || true
  if ! pgrep -f "^$OLD_SMBD( |$)" >/dev/null 2>&1; then
    "$OLD_SMBD" -D
  fi
  if [[ -x "$OLD_NMBD" ]] && ! pgrep -f "^$OLD_NMBD( |$)" >/dev/null 2>&1; then
    "$OLD_NMBD" -D
  fi
  sleep 1
  ss -lntp 2>/dev/null | grep -E ':445[[:space:]]' || warn "旧 Samba 未重新监听 TCP 445，请立即人工检查"
}

backup_cutover_state() {
  local backup="$1"
  mkdir -p "$backup/cutover"
  chmod 700 "$backup/cutover"
  cp -a "$OLD_PRIVATE_DIR" "$backup/cutover/old-private"
  if [[ -n "$OLD_LOCKDIR" && -d "$OLD_LOCKDIR" ]]; then
    cp -a "$OLD_LOCKDIR" "$backup/cutover/old-lockdir"
  fi
  cp -a "$OLD_CONFIG" "$backup/cutover/smb.conf.old"

  printf '%s\n' "$(password_fingerprint "$OLD_PDBEDIT")" > "$backup/cutover/password-fingerprint.txt"
  printf '%s\n' "$(sid_fingerprint "$OLD_PDBEDIT")" > "$backup/cutover/user-sid-fingerprint.txt"
  printf '%s\n' "$(linux_identity_fingerprint)" > "$backup/cutover/linux-identity-fingerprint.txt"
  printf '%s\n' "$(share_metadata_fingerprint)" > "$backup/cutover/share-metadata-fingerprint.txt"
  printf '%s\n' "$("$OLD_NET" getlocalsid 2>/dev/null | awk '{print $NF}')" > "$backup/cutover/local-sid.txt"
  list_old_users > "$backup/cutover/usernames.txt"
}

install_new_stack() {
  local backup="$1"
  log "安装离线 Samba 4.11 + Sambly；install.sh 不会启动 Samba 文件服务"
  bash "$INSTALL_SCRIPT" | tee "$backup/install-apply.txt"

  NEW_SMBD="/usr/sbin/smbd"
  NEW_PDBEDIT="/usr/bin/pdbedit"
  NEW_NET="/usr/bin/net"
  NEW_TESTPARM="/usr/bin/testparm"
  NEW_SMBCLIENT="/usr/bin/smbclient"

  [[ -x "$NEW_SMBD" ]] || die "安装后找不到系统 smbd"
  [[ "$(readlink -f "$NEW_SMBD")" != "$(readlink -f "$OLD_SMBD")" ]] || die "系统 smbd 仍指向旧源码版本"
  "$NEW_SMBD" -V | grep -Fq '4.11.12' || die "安装后的 Samba 不是 4.11.12"
  [[ -x "$NEW_PDBEDIT" && -x "$NEW_NET" && -x "$NEW_TESTPARM" && -x "$NEW_SMBCLIENT" ]] || die "Samba 4.11 管理工具不完整"

  NEW_CONFIG="$(build_value "$NEW_SMBD" CONFIGFILE)"
  NEW_PRIVATE_DIR="$(build_value "$NEW_SMBD" PRIVATE_DIR)"
  [[ -n "$NEW_CONFIG" && -n "$NEW_PRIVATE_DIR" ]] || die "无法解析 Samba 4.11 编译路径"
  mkdir -p "$(dirname "$NEW_CONFIG")" "$NEW_PRIVATE_DIR"
  chmod 700 "$NEW_PRIVATE_DIR" 2>/dev/null || true

  {
    "$NEW_SMBD" -V
    "$NEW_SMBD" -b
  } > "$backup/new-samba-build.txt"
}

install_migrated_config() {
  local backup="$1" tmp
  if [[ -f "$NEW_CONFIG" ]]; then
    cp -a "$NEW_CONFIG" "$backup/new-smb.conf-before-migration"
  fi
  tmp="$(mktemp)"

  awk '
    BEGIN {in_global=0; inserted=0}
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_global && !inserted) {
        print "\tserver min protocol = SMB2_02"
        inserted=1
      }
      in_global = (tolower($0) ~ /^[[:space:]]*\[global\][[:space:]]*$/)
      print
      next
    }
    { print }
    END {
      if (in_global && !inserted) print "\tserver min protocol = SMB2_02"
    }
  ' "$OLD_CONFIG" > "$tmp"

  install -m 0640 "$tmp" "$NEW_CONFIG"
  rm -f "$tmp"
  "$NEW_TESTPARM" -s "$NEW_CONFIG" > "$backup/new-testparm.txt" 2>&1 || {
    cat "$backup/new-testparm.txt" >&2
    return 1
  }
  grep -Fq "[$TEST_SHARE]" "$backup/new-testparm.txt" || return 1
}

migrate_identity_db() {
  local backup="$1"
  local old_sid staged_passdb new_passdb new_sid
  local old_pw new_pw old_usid new_usid old_linux new_linux
  old_sid="$(cat "$backup/cutover/local-sid.txt")"
  new_passdb="$NEW_PRIVATE_DIR/passdb.tdb"
  staged_passdb="$backup/cutover/passdb.tdb.for-411"

  rm -f "$staged_passdb"
  log "使用 Samba 4.11 pdbedit 从旧 tdbsam 副本导入用户和 NT 密码哈希"
  "$NEW_PDBEDIT" -i "tdbsam:$backup/cutover/old-private/passdb.tdb" \
                  -e "tdbsam:$staged_passdb" \
                  > "$backup/pdbedit-import.txt" 2>&1 || return 1
  [[ -s "$staged_passdb" ]] || return 1

  if [[ -f "$new_passdb" ]]; then
    cp -a "$new_passdb" "$backup/cutover/new-passdb-before-migration.tdb"
  fi
  install -m 0600 "$staged_passdb" "$new_passdb"

  log "恢复原 Samba 本机 SID: $old_sid"
  "$NEW_NET" setlocalsid "$old_sid" > "$backup/net-setlocalsid.txt" 2>&1 || return 1
  new_sid="$("$NEW_NET" getlocalsid 2>/dev/null | awk '{print $NF}')"
  [[ "$new_sid" == "$old_sid" ]] || return 1

  old_pw="$(cat "$backup/cutover/password-fingerprint.txt")"
  new_pw="$(password_fingerprint "$NEW_PDBEDIT")"
  old_usid="$(cat "$backup/cutover/user-sid-fingerprint.txt")"
  new_usid="$(sid_fingerprint "$NEW_PDBEDIT")"
  old_linux="$(cat "$backup/cutover/linux-identity-fingerprint.txt")"
  new_linux="$(linux_identity_fingerprint)"

  [[ "$new_pw" == "$old_pw" ]] || return 1
  [[ "$new_usid" == "$old_usid" ]] || return 1
  [[ "$new_linux" == "$old_linux" ]] || return 1

  "$NEW_PDBEDIT" -L > "$backup/users-after-import.txt" || return 1
  diff -u "$backup/cutover/usernames.txt" <("$NEW_PDBEDIT" -L | cut -d: -f1 | LC_ALL=C sort -u) > "$backup/usernames.diff" || return 1
}

verify_share_metadata_unchanged() {
  local backup="$1" before after
  before="$(cat "$backup/cutover/share-metadata-fingerprint.txt")"
  after="$(share_metadata_fingerprint)"
  printf '%s\n' "$after" > "$backup/share-metadata-fingerprint-after.txt"
  [[ "$after" == "$before" ]]
}

start_new_and_test() {
  local backup="$1"
  log "启动 Samba 4.11 smb.service"
  systemctl daemon-reload || return 1
  systemctl enable --now smb.service || return 1
  for _ in $(seq 1 20); do
    if systemctl is-active --quiet smb.service && ss -lnt 2>/dev/null | grep -Eq '[:.]445[[:space:]]'; then
      break
    fi
    sleep 1
  done
  systemctl is-active --quiet smb.service || return 1
  ss -lnt 2>/dev/null | grep -Eq '[:.]445[[:space:]]' || return 1

  log "使用测试用户做真实 SMB3 登录验证"
  "$NEW_SMBCLIENT" "//127.0.0.1/$TEST_SHARE" -A "$AUTH_FILE" -m SMB3 -c 'ls' > "$backup/smbclient-post-migration.txt" 2>&1 || return 1

  "$NEW_SMBD" -V > "$backup/samba-version-after.txt"
  "$NEW_TESTPARM" -s "$NEW_CONFIG" > "$backup/smbconf-after.txt" 2>&1 || return 1
  "$NEW_PDBEDIT" -L -v > "$backup/users-after.txt" 2>&1 || return 1
  "$NEW_NET" getlocalsid > "$backup/localsid-after.txt" 2>&1 || return 1

  verify_share_metadata_unchanged "$backup" || return 1
  [[ "$(password_fingerprint "$NEW_PDBEDIT")" == "$(cat "$backup/cutover/password-fingerprint.txt")" ]] || return 1
  [[ "$(sid_fingerprint "$NEW_PDBEDIT")" == "$(cat "$backup/cutover/user-sid-fingerprint.txt")" ]] || return 1
}

apply_mode() {
  preflight
  read_test_password
  verify_old_login

  local backup sessions old_running failed rc
  old_running=0
  pgrep -f "^$OLD_SMBD( |$)" >/dev/null 2>&1 && old_running=1
  [[ "$old_running" -eq 1 ]] || die "旧 Samba 3.2 当前未运行；为避免误判，不执行自动切换"

  sessions="$(active_session_count)"
  if (( sessions > 0 && FORCE_ACTIVE == 0 )); then
    die "检测到 $sessions 个活动 SMB 会话。请让用户退出后重试；如确需强切换可显式加 --force-active-sessions"
  fi

  backup="$(create_backup)"
  write_state "$backup" installing

  install_new_stack "$backup"
  install_migrated_config "$backup" || die "旧 smb.conf 无法被 Samba 4.11 安全接受；旧 Samba 仍在运行"

  sessions="$(active_session_count)"
  if (( sessions > 0 && FORCE_ACTIVE == 0 )); then
    write_state "$backup" prepared-new-rpms
    die "安装期间出现 $sessions 个活动 SMB 会话；未停止旧 Samba。稍后重新执行 --apply 即可"
  fi

  failed=0
  set +e
  stop_old_samba
  rc=$?
  if (( rc != 0 )); then failed=$rc; fi
  if (( failed == 0 )); then backup_cutover_state "$backup" || failed=$?; fi
  if (( failed == 0 )); then migrate_identity_db "$backup" || failed=$?; fi
  if (( failed == 0 )); then verify_share_metadata_unchanged "$backup" || failed=$?; fi
  if (( failed == 0 )); then start_new_and_test "$backup" || failed=$?; fi
  set -e

  if (( failed != 0 )); then
    warn "迁移校验失败，正在自动回退到旧 Samba 3.2"
    start_old_samba || true
    write_state "$backup" rolled-back
    exit "$failed"
  fi

  write_state "$backup" completed
  log "迁移成功"
  echo "Samba: $($NEW_SMBD -V)"
  echo "本机 SID: $($NEW_NET getlocalsid 2>/dev/null | awk '{print $NF}')"
  echo "测试用户: $TEST_USER"
  echo "测试共享: $TEST_SHARE"
  echo "备份目录: $backup"
  echo "旧 Samba 保留在: $OLD_PREFIX"
  echo "注意：不要删除备份和旧 Samba，至少保留到 DFS/Windows/麒麟客户端全部验收完成。"
}

rollback_mode() {
  load_state
  log "执行人工回退"
  start_old_samba
  if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]]; then
    write_state "$BACKUP_DIR" rolled-back-manual
  fi
  echo "旧 Samba 版本: $(old_version)"
}

case "$MODE" in
  prepare) prepare_mode ;;
  apply) apply_mode ;;
  rollback) rollback_mode ;;
  *) die "内部错误：未知模式 $MODE" ;;
esac
