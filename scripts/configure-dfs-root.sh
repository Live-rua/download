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
TMP_CONF="${CONF}.new-${STAMP}"

mkdir -p "$DFS_DIR"
chmod 0755 "$DFS_DIR"
mkdir -p /var/log/samba

if [[ -f "$CONF" ]]; then
  cp -a "$CONF" "${CONF}.bak-${STAMP}"
  echo "已备份：${CONF}.bak-${STAMP}"

  # 新服务器的系统默认配置通常只有 global/homes/printers/print$。
  # 如果已经存在业务共享，不默认覆盖，避免误删现有共享。
  custom_sections="$(awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      s=$0
      gsub(/^[[:space:]]*\[/,"",s)
      gsub(/\][[:space:]]*$/,"",s)
      l=tolower(s)
      if (l!="global" && l!="homes" && l!="printers" && l!="print$") print s
    }
  ' "$CONF" | sort -u)"

  if [[ -n "$custom_sections" && "${FORCE_DFS_CONFIG:-0}" != "1" ]]; then
    echo "检测到已有自定义共享，默认停止以避免覆盖：" >&2
    echo "$custom_sections" >&2
    echo >&2
    echo "确认这些共享可以被新的 DFS Root 配置替换后，再执行：" >&2
    echo "  FORCE_DFS_CONFIG=1 bash configure-dfs-root.sh" >&2
    exit 2
  fi
fi

cat > "$TMP_CONF" <<'EOF'
[global]
        workgroup = SAMBA
        server role = standalone server
        security = user

        # Samba 4.x 只提供现代 SMB；Windows 不需要开启 SMB1/CIFS 客户端。
        server min protocol = SMB2_02

        # 开启 Samba MSDFS / DFS referral。
        host msdfs = yes

        # DFS 入口不提供打印服务。
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
EOF

echo "== testparm 配置检查 =="
testparm -s "$TMP_CONF"
install -m 0644 "$TMP_CONF" "$CONF"
rm -f "$TMP_CONF"

# Kylin/RHEL Samba RPM 的服务名通常是 smb.service。
if systemctl cat smb.service >/dev/null 2>&1; then
  systemctl enable --now smb.service
else
  echo "错误：没有找到 smb.service。" >&2
  exit 3
fi

echo
echo "== Samba 状态 =="
systemctl status smb.service --no-pager -l || true
ss -lntp 2>/dev/null | grep -E ':(445|139)[[:space:]]' || true

echo
echo "DFS Root 已配置完成。"
echo "DFS 目录：$DFS_DIR"
echo "Windows 统一入口：\\\\<DFS服务器IP>\\files"
echo
echo "下一步："
echo "1. 先通过 Sambly 创建至少一个 Samba 用户。"
echo "2. 使用 add-dfs-target.sh 添加后端服务器，例如："
echo "   bash add-dfs-target.sh kylin01 192.168.88.211 ledong_share"
echo "   bash add-dfs-target.sh kylin02 192.168.88.212 ledong_share"
