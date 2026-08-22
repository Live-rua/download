#!/usr/bin/env bash
set -euxo pipefail

: "${REQUESTS_VERSION:?REQUESTS_VERSION is required}"
: "${PILLOW_VERSION:?PILLOW_VERSION is required}"
: "${SOURCE_SHA256:?SOURCE_SHA256 is required}"

PY=/opt/python/cp311-cp311/bin/python
NAME=face-device-offline-kylin-v10sp3-arm64-python311
PKG=/io/dist/$NAME

"$PY" --version
ldd --version

PYTHON_RUNTIME_VERSION="$($PY -c 'import platform; print(platform.python_version())')"
GLIBC_RUNTIME_VERSION="$(ldd --version 2>&1 | sed -n '1s/.* //p')"

"$PY" -m pip install --disable-pip-version-check --no-cache-dir \
  "requests==$REQUESTS_VERSION" \
  "Pillow==$PILLOW_VERSION"

rm -rf "$PKG"
mkdir -p "$PKG/python"
cp -a /opt/python/cp311-cp311/. "$PKG/python/"
cp /io/face-device-offline/face_device_menu.py "$PKG/face_device_menu.py"

cat > "$PKG/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ;;
  *) echo "错误：此包只支持 ARM64/aarch64，当前架构：$ARCH" >&2; exit 2 ;;
esac
export PYTHONUTF8=1
export PYTHONHOME="$ROOT/python"
export LD_LIBRARY_PATH="$ROOT/python/lib:$ROOT/python/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$ROOT/python/bin/python3.11" "$ROOT/face_device_menu.py" "$@"
RUNEOF
chmod +x "$PKG/run.sh"

cat > "$PKG/README_OFFLINE.txt" <<EOF
Face Device Tool - 麒麟 V10 SP3 ARM64 离线可移植版
======================================================
Python: $PYTHON_RUNTIME_VERSION (ARM64)
Runtime baseline: manylinux_2_28 / glibc $GLIBC_RUNTIME_VERSION
requests: $REQUESTS_VERSION
Pillow: $PILLOW_VERSION
Source SHA256: $SOURCE_SHA256

使用：
  tar -xzf face-device-offline-kylin-v10sp3-arm64-python311.tar.gz
  cd face-device-offline-kylin-v10sp3-arm64-python311
  chmod +x run.sh
  ./run.sh

目标机无需联网、无需安装 Python、无需执行 pip install。
脚本仍需要通过局域网访问实际人脸设备的 IP 和端口。
EOF

cat > "$PKG/BUILD_INFO.json" <<EOF
{
  "platform": "linux-arm64-kylin-v10sp3",
  "runtime_baseline": "manylinux_2_28",
  "minimum_glibc": "2.28",
  "build_glibc": "$GLIBC_RUNTIME_VERSION",
  "python": "$PYTHON_RUNTIME_VERSION",
  "requests": "$REQUESTS_VERSION",
  "pillow": "$PILLOW_VERSION",
  "source_sha256": "$SOURCE_SHA256",
  "portable": true,
  "target_requires_python": false,
  "target_requires_internet": false
}
EOF

# Verify the copied runtime, not the original /opt/python prefix.
file "$PKG/python/bin/python3.11"
file "$PKG/python/bin/python3.11" | grep -Eiq 'aarch64|ARM'

echo "$SOURCE_SHA256  $PKG/face_device_menu.py" | sha256sum -c -

PYTHONHOME="$PKG/python" \
LD_LIBRARY_PATH="$PKG/python/lib:$PKG/python/lib64" \
"$PKG/python/bin/python3.11" -c \
'import requests; from PIL import Image; import py_compile; py_compile.compile("/io/dist/face-device-offline-kylin-v10sp3-arm64-python311/face_device_menu.py", doraise=True); print("Kylin ARM64 relocated-runtime smoke test OK")'

# Ensure the launcher is syntactically valid without contacting a device.
bash -n "$PKG/run.sh"

printf 'runtime_python=%s\n' "$PYTHON_RUNTIME_VERSION"
printf 'runtime_glibc=%s\n' "$GLIBC_RUNTIME_VERSION"
printf 'build_result=OK\n'
