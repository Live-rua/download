# Kylin V10 SP3 ARM64 Samba DFS + WebUI 离线包

本仓库通过 GitHub Actions 为 **Kylin Linux Advanced Server V10 SP3-2403 aarch64** 构建一套可直接带入离线环境的 Samba 文件服务工具包。

目标场景：

- 多台麒麟 ARM 服务器运行 Samba 4.x；
- 一台 Samba DFS Root 作为 Windows 的统一入口；
- Windows 只添加一个网络位置，例如 `\\files-gw\\files`；
- 管理员希望通过 Web UI 管理 Samba 用户、组、共享目录和权限；
- 服务器无法访问互联网，因此安装介质必须包含完整依赖。

## Release 内容

生成的压缩包：

`kylin-v10sp3-aarch64-samba-dfs-webui-offline.tar.gz`

目录结构：

```text
kylin-v10sp3-aarch64-samba-dfs-webui-offline/
├── rpms/                         # Samba/Cockpit/插件及完整 RPM 依赖闭包
│   └── repodata/                 # 本地 DNF/YUM 仓库
├── webui/
│   └── sambly/
│       ├── sambly                # Linux ARM64 静态单二进制
│       └── SOURCE.txt
├── licenses/
├── install.sh                    # 仅安装/升级 Samba
├── install-webui.sh              # 安装 Sambly / Cockpit
├── install-all.sh                # Samba + 两套 WebUI 一键安装
├── configure-dfs-root.sh         # DFS Root 初始化助手
├── packages-manifest.txt
├── cockpit-file-sharing-requires.txt
├── SHA256SUMS
└── README.txt
```

## 包含的软件

### Samba 4.x

Samba Server、Client、Common、Common Tools 以及依赖全部从麒麟 V10 SP3-2403 官方 Base / Updates ARM64 仓库解析下载。

安装脚本不会自动替换现有 `/etc/samba/smb.conf`，也不会自动把普通服务器改成 DFS Root。

### Sambly

Sambly 是专门管理 Samba 的轻量 Web UI。本 Action 从 `buadamlaz/Sambly` 的固定提交构建 Linux ARM64 静态单二进制，并放进离线包。

主要用途：

- 新建、删除、启用/禁用 Samba 用户；
- 创建 Linux 用户和组、调整组成员；
- 修改 Samba 密码；
- 新建、修改、删除共享；
- 配置 `valid users`、`write list`；
- 管理共享目录及常用权限；
- 编辑和验证 `smb.conf`；
- 启停/重启 Samba；
- 操作审计。

默认地址：`http://<服务器IP>:8090`

> Sambly 以 root 身份运行，只应开放给可信内网管理网段，不应暴露到公网。

### Cockpit + cockpit-file-sharing

同时打包麒麟官方 Cockpit 运行组件，以及 45Drives 的 `cockpit-file-sharing` 插件。

主要用途：

- Cockpit 系统原生 Web 管理控制台；
- Samba 全局参数管理；
- Samba 用户密码管理；
- Samba/NFS 共享管理；
- 共享目录权限管理；
- 服务和系统状态管理。

默认地址：`https://<服务器IP>:9090`

**重要：** `cockpit-file-sharing` 的 Samba 页面使用 Samba registry / `net conf` 管理共享。已有 `/etc/samba/smb.conf` 中手工配置的共享不会自动显示；插件提供 Import 功能，但 Import 会改变配置管理方式。因此本离线安装脚本只安装插件，**绝不自动 Import、绝不自动把 DFS Root 配置迁移到 registry**。

Sambly 与 cockpit-file-sharing 可以同时安装，但不建议同时编辑同一批共享：

- Sambly 直接读写 `/etc/samba/smb.conf`，并且能创建 Linux/Samba 用户和组；
- cockpit-file-sharing 主要通过 Samba registry / `net conf` 管理共享；
- 对现有 `smb.conf` 和 DFS Root，默认建议以 **Sambly** 作为 Samba 配置管理 UI；
- 只有明确决定迁移到 registry 管理时，再使用 Cockpit 的 Import 功能。

