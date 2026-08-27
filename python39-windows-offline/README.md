# Python 3.9.2 Windows x64 完整离线安装包

目标环境：Windows x64。

这个 artifact 不要求目标电脑预先安装 Python 或 pip，已经包含：

- 官方 CPython 3.9.2 x64 安装程序 `python-3.9.2-amd64.exe`
- Python 自带 pip
- 一份兼容 Python 3.9 的新版 pip 离线 wheel
- `requests>=2.28.0`
- `pandas>=1.5.0`
- `openpyxl>=3.0.0`
- 上述 Python 包所需的全部传递依赖 wheel
- 一键离线安装脚本
- 精确版本清单和 SHA256 校验清单

GitHub Actions 会从 python.org 下载官方 Python 3.9.2 x64 安装程序，验证 Authenticode 签名必须有效且签名者为 Python Software Foundation。随后 Action 使用这份安装程序安装一个全新的 Python 3.9.2，再严格通过 `--no-index` 仅使用 artifact 内的 wheel 完成 pip 升级、依赖安装、模块导入和 `pip check`，以证明离线包完整可用。

## 离线电脑安装

1. 下载 artifact：`python-3.9.2-windows-x64-complete-offline`。
2. 将 ZIP 完整复制到离线 Windows 电脑并解压。
3. 双击或在 CMD 中运行：

```bat
install-offline.bat
```

脚本会为当前 Windows 用户安装到：

```text
%LOCALAPPDATA%\Programs\Python\Python392Offline
```

不需要管理员权限。

脚本同时设置 `PrependPath=1`。安装完成后重新打开一个 CMD 或 PowerShell，即可尝试：

```bat
python --version
python -m pip --version
```

如果电脑原先已经有其他 Python，建议直接使用本包安装的精确路径验证：

```bat
"%LOCALAPPDATA%\Programs\Python\Python392Offline\python.exe" --version
"%LOCALAPPDATA%\Programs\Python\Python392Offline\python.exe" -m pip --version
"%LOCALAPPDATA%\Programs\Python\Python392Offline\python.exe" -c "import requests,pandas,openpyxl; print(requests.__version__, pandas.__version__, openpyxl.__version__)"
```

## 产物说明

- `python-3.9.2-amd64.exe`：python.org 官方 CPython 3.9.2 x64 完整安装程序
- `python-installer-source.txt`：Python 安装程序官方下载地址记录
- `packages/`：pip、requests、pandas、openpyxl 及全部传递依赖的 Windows x64 wheel
- `requirements.txt`：用户要求的版本约束
- `resolved-versions.txt`：Action 实际完整安装并验证后的精确版本
- `SHA256SUMS.txt`：Python 安装程序和所有 wheel 的 SHA256
- `install-offline.bat`：一键安装 Python + pip + 所有依赖

## 已验证的离线流程

Action 的验证不是使用 runner 上已经存在的 Python 来假装通过，而是：

1. 下载并验签官方 `python-3.9.2-amd64.exe`；
2. 用该 EXE 安装到全新的独立目录；
3. 验证解释器严格为 CPython 3.9.2 x64；
4. 验证安装程序内置 pip 可用；
5. 使用 `--no-index` 从本地 wheel 升级 pip；
6. 使用 `--no-index` 从本地 wheel 安装 requirements；
7. 导入 requests、pandas、openpyxl；
8. 执行 `pip check`。
