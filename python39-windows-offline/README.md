# Python 3.9.2 Windows 离线依赖包

目标环境：Windows x64 + CPython 3.9.2。

包含直接依赖：

- requests>=2.28.0
- pandas>=1.5.0
- openpyxl>=3.0.0

GitHub Actions 会同时下载这些包在 Python 3.9 / Windows x64 下所需的全部传递依赖，并执行一次无网络安装验证。

## 离线安装

1. 从 GitHub Actions 下载 artifact：`python-3.9.2-windows-x64-offline`。
2. 解压到目标 Windows 机器。
3. 确认 `python --version` 为 Python 3.9.x。
4. 双击或在 CMD 中运行：

```bat
install-offline.bat
```

等价手工命令：

```bat
python -m pip install --no-index --find-links packages -r requirements.txt
```

## 产物说明

- `packages/`：wheel 离线包及全部依赖
- `requirements.txt`：原始版本约束
- `resolved-versions.txt`：Action 实际解析并验证通过的精确版本
- `SHA256SUMS.txt`：所有 wheel 的 SHA256
- `install-offline.bat`：Windows 一键离线安装脚本
