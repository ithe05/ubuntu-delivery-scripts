# 配置项说明

配置文件格式为 shell 变量赋值（`KEY=value`），由脚本 `source` 加载。**不要加引号以外的复杂逻辑，也不要在里面执行命令。**

## 基础

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `HOSTNAME` | 是 | — | 主机名。建议 `prod-<项目>-<用途><序号>` |
| `TIMEZONE` | 是 | `Asia/Shanghai` | 时区，影响日志与定时任务 |

## 网络

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `MGMT_IFACE` | 是 | — | 网卡名。用 `ip -br link` 确认，常见 `eno1` / `ens33` / `enp3s0` |
| `MGMT_IP` | 是 | — | 管理 IP，不带掩码 |
| `MGMT_PREFIX_LEN` | 是 | — | 掩码前缀长度，`24` 对应 `255.255.255.0` |
| `GATEWAY` | 是 | — | 默认网关 |
| `DNS_SERVERS` | 是 | — | 多个用英文逗号分隔，如 `10.10.0.10,223.5.5.5` |
| `NETPLAN_APPLY` | 否 | `1` | `0` = 只生成配置不应用（首次远程改网络建议设 0） |
| `VLAN_ID` | 否 | 空 | 填写则生成 `vlans` 段，接口名为 `<MGMT_IFACE>.<VLAN_ID>` |

> 生成的配置文件为 `/etc/netplan/99-provision.yaml`，权限 600。原文件会先备份。

## 数据盘

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `DATA_DEVICE` | 是 | — | 设备路径，建议用分区如 `/dev/sdb1` |
| `DATA_MOUNT` | 是 | — | 挂载点，如 `/data` |
| `DATA_FSTYPE` | 是 | `ext4` | 支持 `ext4` / `xfs` |
| `DATA_ALLOW_FORMAT` | 否 | `0` | `1` 才允许格式化。默认 0 表示只挂载、不动数据 |
| `DATA_LABEL` | 否 | `data` | 文件系统卷标 |

**安全机制**：
- 检测到数据盘与系统盘同属一块物理盘时直接中止
- 设备上已有其他类型文件系统时不自动格式化
- 格式化前打印 `lsblk` 并要求二次确认

## 交付制品（步骤 35）

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `DEPLOY_ZIP` | 是 | — | 制品 zip 的绝对路径，一般就在数据盘根目录 |
| `DEPLOY_DEST` | 是 | — | 解压落点，通常等于 `DATA_MOUNT` |
| `DEPLOY_MOUNT` | 否 | `DATA_MOUNT` | 用于「是否已挂载」的强校验。未挂载直接中止 |
| `DEPLOY_SUBDIR` | 否 | `deploy_files` | 包内顶层目录名，解压后应为 `<DEPLOY_DEST>/deploy_files` |
| `DEPLOY_ZIP_PASS` | 否 | 空 | 留空则走 `unzip` 交互式输入，口令不进进程列表（推荐） |
| `DEPLOY_SKIP` | 否 | `0` | `1` = 单盘机器整步跳过，`90-check.sh` 也不再校验制品 |
| `DEPLOY_FORCE_EXTRACT` | 否 | `0` | `1` = 已解压过也强制重解 |
| `DEPLOY_MIN_FILES` | 否 | `1` | 解压后最少文件数，低于此值视为包不完整并中止 |
| `DEPLOY_VERIFY_PATHS` | 否 | 空 | 必须存在的关键相对路径，空格分隔，缺失即中止 |

**幂等判断**：有标记文件 `.deploy_extracted` 或目标目录已非空，即视为已解压并跳过。标记文件内容是解压时间、包路径与文件数，便于事后追溯。

**为什么必须校验挂载**：数据盘未挂载时，`DEPLOY_DEST` 只是根分区上的普通目录，解压会写进系统盘；之后数据盘挂上来把这个目录盖住，制品看起来「消失」，系统盘空间还少了几个 G。

## FTP 增量同步（步骤 35，跟在解压后面）

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `FTP_HOST` | 否 | 空 | 留空则整个同步步骤跳过 |
| `FTP_USER` | 否 | `anonymous` | 账号 |
| `FTP_PASS` | 否 | 空 | 口令。日志与 dry-run 输出中一律显示为 `****` |
| `FTP_REMOTE_DIR` | 是（启用时） | — | 远端目录，`mirror` 的源 |
| `FTP_LOCAL_DIR` | 否 | `DEPLOY_DEST/DEPLOY_SUBDIR` | 本地落点，必须先由解压创建 |
| `FTP_PARALLEL` | 否 | `4` | 并发数，链路差降到 1~2 |
| `FTP_MIN_FILES` | 否 | 空 | 同步后本地最少文件数，用于发现远端不完整 |

执行的命令等价于：

```bash
lftp -u "$FTP_USER,$FTP_PASS" -e \
  "mirror --verbose --continue --only-missing --ignore-time --parallel=$FTP_PARALLEL \
   $FTP_REMOTE_DIR $FTP_LOCAL_DIR; bye" "ftp://$FTP_HOST"
```

`mirror` 不带 `--delete`：本地多出来的文件不会被删。这是刻意选择——现场运维有时会手工往制品目录补文件，全量镜像会把它们清掉。

