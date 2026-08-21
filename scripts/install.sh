#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  sudo bash install.sh
  sudo bash install.sh --dry-run

--dry-run  只校验离线包并执行 DNF/YUM 事务测试，显示将安装/升级的包；
           不安装/升级任何 RPM，不写 Samba 配置，不安装或启动 Sambly。
EOF
}

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) usage; exit 0 ;;
  *)
    echo "错误：未知参数：$1" >&2
    usage >&2
    exit 1
    ;;
esac
if [[ $# -gt 1 ]]; then
  echo "错误：参数过多。" >&2
  usage >&2
  exit 1
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash install.sh" >&2
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" ]]; then
  echo "错误：此离线包仅适用于 aarch64/ARM64，当前架构：$ARCH" >&2
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "错误：无法识别操作系统。" >&2
  exit 1
fi
. /etc/os-release
if [[ "${ID:-}" != "kylin" || "${VERSION_ID:-}" != "V10" ]]; then
  echo "错误：此包仅针对 Kylin Linux Advanced Server V10，当前：${PRETTY_NAME:-unknown}" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPM_DIR="$ROOT_DIR/rpms"
SAMBLY_BIN="$ROOT_DIR/webui/sambly/sambly"
SAMBA_NEVR="4.11.12-32.p11.ky10"

if [[ ! -d "$RPM_DIR" ]]; then
  echo "错误：找不到 RPM 目录：$RPM_DIR" >&2
  exit 1
fi
if [[ ! -f "$RPM_DIR/repodata/repomd.xml" ]]; then
  echo "错误：离线包缺少 rpms/repodata/repomd.xml，无法作为完整本地软件仓库安装。" >&2
  exit 1
fi
if [[ ! -x "$SAMBLY_BIN" ]]; then
  echo "错误：找不到 Sambly ARM64 二进制：$SAMBLY_BIN" >&2
  exit 1
fi

if command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
else
  echo "错误：系统中未找到 dnf/yum。" >&2
  exit 1
fi

if [[ -f "$ROOT_DIR/SHA256SUMS" ]]; then
  echo "== 校验离线包完整性 =="
  (cd "$ROOT_DIR" && sha256sum -c SHA256SUMS)
fi

echo "== 当前 Samba 相关包 =="
rpm -qa | grep -E '^(samba|libwbclient|libsmbclient|libtalloc|libtdb|libtevent|libldb)' | sort || true

TMP_REPO_DIR="$(mktemp -d /tmp/samba-offline-repo.XXXXXX)"
TMP_CACHE_DIR="$TMP_REPO_DIR/cache"
mkdir -p "$TMP_CACHE_DIR"
cat >"$TMP_REPO_DIR/samba-offline-local.repo" <<EOF
[samba-offline-local]
name=Kylin Samba Offline Local Repository
baseurl=file://$RPM_DIR
enabled=1
gpgcheck=0
repo_gpgcheck=0
metadata_expire=0
EOF

cleanup_repo() {
  rm -rf "$TMP_REPO_DIR"
}
trap cleanup_repo EXIT

TARGETS=(
  "samba-${SAMBA_NEVR}.aarch64"
  "samba-client-${SAMBA_NEVR}.aarch64"
  "samba-common-${SAMBA_NEVR}.aarch64"
  "samba-common-tools-${SAMBA_NEVR}.aarch64"
)

COMMON_ARGS=(
  --setopt="reposdir=$TMP_REPO_DIR"
  --setopt="cachedir=$TMP_CACHE_DIR"
  --disablerepo='*'
  --enablerepo='samba-offline-local'
  --setopt=install_weak_deps=False
  --nogpgcheck
)

"$PKG_MGR" "${COMMON_ARGS[@]}" makecache

echo
echo "== 离线事务预检查（不会修改 RPM 数据库） =="
if ! "$PKG_MGR" -y "${COMMON_ARGS[@]}" --setopt=tsflags=test install "${TARGETS[@]}"; then
  echo >&2
  echo "依赖事务预检查失败，未安装任何软件。" >&2
  echo "本 Release 应包含 Samba 所有强依赖；请把上面的完整错误反馈回来。" >&2
  echo "不要使用 --nodeps，也不要临时启用互联网软件源。" >&2
  exit 2
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "== DRY-RUN 完成 =="
  echo "上面的 Transaction Summary 就是正式执行时 DNF/YUM 计划的安装/升级集合。"
  echo "未安装或升级任何 RPM；未修改 smb.conf；未安装、覆盖或启动 Sambly。"
  exit 0
fi

BACKUP_DIR="/root/samba-sambly-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
rpm -qa | sort >"$BACKUP_DIR/packages-before-all.txt"
rpm -qa | grep -E '^(samba|libwbclient|libsmbclient|libtalloc|libtdb|libtevent|libldb)' | sort \
  >"$BACKUP_DIR/packages-before-samba.txt" || true
if [[ -f /etc/samba/smb.conf ]]; then
  cp -a /etc/samba/smb.conf "$BACKUP_DIR/smb.conf"
fi
if [[ -d /var/lib/samba/private ]]; then
  cp -a /var/lib/samba/private "$BACKUP_DIR/samba-private" 2>/dev/null || true
fi

echo
echo "== 从完整本地仓库安装/升级 Samba 4.11 p11 =="
"$PKG_MGR" -y "${COMMON_ARGS[@]}" install "${TARGETS[@]}"

echo
echo "== Samba 安装验证 =="
command -v smbd
command -v testparm
smbd -V
if [[ "$(smbd -V)" != *"4.11.12"* ]]; then
  echo "错误：安装后的 smbd 版本不是预期的 Samba 4.11.12。" >&2
  exit 3
fi
if [[ -f /etc/samba/smb.conf ]]; then
  testparm -s /etc/samba/smb.conf >/dev/null
else
  echo "提示：当前还没有 /etc/samba/smb.conf；configure-dfs-root.sh 会创建 DFS 配置。"
fi
rpm -qa | grep -E '^(samba|libwbclient|libsmbclient)' | sort

if ! systemctl cat smbd.service >/dev/null 2>&1; then
  SMB_UNIT="$(systemctl show -p FragmentPath --value smb.service 2>/dev/null || true)"
  if [[ -z "$SMB_UNIT" || ! -f "$SMB_UNIT" ]]; then
    SMB_UNIT="/usr/lib/systemd/system/smb.service"
  fi
  if [[ -f "$SMB_UNIT" ]]; then
    ln -sfn "$SMB_UNIT" /etc/systemd/system/smbd.service
    systemctl daemon-reload
    echo "已创建 Sambly 兼容别名：smbd.service -> $SMB_UNIT"
  else
    echo "警告：没有找到 smb.service；Sambly 的服务控制按钮可能不可用。" >&2
  fi
fi

echo
echo "== 安装/更新 Sambly ARM64 单二进制 =="
install -m 0755 "$SAMBLY_BIN" /usr/local/bin/sambly
install -d -m 0750 /var/lib/sambly

SAMBLY_PORT="${SAMBLY_PORT:-8090}"
SAMBLY_ADMIN_USER="${SAMBLY_ADMIN_USER:-admin}"
SAMBLY_ADMIN_PASSWORD="${SAMBLY_ADMIN_PASSWORD:-}"

if ! [[ "$SAMBLY_PORT" =~ ^[0-9]+$ ]] || (( SAMBLY_PORT < 1 || SAMBLY_PORT > 65535 )); then
  echo "错误：SAMBLY_PORT 必须是 1-65535。" >&2
  exit 1
fi
if ! [[ "$SAMBLY_ADMIN_USER" =~ ^[a-zA-Z0-9_.-]{1,32}$ ]]; then
  echo "错误：SAMBLY_ADMIN_USER 格式不合法。" >&2
  exit 1
fi

if [[ ! -f /var/lib/sambly/sambly.db ]]; then
  {
    printf 'ADMIN_USERNAME=%s\n' "$SAMBLY_ADMIN_USER"
    if [[ -n "$SAMBLY_ADMIN_PASSWORD" ]]; then
      printf 'ADMIN_PASSWORD=%s\n' "$SAMBLY_ADMIN_PASSWORD"
    fi
  } >/var/lib/sambly/setup.env
  chmod 0600 /var/lib/sambly/setup.env
fi

cat >/etc/systemd/system/sambly.service <<EOF
[Unit]
Description=Sambly - Samba Web Manager
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sambly --addr=0.0.0.0:${SAMBLY_PORT} --data=/var/lib/sambly
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sambly
systemctl restart sambly

for _ in $(seq 1 15); do
  [[ -f /var/lib/sambly/initial-credentials.txt ]] && break
  systemctl is-active --quiet sambly || break
  sleep 1
done

echo
echo "安装完成。"
echo "Samba：$(smbd -V)"
echo "Sambly：http://<服务器IP>:${SAMBLY_PORT}"
echo "Sambly 状态：systemctl status sambly --no-pager -l"
if [[ -f /var/lib/sambly/initial-credentials.txt ]]; then
  chmod 0600 /var/lib/sambly/initial-credentials.txt
  echo "首次登录凭据已写入：/var/lib/sambly/initial-credentials.txt（0600）"
  echo "为避免密码进入终端/审计日志，安装脚本不会打印该文件内容。"
  echo "请在服务器本机查看，登录并修改密码后删除该凭据文件。"
fi
echo
echo "注意：本脚本没有自动启动 Samba，也没有修改现有 smb.conf。"
echo "安装前备份：$BACKUP_DIR"
echo "下一步在 DFS 入口服务器运行：sudo bash configure-dfs-root.sh"
