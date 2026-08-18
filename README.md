# Kylin V10 SP3 ARM64 Samba 4.11 + Sambly 最小离线包

这个仓库现在只针对当前确定的部署方式：

**新麒麟 ARM 服务器原生部署 Samba 4.11 + Sambly，并作为 Samba DFS 统一入口。**

不使用 Docker，不在默认包里安装 Cockpit，也不下载“空白系统完整依赖闭包”。

## 目标服务器

已确认的目标环境：

```text
Kylin Linux Advanced Server V10 (Halberd)
Kernel: 4.19.90-52.60.v2207.ky10.aarch64
Architecture: aarch64

现有：
samba-client-4.11.12-32.p03.ky10.aarch64
samba-common-4.11.12-32.p03.ky10.aarch64
libldb-2.0.12-4.ky10.aarch64
libtalloc-2.3.1-1.ky10.aarch64
libtdb-1.4.2-7.ky10.aarch64
libtevent-0.10.2-1.ky10.aarch64
libwbclient-4.11.12-32.p03.ky10.aarch64
libsmbclient-4.11.12-32.p03.ky10.aarch64
```

因此 Release 不再携带几百个系统 RPM，而只补齐/统一升级当前 Samba 组件。

## Release 内容

生成：

```text
kylin-v10sp3-aarch64-samba-sambly-minimal.tar.gz
kylin-v10sp3-aarch64-samba-sambly-minimal.tar.gz.sha256
```

包内：

```text
kylin-v10sp3-aarch64-samba-sambly-minimal/
├── rpms/
│   ├── samba-4.11.12-32.p11.ky10.aarch64.rpm
│   ├── samba-libs-4.11.12-32.p11.ky10.aarch64.rpm
│   ├── samba-common-tools-4.11.12-32.p11.ky10.aarch64.rpm
│   ├── samba-client-4.11.12-32.p11.ky10.aarch64.rpm
│   ├── samba-common-4.11.12-32.p11.ky10.aarch64.rpm
│   ├── libwbclient-4.11.12-32.p11.ky10.aarch64.rpm
│   └── libsmbclient-4.11.12-32.p11.ky10.aarch64.rpm
├── webui/
│   └── sambly/
│       ├── sambly
│       └── SOURCE.txt
├── licenses/
├── install.sh
├── configure-dfs-root.sh
├── add-dfs-target.sh
├── packages-manifest.txt
├── rpm-requires.txt
├── SHA256SUMS
└── README.txt
```

RPM 均从麒麟 V10 SP3-2403 官方 ARM64 Base / Updates 仓库获取。Sambly 从固定 commit 构建为 Linux ARM64 静态单二进制。

## 为什么只有 7 个 RPM

这不是给“完全空白系统”准备的通用安装介质，而是针对上面已经确认过的这台麒麟服务器。

当前系统已经存在 Samba 所需的大量基础库，所以只需要：

1. 安装 Samba Server；
2. 补上 `samba-libs`、`samba-common-tools`；
3. 把现有 p03 的 Samba Client/Common/libwbclient/libsmbclient 一起升级到 p11，避免同一套 Samba 组件混用不同 patch release。

安装脚本不会盲目强装。正式修改系统前会先执行：

```bash
rpm -Uvh --test rpms/*.rpm
```

只有依赖预检查成功才继续安装。如果另一台麒麟缺依赖，脚本会停止，并要求根据实际缺失项补包；**不要使用 `--nodeps`**。

## 安装

先校验：

```bash
sha256sum -c kylin-v10sp3-aarch64-samba-sambly-minimal.tar.gz.sha256
```

解压：

```bash
tar -xzf kylin-v10sp3-aarch64-samba-sambly-minimal.tar.gz
cd kylin-v10sp3-aarch64-samba-sambly-minimal
```

安装 Samba + Sambly：

```bash
sudo bash install.sh
```

如果希望预先指定 Sambly 管理员密码：

```bash
sudo SAMBLY_ADMIN_USER=admin \
     SAMBLY_ADMIN_PASSWORD='替换成强密码' \
     SAMBLY_PORT=8090 \
     bash install.sh
```

不提供密码时，由 Sambly 首次启动生成随机密码：

```bash
cat /var/lib/sambly/initial-credentials.txt
```

Sambly 默认：

```text
http://<服务器IP>:8090
```

Sambly 以 root 身份运行，用于管理 Samba 用户、Linux 用户/组、共享以及 `/etc/samba/smb.conf`。8090 只应开放给可信管理网络。

`install.sh` **不会启动 Samba，也不会自动把服务器改成 DFS Root**，避免在配置完成前开放文件共享。

## 配置 DFS 入口

确认 Sambly 能访问后，执行：

```bash
sudo bash configure-dfs-root.sh
```

脚本会：

- 备份原 `/etc/samba/smb.conf`；
- 若发现已有自定义业务共享则默认停止，避免覆盖；
- 创建 `/srv/dfs`；
- 开启 `host msdfs = yes`；
- 创建 `[files]`，设置 `msdfs root = yes`；
- 设置最低协议为 SMB2；
- `testparm` 成功后才替换正式配置；
- 启动并启用 `smb.service`。

然后先在 Sambly 中创建至少一个 Samba 用户。

## 添加后端麒麟服务器

例如后端服务器：

```text
192.168.88.211 -> ledong_share
192.168.88.212 -> ledong_share
192.168.88.213 -> ledong_share
```

执行：

```bash
sudo bash add-dfs-target.sh kylin01 192.168.88.211 ledong_share
sudo bash add-dfs-target.sh kylin02 192.168.88.212 ledong_share
sudo bash add-dfs-target.sh kylin03 192.168.88.213 ledong_share
```

最终 `/srv/dfs` 类似：

```text
kylin01 -> msdfs:192.168.88.211\ledong_share
kylin02 -> msdfs:192.168.88.212\ledong_share
kylin03 -> msdfs:192.168.88.213\ledong_share
```

Windows 只添加：

```text
\\<DFS服务器IP>\files
```

就会看到：

```text
kylin01
kylin02
kylin03
```

文件真正传输时，Windows 会根据 DFS referral 直接连接相应后端服务器，所以 DFS 入口不需要大容量业务磁盘，也不承担所有文件传输流量。

## Cockpit / cockpit-file-sharing

当前这台新服务器的确定方案是 **Samba 4.11 + Sambly 原生部署**，因此 Cockpit 已从默认 Release 中拆除，避免为了一个备用 UI 携带数百个额外系统依赖。

如果后续仍需要 Cockpit + cockpit-file-sharing，应作为**独立可选安装包**构建，不与这个最小包绑定，也不应默认修改 DFS 的 `smb.conf` 管理方式。

## Action 策略

为了避免浪费 GitHub Actions 时间：

- PR 只运行几秒的 shell 静态检查；
- 完整 ARM64 构建只在手动 `workflow_dispatch` 或合并到 `main` 后执行；
- 完整构建只下载上述 7 个麒麟官方 Samba RPM；
- Sambly 会运行 upstream tests 后再交叉编译 ARM64 静态二进制；
- 最终 tar.gz 会重新解压并校验 SHA256、脚本语法、RPM 数量和 Sambly 架构；
- 只有 `main` push 的完整构建成功后才发布/更新 Release。

## 软件来源

Kylin 官方仓库：

```text
https://update.cs2c.com.cn/NS/V10/V10SP3-2403/os/adv/lic/base/aarch64/
https://update.cs2c.com.cn/NS/V10/V10SP3-2403/os/adv/lic/updates/aarch64/
```

Sambly：

```text
https://github.com/buadamlaz/Sambly
```