## 安装

推荐全部安装：

```bash
tar -xzf kylin-v10sp3-aarch64-samba-dfs-webui-offline.tar.gz
cd kylin-v10sp3-aarch64-samba-dfs-webui-offline
sudo bash install-all.sh
```

仅安装 Samba：

```bash
sudo bash install.sh
```

仅安装 Web UI：

```bash
sudo bash install-webui.sh all
```

也可以单独安装：

```bash
sudo bash install-webui.sh sambly
sudo bash install-webui.sh cockpit
```

Sambly 支持通过环境变量进行无交互初始化：

```bash
sudo SAMBLY_PORT=8090 \
     SAMBLY_ADMIN_USER=admin \
     SAMBLY_ADMIN_PASSWORD='替换成强密码' \
     bash install-webui.sh sambly
```

如果不设置 `SAMBLY_ADMIN_PASSWORD`，首次启动由 Sambly 生成随机密码，可在下面文件查看：

```bash
cat /var/lib/sambly/initial-credentials.txt
```

安装脚本不会自动修改防火墙。如果服务器启用了防火墙，需要按现场安全策略放行管理网段访问 Sambly `8090/tcp` 和 Cockpit `9090/tcp`。

## 校验离线包

下载 `.tar.gz` 与 `.tar.gz.sha256` 后先校验外层压缩包：

```bash
sha256sum -c kylin-v10sp3-aarch64-samba-dfs-webui-offline.tar.gz.sha256
```

解压后还可以验证包内全部 RPM、脚本和 Sambly 二进制：

```bash
cd kylin-v10sp3-aarch64-samba-dfs-webui-offline
sha256sum -c SHA256SUMS
```

## 配置 DFS Root

确认 Samba 安装正常后，在作为统一入口的服务器执行：

```bash
sudo bash configure-dfs-root.sh
```

它会：

1. 备份已有 `/etc/samba/smb.conf`；
2. 创建 `/srv/dfs`；
3. 配置 `[files]` 为 `msdfs root = yes`；
4. 使用 `testparm` 验证配置；
5. 给出后端 DFS 链接示例。

例如：

```bash
cd /srv/dfs
ln -s 'msdfs:kylin01\\ledong_share' kylin01
ln -s 'msdfs:kylin02\\ledong_share' kylin02
ln -s 'msdfs:kylin03\\ledong_share' kylin03
```

Windows 最终访问：

```text
\\<DFS服务器IP>\files
```

## 软件来源与构建方式

Kylin RPM：

- Base: `https://update.cs2c.com.cn/NS/V10/V10SP3-2403/os/adv/lic/base/aarch64/`
- Updates: `https://update.cs2c.com.cn/NS/V10/V10SP3-2403/os/adv/lic/updates/aarch64/`

第三方开源组件：

- Sambly: `https://github.com/buadamlaz/Sambly`
- cockpit-file-sharing: `https://github.com/45Drives/cockpit-file-sharing`

完整构建使用 ARM64 容器解析麒麟仓库依赖，并把 `BUNDLE_NAME` 显式传入容器。生成本地 RPM 仓库后，Action 会关闭所有联网仓库、仅使用刚生成的 `rpms/` 再做一次依赖解析，从而验证离线依赖闭包。

为避免在 PR 修改过程中反复消耗完整 ARM64 构建时间：

- Pull Request 只运行几秒级的脚本/输入静态检查；
- 手动 `workflow_dispatch` 才执行完整离线包构建，但不会发布 Release；
- 合并/推送到 `main` 执行完整构建，通过后发布或更新 GitHub Release；
- 正式打包前还会再次解压生成的 `.tar.gz`，校验外层 SHA256、包内 `SHA256SUMS`、脚本语法、RPM 数量和 Sambly ARM64 二进制。
