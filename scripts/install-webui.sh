#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash install-webui.sh [all|sambly|cockpit]" >&2
  exit 1
fi

MODE="${1:-all}"
case "$MODE" in
  all|sambly|cockpit) ;;
  *)
    echo "用法：sudo bash install-webui.sh [all|sambly|cockpit]" >&2
    exit 2
    ;;
esac

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" ]]; then
  echo "错误：此离线包仅适用于 aarch64/ARM64，当前架构：$ARCH" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
RPM_DIR="$ROOT_DIR/rpms"
SAMBLY_BIN="$ROOT_DIR/webui/sambly/sambly"
LOCAL_REPO_FILE="/etc/yum.repos.d/samba-dfs-webui-offline.repo"

if [[ ! -d "$RPM_DIR/repodata" ]]; then
  echo "错误：缺少离线 RPM 仓库：$RPM_DIR/repodata" >&2
  exit 1
fi

PKG_MGR="dnf"
command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"
if ! command -v "$PKG_MGR" >/dev/null 2>&1; then
  echo "错误：系统中没有 dnf/yum。" >&2
  exit 1
fi

cat > "$LOCAL_REPO_FILE" <<EOF
[samba-dfs-webui-offline]
name=Samba DFS WebUI Offline Repository
baseurl=file://$RPM_DIR
enabled=1
gpgcheck=0
metadata_expire=0
EOF

cleanup() {
  rm -f "$LOCAL_REPO_FILE"
}
trap cleanup EXIT

pkg_install() {
  "$PKG_MGR" -y \
    --disablerepo='*' \
    --enablerepo='samba-dfs-webui-offline' \
    install "$@"
}

ensure_smbd_service_alias() {
  # Sambly upstream currently controls the unit name "smbd". Kylin/RHEL
  # packages normally expose "smb.service". Create a systemd alias so the
  # UI's start/stop/restart/status buttons work without patching Samba itself.
  if systemctl cat smbd.service >/dev/null 2>&1; then
    return 0
  fi

  local smb_unit_path
  smb_unit_path="$(systemctl show -p FragmentPath --value smb.service 2>/dev/null || true)"
  if [[ -z "$smb_unit_path" || ! -f "$smb_unit_path" ]]; then
    smb_unit_path="/usr/lib/systemd/system/smb.service"
  fi

  if [[ -f "$smb_unit_path" ]]; then
    ln -sfn "$smb_unit_path" /etc/systemd/system/smbd.service
    systemctl daemon-reload
    echo "已创建 Sambly 兼容别名：smbd.service -> $smb_unit_path"
  else
    echo "警告：未找到 smb.service，Sambly 的 Samba 服务控制按钮可能不可用。" >&2
  fi
}

install_sambly() {
  echo "== 安装 Sambly =="
  if [[ ! -x "$SAMBLY_BIN" ]]; then
    echo "错误：离线包缺少 ARM64 Sambly：$SAMBLY_BIN" >&2
    exit 1
  fi

  if ! command -v smbd >/dev/null 2>&1 || ! command -v testparm >/dev/null 2>&1; then
    echo "错误：未检测到 Samba Server，请先运行 install.sh。" >&2
    exit 1
  fi

  install -m 0755 "$SAMBLY_BIN" /usr/local/bin/sambly
  ensure_smbd_service_alias

  local port admin_user admin_password
  port="${SAMBLY_PORT:-8090}"
  admin_user="${SAMBLY_ADMIN_USER:-admin}"
  admin_password="${SAMBLY_ADMIN_PASSWORD:-}"

  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "错误：SAMBLY_PORT 必须是 1-65535。" >&2
    exit 1
  fi
  if ! [[ "$admin_user" =~ ^[a-zA-Z0-9_.-]{1,32}$ ]]; then
    echo "错误：SAMBLY_ADMIN_USER 格式不合法。" >&2
    exit 1
  fi

  install -d -m 0750 /var/lib/sambly

  # 仅首次安装写入初始化参数。空密码由 Sambly 自己安全随机生成。
  if [[ ! -f /var/lib/sambly/sambly.db && ! -f /var/lib/sambly/initial-credentials.txt ]]; then
    {
      printf 'ADMIN_USERNAME=%s\n' "$admin_user"
      if [[ -n "$admin_password" ]]; then
        printf 'ADMIN_PASSWORD=%s\n' "$admin_password"
      fi
    } > /var/lib/sambly/setup.env
    chmod 0600 /var/lib/sambly/setup.env
  fi

  cat > /etc/systemd/system/sambly.service <<EOF
[Unit]
Description=Sambly - Samba Web Manager
After=network.target smb.service
Wants=smb.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sambly --addr=0.0.0.0:${port} --data=/var/lib/sambly
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

  echo "Sambly 已安装并启动。"
  echo "访问地址：http://<服务器IP>:${port}"
  echo "状态：systemctl status sambly --no-pager -l"
  echo "日志：journalctl -u sambly -f"
  if [[ -f /var/lib/sambly/initial-credentials.txt ]]; then
    echo "首次登录凭据：/var/lib/sambly/initial-credentials.txt"
    cat /var/lib/sambly/initial-credentials.txt
  else
    echo "已有 Sambly 数据库或服务尚未生成首次凭据。"
  fi
  echo "重要：Sambly 以 root 权限运行，只应开放给可信内网管理网段。"
}

install_cockpit() {
  echo "== 安装 Cockpit + cockpit-file-sharing =="
  pkg_install cockpit cockpit-bridge cockpit-system cockpit-ws cockpit-file-sharing

  systemctl enable --now cockpit.socket

  echo "Cockpit 已安装并启动。"
  echo "访问地址：https://<服务器IP>:9090"
  echo "状态：systemctl status cockpit.socket --no-pager -l"
  echo
  echo "重要提示："
  echo "- cockpit-file-sharing 的 Samba 页面使用 Samba registry/net conf 管理共享。"
  echo "- 现有 /etc/samba/smb.conf 共享默认不会自动出现在其 UI。"
  echo "- 不会由本安装脚本自动执行 Import，也不会自动改写 smb.conf。"
  echo "- DFS Root 配置尤其不要直接 Import；请先备份并确认 include = registry 与 DFS 配置的组合方式。"
}

case "$MODE" in
  sambly)
    install_sambly
    ;;
  cockpit)
    install_cockpit
    ;;
  all)
    install_sambly
    install_cockpit
    ;;
esac

echo
echo "WebUI 安装完成。"
