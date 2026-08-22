# Face Device Tool 离线可移植包

本目录用于通过 GitHub Actions 将 `face_device_menu.py` 打包为两个**无需目标机联网、无需目标机预装 Python**的可移植包。

## 产物

- `face-device-offline-windows-amd64-python311.zip`
  - Windows x64 / AMD64
  - 内置 CPython 3.11.9 embeddable runtime
  - 内置 `requests`、`Pillow`
  - 解压后运行 `run.bat`

- `face-device-offline-kylin-v10sp3-arm64-python311.tar.gz`
  - Linux ARM64 / aarch64，面向麒麟 V10 SP3
  - 内置 CPython 3.11 ARM64 运行环境
  - 在固定摘要的 `manylinux_2_28_aarch64` 镜像内制作，glibc 基线为 2.28
  - 当前固定镜像中的 CPython 为 3.11.16；最终实际版本会同时写入压缩包的 `BUILD_INFO.json`
  - 内置 `requests`、`Pillow`
  - 解压后运行 `./run.sh`

每个压缩包同时生成一个 `.sha256` 校验文件。

## 源脚本一致性

由于该脚本来自会话上传文件，仓库中以 Base64 分片保存于 `source/`。Action 会按文件名顺序拼接、解码，并强制校验：

```text
SHA256 565ef5068f083e1af6336919f8e33d74f11bf2da80bc43b6638bebbe21e75f8f
```

若任何分片损坏、缺失或顺序错误，构建立即失败。

## 依赖版本

- Windows Python: 3.11.9
- 麒麟 ARM64 Python: CPython 3.11.x（当前固定构建镜像为 3.11.16）
- requests: 2.32.5
- Pillow: 11.3.0

这些依赖会在 GitHub Actions 联网环境中下载并装入最终包；目标离线环境不再执行 `pip install`。

## Windows 使用

1. 解压 ZIP。
2. 将待上传的人脸图片放在解压目录中（脚本按当前工作目录扫描图片）。
3. 双击 `run.bat`，或在 CMD / PowerShell 中执行：

```bat
run.bat
```

## 麒麟 ARM64 使用

```bash
tar -xzf face-device-offline-kylin-v10sp3-arm64-python311.tar.gz
cd face-device-offline-kylin-v10sp3-arm64-python311
chmod +x run.sh
./run.sh
```

`run.sh` 会检查当前 CPU 是否为 ARM64/aarch64，并设置包内 `PYTHONHOME`、`LD_LIBRARY_PATH` 后启动脚本。

## 构建验证

Action 会执行：

- 原始脚本 SHA256 校验；
- Python 运行时启动测试；
- `requests` 导入测试；
- `Pillow` 导入测试；
- `face_device_menu.py` 语法编译测试；
- Linux ARM64 可执行文件架构检查；
- 从最终复制目录启动 ARM64 Python，验证运行时确实可重定位；
- `run.sh` 语法检查；
- 最终压缩包 SHA256 生成。

实际设备接口测试仍需在能够访问设备 IP/端口的现场网络环境中执行。
