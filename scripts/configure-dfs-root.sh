#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash configure-dfs-root.sh" >&2
  exit 1
fi

if ! command -v smbd >/dev/null 2>&1 || ! command -v testparm >/dev/null 2>&1; then
  echo "错误：未检测到 Samba Server，请先运行 install.sh。" >&2
  exit 1
fi

DFS_DIR="/srv/dfs"
CONF="/etc/samba/smb.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DFS_DIR"
chmod 0755 "$DFS_DIR"

if [[ -f "$CONF" ]]; then
  cp -a "$CONF" "${CONF}.bak-${STAMP}"
  echo "已备份：${CONF}.bak-${STAMP}"
fi

cat > "$CONF" <<'EOF'
[global]
        workgroup = SAMBA
        security = user

        # 仅启用现代 SMB；Windows 无需 SMB1/CIFS 客户端。
        server min protocol = SMB2

        # 开启 Microsoft DFS / Samba MSDFS 支持。
        host msdfs = yes

        # DFS 入口不承担打印服务。
        load printers = no
        printing = bsd
        printcap name = /dev/null
        disable spoolss = yes

        log file = /var/log/samba/log.%m
        max log size = 1000

[files]
        comment = Unified DFS Root
        path = /srv/dfs
        browseable = yes
        read only = yes
        guest ok = no
        msdfs root = yes

        # 正式使用时建议启用并替换为现场统一 Samba 用户组：
        # valid users = @ledong
EOF

echo "== testparm 配置检查 =="
testparm -s "$CONF"

echo
echo "DFS Root 配置已生成：$CONF"
echo "DFS 目录：$DFS_DIR"
echo
echo "接入后端示例（请替换服务器名/IP和共享名）："
echo "  ln -s 'msdfs:kylin01\\ledong_share' '$DFS_DIR/kylin01'"
echo "  ln -s 'msdfs:kylin02\\ledong_share' '$DFS_DIR/kylin02'"
echo
echo "确认配置后可启动："
echo "  systemctl enable --now smb"
echo "  systemctl status smb --no-pager -l"
echo
echo "Windows 访问：\\\\<DFS服务器IP>\\files"
