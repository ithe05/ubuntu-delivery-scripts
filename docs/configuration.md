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

## 软件源与依赖

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `APT_MIRROR` | 否 | 空 | 内网镜像地址，留空则不改软件源 |
| `NTP_SERVERS` | 否 | 空 | 内网 NTP，多个用空格分隔 |
| `EXTRA_PACKAGES` | 否 | 空 | 额外安装的包，空格分隔 |

基础依赖固定安装：`vim curl wget net-tools lsof htop unzip zip tar tcpdump rsync tree jq chrony`

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
