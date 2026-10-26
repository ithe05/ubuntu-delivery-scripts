# ubuntu-delivery-scripts

把一台裸装的 Ubuntu 服务器变成「可交付状态」——分区挂载、静态 IP、VNC、frp 穿透、时间同步、依赖安装，一条命令跑完，可重复执行，跑挂了修完能重跑。

> 这个仓库来自港口自动化项目现场的真实交付流程，不是教程 demo。所以它优先解决的是**别把人送进机房**和**别把 fstab 写错**这两件事。

## 解决什么问题

手工装机的问题不在难，在于**步骤多、易漏、无法复现**：

- 同一批十台机器，三个人装出三种结果，事后没人记得当时改了什么
- fstab 写错一个字段，重启进 emergency mode，现场没有显示器只能等人到
- 改 IP 时 SSH 断了，如果没有 BMC 或 VNC 兜底，只能去现场
- 新同事接手，全靠口头传帮带，每台机器都要重新问一遍

这套脚本把流程固化成代码：配置写在一个 `.env` 里，步骤拆成七个可独立执行的模块，每一步都做幂等判断——重复执行不会把系统弄坏。

## 特性

- **幂等**：每一步执行前先检测当前状态，已完成的自动跳过
- **dry-run**：`-n` 只打印将执行的命令，不产生任何修改
- **分步**：`-o 20,30` 只跑指定步骤，适合只改网络的场景
- **可回滚的边界**：改文件前自动备份为 `.bak.<时间戳>`
- **危险操作有闸门**：格式化数据盘需要显式 `DATA_ALLOW_FORMAT=1` 且二次确认；检测到数据盘与系统盘同属一块物理盘直接中止
- **失败可定位**：日志落盘、出错打印行号与具体命令
- **只用 bash + 系统工具**，无额外依赖

## 目录结构

```
.
├── bin/
│   ├── provision.sh          # 主入口，串联各步骤
│   ├── 10-init-system.sh     # 主机名 / hosts / 时区
│   ├── 20-network.sh         # netplan 静态 IP（支持 VLAN）
│   ├── 30-mount-data.sh      # 数据盘格式化 / UUID 写入 fstab
│   ├── 40-install-deps.sh    # 软件源 / 基础依赖 / chrony
│   ├── 50-setup-vnc.sh       # tigervnc + systemd，仅监听 127.0.0.1
│   ├── 60-setup-frpc.sh      # frpc 配置 + systemd
│   └── 90-check.sh           # 对照验收清单自检
├── lib/
│   └── common.sh             # 日志 / 幂等 / 确认 / dry-run 封装
├── conf/
│   └── example.env           # 配置模板
├── playbooks/                # Ansible 批量下发（可选）
└── docs/
    └── configuration.md      # 配置项说明
```

## 快速开始

```bash
git clone <repo-url> ubuntu-delivery-scripts
cd ubuntu-delivery-scripts
chmod +x bin/*.sh

cp conf/example.env conf/node31.env
vim conf/node31.env          # 填 IP、网卡名、数据盘、VNC 密码、frp 参数

# 1. 先空跑，确认命令符合预期
sudo ./bin/provision.sh -c conf/node31.env -n

# 2. 只做系统与网络
sudo ./bin/provision.sh -c conf/node31.env -o 10,20

# 3. 全流程
sudo ./bin/provision.sh -c conf/node31.env

# 4. 自检
sudo ./bin/provision.sh -c conf/node31.env -o 90
```

执行完会输出日志路径（默认 `/var/log/provision/`），交付时把日志一起归档。

## 三个必须知道的注意点

**1. 改网络前先确认有兜底通道。** 第 20 步会 `netplan apply`，SSH 可能直接断。上线前务必确认 BMC 带外可登录，或者已经把 VNC 跑起来。不确定就把 `NETPLAN_APPLY=0`，配置写好人工核对后再手动 apply。

**2. fstab 改完一定要重启验证。** 第 30 步只用 `mount -a` 验证了当前会话，重启后能否自动挂载是另一回事。这是现场翻车率最高的一步。

**3. 第一次用先 dry-run。** 这不是玩具脚本，第 30 步的格式化是真的 `mkfs`。养成先 `-n` 的习惯。

## 配置项

见 [docs/configuration.md](docs/configuration.md)。最少需要关注：

| 变量 | 说明 |
|---|---|
| `MGMT_IFACE` / `MGMT_IP` / `GATEWAY` | 网络三件套，网卡名用 `ip -br link` 确认 |
| `DATA_DEVICE` / `DATA_MOUNT` | 数据盘，**别写系统盘**，脚本会做一次校验但不是万能的 |
| `VNC_PASSWORD` | 必填，至少 8 位 |
| `FRP_SERVER_ADDR` / `FRP_TOKEN` / `FRP_REMOTE_PORT` | frp 穿透参数 |

## 批量执行

`playbooks/site.yml` 提供 Ansible 版本，把配置分发到多台机器并行执行。**建议先在单台跑通全流程再用**，批量模式下出错很难中断。

```bash
cd playbooks
cp inventory.example.ini inventory.ini
ansible-playbook site.yml --limit node31
```

## 已知限制

- 只支持 Ubuntu 20.04 / 22.04 / 24.04，Debian 未验证
- frpc 二进制需自行准备（现场多为内网，脚本不代下载）
- 不支持 LVM 扩容、RAID 配置，这些在装机阶段完成
- VNC 仅监听 `127.0.0.1`，对外访问依赖 SSH 隧道或 frp，这是刻意的安全取舍

## 许可

MIT
