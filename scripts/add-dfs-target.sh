#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 root 运行。" >&2
  exit 1
fi

if [[ $# -ne 3 ]]; then
  echo "用法：bash add-dfs-target.sh <显示名称> <后端服务器IP或主机名> <共享名>" >&2
  echo "示例：bash add-dfs-target.sh kylin01 192.168.88.211 ledong_share" >&2
  exit 2
fi

NAME="$1"
SERVER="$2"
SHARE="$3"
DFS_DIR="/srv/dfs"
LINK="$DFS_DIR/$NAME"

if [[ "$NAME" == */* || "$NAME" == "." || "$NAME" == ".." ]]; then
  echo "错误：显示名称不能包含 /，也不能是 . 或 .." >&2
  exit 1
fi
if [[ "$SERVER" == *'\\'* || "$SERVER" == */* || -z "$SERVER" ]]; then
  echo "错误：后端服务器格式不正确。" >&2
  exit 1
fi
if [[ "$SHARE" == *'\\'* || "$SHARE" == */* || -z "$SHARE" ]]; then
  echo "错误：共享名格式不正确。" >&2
  exit 1
fi

if [[ ! -d "$DFS_DIR" ]]; then
  echo "错误：$DFS_DIR 不存在，请先运行 configure-dfs-root.sh。" >&2
  exit 1
fi

if [[ -e "$LINK" || -L "$LINK" ]]; then
  if [[ "${REPLACE_DFS_TARGET:-0}" != "1" ]]; then
    echo "错误：$LINK 已存在。若确认替换：" >&2
    echo "  REPLACE_DFS_TARGET=1 bash add-dfs-target.sh '$NAME' '$SERVER' '$SHARE'" >&2
    exit 3
  fi
  rm -f "$LINK"
fi

TARGET="msdfs:${SERVER}\\${SHARE}"
ln -s "$TARGET" "$LINK"

echo "已添加 DFS 目录："
ls -l "$LINK"
echo
echo "Windows 中将显示：$NAME"
echo "实际后端：\\\\${SERVER}\\${SHARE}"
echo "无需重启 Samba。"
