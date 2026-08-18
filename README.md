# Kylin V10 SP3 ARM64 Samba 离线包

本仓库使用 GitHub Actions 从银河麒麟/麒麟官方更新源下载 **Kylin Linux Advanced Server V10 SP3-2403 aarch64** 对应的 Samba 4.11.12 官方 RPM 及其完整依赖闭包，并打包为可带入离线环境安装的 Release。

目标环境：

- Kylin Linux Advanced Server V10 (Halberd)
- V10 SP3 / 2403
- aarch64 / ARM64
- Samba 4.11.12-32.p11.ky10

Release 包内包含：

- `rpms/`：Samba 服务端、客户端、工具以及通过官方 Base + Updates 仓库解析出的依赖 RPM
- `repodata/`：本地 DNF/YUM 仓库元数据（位于 `rpms/repodata`）
- `install.sh`：离线安装/升级脚本，不覆盖现有 `smb.conf`
- `configure-dfs-root.sh`：可选的 DFS Root 初始化脚本
- `SHA256SUMS`：RPM 与脚本完整性校验
- `packages-manifest.txt`：RPM 清单

## 使用

从 Releases 下载 `kylin-v10sp3-aarch64-samba-4.11.12-p11-offline.tar.gz`，复制到离线麒麟服务器：

```bash
tar -xzf kylin-v10sp3-aarch64-samba-4.11.12-p11-offline.tar.gz
cd kylin-v10sp3-aarch64-samba-4.11.12-p11-offline
sudo bash install.sh
```

安装脚本默认只安装/升级软件包并进行验证，**不会修改 `/etc/samba/smb.conf`，也不会自动启动 Samba 服务**。

如需初始化 DFS Root，可在确认 Samba 安装正常后执行：

```bash
sudo bash configure-dfs-root.sh
```

脚本会先备份已有配置，并生成一个最小 DFS Root 示例；正式使用前应按现场的用户名、组和后端服务器地址调整。

## 软件来源

RPM 仅从麒麟官方仓库下载：

- Base: `https://update.cs2c.com.cn/NS/V10/V10SP3-2403/os/adv/lic/base/aarch64/`
- Updates: `https://update.cs2c.com.cn/NS/V10/V10SP3-2403/os/adv/lic/updates/aarch64/`

GitHub Actions 使用上述仓库的 `repodata` 做依赖解析，避免手工遗漏依赖。
