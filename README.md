# Kylin V10 SP3 ARM64 Samba 4.11 + Sambly 完整离线包

这个仓库用于构建：

**Kylin Linux Advanced Server V10 SP3-2403 aarch64 上可完全离线安装的 Samba 4.11 + Samba DFS + Sambly 管理界面。**

当前方案不再使用“只带 7 个 Samba RPM、依赖目标机现有系统”的最小包。GitHub Actions 会从麒麟官方 ARM64 Base / Updates 仓库递归解析 Samba 的强依赖，下载完整依赖闭包，生成本地 RPM 仓库，并在发布前用一个空 installroot 做纯离线安装验证。

## 目标环境

```text
Kylin Linux Advanced Server V10 (Halberd)
Kylin V10 SP3-2403
aarch64 / ARM64
Samba: 4.11.12-32.p11.ky10
```

已确认的实际目标服务器示例：

```text
Kernel: 4.19.90-52.60.v2207.ky10.aarch64
现有：
samba-client-4.11.12-32.p03.ky10.aarch64
samba-common-4.11.12-32.p03.ky10.aarch64
```

安装脚本会把 Samba 组件统一升级到 p11，并且只使用 Release 内自带的本地 file:// RPM 仓库，不需要目标服务器访问互联网。

## Release 内容

Action 发布：

```text
kylin-v10sp3-aarch64-samba-sambly-full.tar.gz
kylin-v10sp3-aarch64-samba-sambly-full.tar.gz.sha256
```

解压后的主要结构：

```text
kylin-v10sp3-aarch64-samba-sambly-full/
├── rpms/
│   ├── *.aarch64.rpm
│   ├── *.noarch.rpm
│   └── repodata/
├── webui/
│   └── sambly/
│       ├── sambly
│       └── SOURCE.txt
├── licenses/
│   └── Sambly-LICENSE
├── install.sh
├── migrate-samba32-to-411.sh
├── configure-dfs-root.sh
├── add-dfs-target.sh
├── packages-manifest.txt
├── root-packages.txt
├── rpm-requires.txt
├── offline-installroot-packages.txt
├── kylin-repositories.txt
├── SHA256SUMS
└── README.txt
```

RPM 数量不再写死。Action 每次从以下四个固定 Samba 根包开始解析：

```text
samba-4.11.12-32.p11.ky10.aarch64
samba-client-4.11.12-32.p11.ky10.aarch64
samba-common-4.11.12-32.p11.ky10.aarch64
samba-common-tools-4.11.12-32.p11.ky10.aarch64
```

然后使用 `dnf download --resolve --alldeps` 下载递归强依赖。`--alldeps` 的目的是即使 Action 的 ARM64 构建容器已经安装某个兼容依赖，也仍然把该依赖下载进离线包，避免错误依赖构建容器已有软件。

## 完整依赖闭包如何验证

Action 下载完成后会生成 `rpms/repodata/`，然后创建一个空目录作为临时 Linux installroot。

验证阶段只启用：

```text
file://.../rpms
```

所有麒麟在线仓库、Rocky 仓库都会禁用，再执行 Samba 安装事务。

如果任何强依赖没有包含在 Release 中，这一步就会失败，后面的 tar.gz 和 Release 都不会发布。

成功后会保存：

```text
offline-installroot-packages.txt
```

用于记录纯离线验证环境最终安装的所有 RPM。

## RPM 来源

所有 Samba 及其依赖 RPM 只从麒麟 V10 SP3-2403 官方 ARM64 仓库解析：

```text
https://update.cs2c.com.cn/NS/V10/V10SP3-2403/os/adv/lic/base/aarch64/
https://update.cs2c.com.cn/NS/V10/V10SP3-2403/os/adv/lic/updates/aarch64/
```

构建时禁用 Rocky Linux 软件源参与目标 RPM 解析；Rocky ARM64 容器只作为运行 dnf/rpm/createrepo_c 的构建环境。

Sambly 来源：

```text
https://github.com/buadamlaz/Sambly
Pinned commit: 3dab4b2713bc9b4b17f0b903c82600028f44f852
```

Sambly 通过：

```text
CGO_ENABLED=0 GOOS=linux GOARCH=arm64
```

构建为 ARM64 静态二进制，并在 Action 中执行 upstream tests、ELF 架构检查和动态依赖检查。

## 离线安装

把两个 Release 文件复制到离线麒麟服务器：

```text
kylin-v10sp3-aarch64-samba-sambly-full.tar.gz
kylin-v10sp3-aarch64-samba-sambly-full.tar.gz.sha256
```

校验：

```bash
sha256sum -c kylin-v10sp3-aarch64-samba-sambly-full.tar.gz.sha256
```

解压：

```bash
tar -xzf kylin-v10sp3-aarch64-samba-sambly-full.tar.gz
cd kylin-v10sp3-aarch64-samba-sambly-full
```

安装：

```bash
sudo bash install.sh
```

`install.sh` 会先检查：

- 系统必须是 Kylin V10；
- 架构必须是 aarch64；
- `rpms/repodata/repomd.xml` 必须存在；
- SHA256 必须通过；
- 只启用 Release 自带的 `samba-offline-local` 仓库；
- 使用 `tsflags=test` 先执行不落盘的 DNF/YUM 事务检查；
- 预检查成功后才正式安装；
- 不使用 `--nodeps`；
- 不访问互联网软件源；
- 不自动覆盖现有 `/etc/samba/smb.conf`；
- 不自动启动 Samba 文件服务。

安装前会备份现有 Samba 配置和 RPM 清单到：

```text
/root/samba-sambly-backup-YYYYmmdd-HHMMSS/
```

## Samba 3.2 原机迁移到 4.11

