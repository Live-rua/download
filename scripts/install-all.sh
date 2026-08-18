#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash install-all.sh" >&2
  exit 1
fi

echo "============================================================"
echo "  Kylin V10 SP3 ARM64 - Samba DFS + WebUI Offline Installer"
echo "============================================================"
echo

echo "[1/2] 安装/升级 Samba 4.x 与基础工具"
bash "$ROOT_DIR/install.sh"

echo
echo "[2/2] 安装 Sambly + Cockpit + cockpit-file-sharing"
bash "$ROOT_DIR/install-webui.sh" all

echo
echo "全部组件安装完成。"
echo "- Samba 配置不会由 install-all.sh 自动替换。"
echo "- 如本机作为 DFS 入口，再单独运行：sudo bash configure-dfs-root.sh"
echo "- Sambly: http://<服务器IP>:${SAMBLY_PORT:-8090}"
echo "- Cockpit: https://<服务器IP>:9090"
