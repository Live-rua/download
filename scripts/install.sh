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
  echo "错误：此包仅针对 Kylin Linux Advanced Server V10，当前：${PRETTY_NAME:-unknown}" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPM_DIR="$ROOT_DIR/rpms"
SAMBLY_BIN="$ROOT_DIR/webui/sambly/sambly"
EXPECTED_VERSION="4.11.12-32.p11.ky10"

if [[ ! -d "$RPM_DIR" ]]; then
  echo "错误：找不到 RPM 目录：$RPM_DIR" >&2
  exit 1
fi
if [[ ! -x "$SAMBLY_BIN" ]]; then
  echo "错误：找不到 Sambly ARM64 二进制：$SAMBLY_BIN" >&2
  exit 1
fi

EXPECTED_PACKAGES=(
  samba
  samba-libs
  samba-common-tools
  samba-client
  samba-common
  libwbclient
  libsmbclient
)

rpm_files=()
for pkg in "${EXPECTED_PACKAGES[@]}"; do
  matches=("$RPM_DIR/${pkg}-${EXPECTED_VERSION}.aarch64.rpm")
  if [[ ! -f "${matches[0]}" ]]; then
    echo "错误：缺少 ${pkg}-${EXPECTED_VERSION}.aarch64.rpm" >&2
    exit 1
  fi
  rpm_files+=("${matches[0]}")
done

actual_count="$(find "$RPM_DIR" -maxdepth 1 -type f -name '*.rpm' | wc -l)"
if [[ "$actual_count" -ne 7 ]]; then
  echo "错误：最小包应恰好包含 7 个 RPM，当前：$actual_count" >&2
  exit 1
fi

if [[ -f "$ROOT_DIR/SHA256SUMS" ]]; then
  echo "== 校验离线包完整性 =="
  (cd "$ROOT_DIR" && sha256sum -c SHA256SUMS)
fi

BACKUP_DIR="/root/samba-sambly-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
rpm -qa | grep -E '^(samba|libwbclient|libsmbclient|libtalloc|libtdb|libtevent|libldb)' | sort \
  > "$BACKUP_DIR/packages-before.txt" || true
if [[ -f /etc/samba/smb.conf ]]; then
  cp -a /etc/samba/smb.conf "$BACKUP_DIR/smb.conf"
fi
if [[ -d /var/lib/samba/private ]]; then
  cp -a /var/lib/samba/private "$BACKUP_DIR/samba-private" 2>/dev/null || true
fi

echo "== 当前 Samba 相关包 =="
cat "$BACKUP_DIR/packages-before.txt" || true

echo
echo "== RPM 事务预检查（不会修改系统） =="
if ! rpm -Uvh --test "${rpm_files[@]}"; then
  echo >&2
  echo "依赖预检查失败，未安装任何软件。" >&2
  echo "请把上面的缺失依赖原样反馈，不要使用 --nodeps 强制安装。" >&2
  exit 2
fi

echo
echo "== 安装/升级最小 Samba 4.11 p11 组件 =="
if command -v dnf >/dev/null 2>&1; then
  dnf -y --disablerepo='*' install "${rpm_files[@]}"
elif command -v yum >/dev/null 2>&1; then
  yum -y --disablerepo='*' localinstall "${rpm_files[@]}"
else
  echo "错误：系统中未找到 dnf/yum。" >&2
  exit 1
fi

echo
echo "== Samba 安装验证 =="
command -v smbd
command -v testparm
smbd -V
testparm -s >/dev/null
rpm -qa | grep -E '^(samba|libwbclient|libsmbclient)' | sort

# Sambly 上游使用 smbd.service 控制 Samba；Kylin/RHEL RPM 通常提供 smb.service。
# 创建 systemd alias，使 UI 的启停/重启按钮可以直接工作。
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
echo "== 安装 Sambly ARM64 单二进制 =="
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
  } > /var/lib/sambly/setup.env
  chmod 0600 /var/lib/sambly/setup.env
fi

cat > /etc/systemd/system/sambly.service <<EOF
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
systemctl enable --now sambly

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
  echo "首次登录凭据："
  cat /var/lib/sambly/initial-credentials.txt
  echo "登录并修改密码后建议删除该凭据文件。"
fi
echo
echo "注意：本脚本没有启动 Samba，也没有修改现有 smb.conf。"
echo "安装前备份：$BACKUP_DIR"
echo "下一步在 DFS 入口服务器运行：sudo bash configure-dfs-root.sh"