## 内核与驱动锁定（步骤 70）

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `KERNEL_HOLD_PACKAGES` | 否 | 空 | 留空 = 自动锁定当前运行内核的 `image/headers/modules/modules-extra` 与 `linux-generic` 等元包 |
| `KERNEL_DISABLE_AUTO_UPGRADE` | 否 | `1` | `1` = 关闭 apt 自动更新（卸包 / 停 timer / mask service / 周期配置置 0） |
| `KERNEL_REMOVE_UNATTENDED` | 否 | `1` | `1` = 卸载 `unattended-upgrades`；`0` = 保留安装仅停用 |
| `APT_CONF_DIR` | 否 | `/etc/apt/apt.conf.d` | 仅测试 / 容器场景用于重定向，正常不要改 |

关闭自动更新的完整动作（与现场脚本一致）：

| # | 动作 | 命令 | 单独留下会怎样 |
|---|---|---|---|
| 1 | 卸载 unattended-upgrades | `apt-get -y remove unattended-upgrades` | 无人值守升级仍在，半夜自动装包 |
| 2 | 停用定时器 | `systemctl disable --now apt-daily.timer apt-daily-upgrade.timer` | 每天仍会跑一次 `apt update`，索引变化后可能触发升级 |
| 3 | 屏蔽服务 | `systemctl mask apt-daily.service apt-daily-upgrade.service` | 某些包 postinst 会直接 `start` 它，disable 拦不住 |
| 4 | 重写周期配置 | 先 `rm` 再写入 `Update-Package-Lists "0"` / `Unattended-Upgrade "0"` | 旧配置项被其它组件读到，仍可能开启周期任务 |

**副作用**：不会再有自动安全补丁。内网交付机由人工补丁窗口统一处理；有等保要求「必须自动更新」的项目，设 `KERNEL_REMOVE_UNATTENDED=0` 并在交付单登记例外。

**幂等**：已 hold 的包跳过；包已卸载则跳过卸载；`20auto-upgrades` 内容已符合预期则不重写（`rm -f` + 重写只发生在内容不符时）。

## 软件源与依赖

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `APT_MIRROR` | 否 | 空 | 内网镜像地址，留空则不改软件源 |
| `NTP_SERVERS` | 否 | 空 | 内网 NTP，多个用空格分隔 |
| `EXTRA_PACKAGES` | 否 | 空 | 额外安装的包，空格分隔 |

基础依赖固定安装：`vim curl wget net-tools lsof htop unzip zip tar tcpdump rsync tree jq chrony lftp smbclient cifs-utils`

其中 `unzip` 与 `lftp` 是步骤 35 的硬依赖，`smbclient`/`cifs-utils` 用于从 SMB 共享拉取缺失的装机包。

## VNC

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `VNC_USER` | 是 | — | 运行 VNC 的系统用户，需已存在 |
| `VNC_PASSWORD` | 是 | — | 至少 8 位。不写入仓库，`conf/*.env` 已被 gitignore |
| `VNC_GEOMETRY` | 否 | `1920x1080` | 分辨率 |
| `VNC_DISPLAY` | 否 | `1` | 显示号，端口 = 5900 + 显示号 |

VNC 强制监听 `127.0.0.1`，对外访问必须走 SSH 隧道或 frp。这是刻意的安全取舍。

## frp

| 变量 | 必填 | 说明 |
|---|---|---|
| `FRP_SERVER_ADDR` | 是 | frps 地址 |
| `FRP_SERVER_PORT` | 是 | frps 控制端口，默认 7000 |
| `FRP_TOKEN` | 是 | 认证 token |
| `FRP_REMOTE_PORT` | 是 | 服务端映射端口 |
| `FRP_LOCAL_PORT` | 是 | 本地转发端口，配合 VNC 时为 `5900 + 显示号` |

生成的 `/etc/frp/frpc.toml` 权限 600。

> **服务端必须限制来源 IP**，只允许跳板机访问 `FRP_REMOTE_PORT`。客户端不加限制等于把内网机器直接挂到公网。

## 配置示例

```bash
HOSTNAME=prod-epf-node31
TIMEZONE=Asia/Shanghai

MGMT_IFACE=eno1
MGMT_IP=10.10.20.31
MGMT_PREFIX_LEN=24
GATEWAY=10.10.20.1
DNS_SERVERS=10.10.0.10,223.5.5.5
NETPLAN_APPLY=1

DATA_DEVICE=/dev/sdb1
DATA_MOUNT=/data
DATA_FSTYPE=ext4
DATA_ALLOW_FORMAT=1

DEPLOY_ZIP=/data/deploy_files.zip
DEPLOY_DEST=/data
DEPLOY_MOUNT=/data
DEPLOY_SUBDIR=deploy_files
DEPLOY_MIN_FILES=1

FTP_HOST=10.0.0.10
FTP_USER=deploy
FTP_PASS=<你的口令>
FTP_REMOTE_DIR=/data/deploy/deploy_files
FTP_PARALLEL=4

KERNEL_DISABLE_AUTO_UPGRADE=1

VNC_USER=ops
VNC_PASSWORD=<你的密码>
VNC_GEOMETRY=1920x1080
VNC_DISPLAY=1

FRP_SERVER_ADDR=10.10.40.5
FRP_SERVER_PORT=7000
FRP_TOKEN=<你的token>
FRP_REMOTE_PORT=15901
FRP_LOCAL_PORT=5901
```
