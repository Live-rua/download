#!/usr/bin/env bash
set -euo pipefail

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
  echo "警告：目标是 Kylin Linux Advanced Server V10，当前：${PRETTY_NAME:-unknown}"
  read -r -p "仍要继续？[y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPM_DIR="$ROOT_DIR/rpms"

if [[ ! -d "$RPM_DIR" ]]; then
  echo "错误：找不到 RPM 目录：$RPM_DIR" >&2
  exit 1
fi

if ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
  echo "错误：系统中未找到 dnf/yum。" >&2
  exit 1
fi

PKG_MGR="dnf"
command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"

BACKUP_DIR="/root/samba-offline-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [[ -f /etc/samba/smb.conf ]]; then
  cp -a /etc/samba/smb.conf "$BACKUP_DIR/smb.conf"
  echo "已备份现有配置到：$BACKUP_DIR/smb.conf"
fi

rpm -qa | grep -Ei '^samba|^libwbclient|^libsmbclient' | sort > "$BACKUP_DIR/packages-before.txt" || true

cat > /etc/yum.repos.d/samba-offline-local.repo <<EOF
[samba-offline-local]
name=Samba Offline Local Repository
baseurl=file://$RPM_DIR
enabled=1
gpgcheck=0
metadata_expire=0
EOF

cleanup() {
  rm -f /etc/yum.repos.d/samba-offline-local.repo
}
trap cleanup EXIT

if [[ ! -d "$RPM_DIR/repodata" ]]; then
  echo "错误：离线包缺少 rpms/repodata。" >&2
  exit 1
fi

echo "== 安装/升级 Samba 服务器及工具 =="
"$PKG_MGR" --disablerepo='*' --enablerepo='samba-offline-local' clean metadata >/dev/null 2>&1 || true
"$PKG_MGR" -y --disablerepo='*' --enablerepo='samba-offline-local' install \
  samba samba-client samba-common samba-common-tools

echo
echo "== 版本验证 =="
smbd -V
command -v testparm
rpm -qa | grep -Ei '^samba|^libwbclient|^libsmbclient' | sort

echo
echo "安装完成。"
echo "- 没有自动覆盖 /etc/samba/smb.conf"
echo "- 没有自动启动/启用 smb、nmb 服务"
echo "- 安装前信息备份：$BACKUP_DIR"
echo "下一步如需建立 DFS Root，可运行：sudo bash configure-dfs-root.sh"