针对 `/usr/local/samba` 源码安装的 Samba 3.2 + `tdbsam` 老服务器，完整包额外提供：

```text
migrate-samba32-to-411.sh
```

目标是保持以下内容不变：

- 服务器 IP；
- 共享名称和共享路径；
- Linux 用户以及 UID/GID/组关系；
- Samba 用户；
- Samba NT 密码哈希；
- Samba 用户 SID；
- Samba 本机 SID；
- 共享目录现有 owner/group/mode/大小元数据。

旧 `/usr/local/samba` 不删除，保留作为回退路径。新 Samba 使用 RPM 安装到系统路径，最低协议明确设置为 SMB2_02。

先执行只读准备：

```bash
sudo bash migrate-samba32-to-411.sh \
  --prepare \
  --test-user wuhongguang \
  --test-share ledong_share
```

`--prepare` 会：

1. 确认 Kylin V10 / ARM64 / 旧源码 Samba 路径；
2. 确认旧认证后端是 `tdbsam`；
3. 记录 Samba 版本、配置、用户、SID、TDB 清单、RPM 清单；
4. 完整备份 `/usr/local/samba`、Linux 用户/组数据库及已有系统 Samba 目录；
5. 生成密码指纹、用户 SID 指纹、Linux 身份指纹；
6. 调用 `install.sh --dry-run` 验证离线 RPM 事务；
7. 不停止旧 Samba，不安装 RPM。

确认准备结果后执行正式迁移：

```bash
sudo bash migrate-samba32-to-411.sh \
  --apply \
  --test-user wuhongguang \
  --test-share ledong_share
```

脚本会在终端安全提示输入测试账号的当前 Samba 密码。密码不会作为命令行参数写入，也不会提交到仓库或迁移报告；实际验证使用临时 `0600` 凭据文件，退出时删除。

`--apply` 会：

1. 在旧 `smbd` 仍运行时安装 Samba 4.11 RPM；`install.sh` 本身不启动 Samba 文件服务；
2. 用 Samba 4.11 `testparm` 预检迁移后的配置；
3. 默认拒绝在存在活动 SMB 会话时切换；
4. 停旧 Samba 后重新做一致性备份；
5. 使用 Samba 4.11 `pdbedit -i/-e` 从旧 `passdb.tdb` 副本迁移 `tdbsam` 数据；
6. 使用原 `net getlocalsid` / `net setlocalsid` 保持本机 SID；
7. 比对 Samba 用户名、UID/NT 密码指纹、用户 SID 指纹、Linux UID/GID/组指纹；
8. 比对共享目录文件权限元数据指纹；
9. 全部一致后才启动 `smb.service`；
10. 使用指定测试账号执行真实 SMB3 `smbclient` 登录与目录浏览；
11. 任一关键检查失败时自动停新服务并尝试恢复旧 `/usr/local/samba/sbin/smbd -D` / `nmbd -D`。

人工回退入口：

```bash
sudo bash migrate-samba32-to-411.sh --rollback
```

不要把生产密码写进 GitHub Actions workflow、README 或命令行参数。测试账号可以作为参数公开，密码只在目标服务器交互输入。

## Sambly

默认启动在：

```text
http://<服务器IP>:8090
```

可预先指定管理员账号、密码和端口：

```bash
sudo SAMBLY_ADMIN_USER=admin \
     SAMBLY_ADMIN_PASSWORD='替换成强密码' \
     SAMBLY_PORT=8090 \
     bash install.sh
```

不指定密码时，首次启动后查看：

```bash
cat /var/lib/sambly/initial-credentials.txt
```

8090 只建议对可信管理网络开放。

## 配置 Samba DFS 入口

Samba 安装完成后：

```bash
sudo bash configure-dfs-root.sh
```

脚本会创建：

```text
/srv/dfs
```

并配置：

```ini
host msdfs = yes

[files]
    path = /srv/dfs
    msdfs root = yes
```

同时将最低 SMB 协议设置为 SMB2，执行 `testparm` 成功后才替换正式配置，并启动 `smb.service`。

## 添加后端服务器

例如：

```bash
sudo bash add-dfs-target.sh kylin01 192.168.88.211 ledong_share
sudo bash add-dfs-target.sh kylin02 192.168.88.212 ledong_share
sudo bash add-dfs-target.sh kylin03 192.168.88.213 ledong_share
```

最终 Windows 只需要添加：

```text
\\<DFS服务器IP>\files
```

即可看到：

```text
kylin01
kylin02
kylin03
```

Windows 进入某个 DFS 目录后会根据 referral 直接连接对应后端 Samba 服务器，DFS 入口主要负责统一命名空间，不承担所有业务文件数据转发。

## Action 发布门槛

完整 Release 只有在以下条件全部满足后才会创建：

1. Shell 脚本静态语法检查通过；
2. Samba 3.2 迁移脚本包含 prepare/apply/rollback、安全密码输入、tdbsam 导入、SID/密码/UID/GID/共享元数据校验和自动回退保护；
3. 从麒麟官方仓库成功解析并下载完整 Samba 强依赖闭包；
4. RPM 只允许 `aarch64` 和 `noarch`；
5. 四个固定 Samba p11 根包存在；
6. 本地 `repodata` 成功生成；
7. 空 installroot 在完全禁用在线仓库的情况下成功安装 Samba；
8. Sambly upstream tests 通过；
9. Sambly 为 ARM64 静态 ELF；
10. 包内 SHA256 全部验证通过；
11. 最终 tar.gz 再次解压，并再次对迁移脚本执行语法/关键保护项审计。

PR 只执行快速静态检查；合并到 `main` 后才执行完整 ARM64 下载、纯离线验证、打包并发布 Release。
