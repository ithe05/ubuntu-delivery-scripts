# ubuntu-delivery-scripts

把一台厂商预装的 Ubuntu 工控机变成「可交付状态」——静态 IP、数据盘挂载、交付制品解压与 FTP 同步、VNC、frp 穿透、内核锁定，一条命令跑完，可重复执行，跑挂了修完能重跑。

> 这个仓库来自港口自动化项目现场的真实交付流程，不是教程 demo。它优先解决的是四件事：**别把制品解压到根分区**、**别把 fstab 写错**、**别让内核自动升级搞掉驱动**、**别让人抱着显示器去现场**。

## 解决什么问题

现场交付的问题不在难，在于**顺序敏感、步骤多、易漏、无法复现**：

- 数据盘还没挂载就解压制品 → 文件全写进根分区，重启后挂载盖住目录，制品「凭空消失」
- 制品没解压就做 FTP 同步 → `mirror` 找不到本地落点，同步了个空
- fstab 写错一个字段 → 重启进 emergency mode，现场没有显示器只能等人到
- 内核被自动升级 → 显卡/采集卡驱动模块编译失败，重启后黑屏、VNC 进不去
- 同一批十台机器，三个人装出三种结果，事后没人记得改了什么

这套脚本把流程固化成代码：配置写在一个 `.env` 里，步骤拆成九个可独立执行的模块，每一步都做前置校验和幂等判断。

## 特性

- **顺序有保护**：步骤 35 会强校验数据盘是否真的挂载，未挂载直接中止，不做「先解压再说」
- **幂等**：每一步执行前先检测当前状态，已完成的自动跳过（解压靠标记文件 + 文件数双重判断）
- **dry-run**：`-n` 只打印将执行的命令，不产生任何修改
- **分步**：`-o 30,35` 只跑指定步骤，适合只补挂载和解压的场景
- **可回滚的边界**：改文件前自动备份为 `.bak.<时间戳>`
- **危险操作有闸门**：格式化数据盘需要显式 `DATA_ALLOW_FORMAT=1` 且二次确认；检测到数据盘与系统盘同属一块物理盘直接中止
- **口令不落日志**：FTP 口令在日志与 dry-run 输出中一律显示为 `****`；zip 口令默认走交互式输入，不进程参数
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
│   ├── 35-extract-deploy.sh  # 解压 deploy_files.zip + FTP 增量同步
│   ├── 40-install-deps.sh    # 软件源 / 基础依赖 / unzip·lftp / chrony
│   ├── 50-setup-vnc.sh       # tigervnc + systemd，仅监听 127.0.0.1
│   ├── 60-setup-frpc.sh      # frpc 配置 + systemd
│   ├── 70-lock-kernel.sh     # 固定内核与驱动，关闭自动升级
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
vim conf/node31.env          # 填 IP、网卡名、数据盘、制品路径、FTP、VNC、frp 参数

# 1. 先空跑，确认命令符合预期
sudo ./bin/provision.sh -c conf/node31.env -n

# 2. 系统与网络
sudo ./bin/provision.sh -c conf/node31.env -o 10,20

# 3. 数据盘挂载
sudo ./bin/provision.sh -c conf/node31.env -o 30

# 4. 解压制品 + FTP 同步（必须在 30 之后）
sudo ./bin/provision.sh -c conf/node31.env -o 35

# 5. 其余步骤
sudo ./bin/provision.sh -c conf/node31.env -o 40,50,60,70

# 6. 自检
sudo ./bin/provision.sh -c conf/node31.env -o 90
```

完整流程也可以一把跑：`sudo ./bin/provision.sh -c conf/node31.env`。执行完会输出日志路径（默认 `/var/log/provision/`），交付时把日志一起归档。

## 交付制品：为什么顺序不能错

现场流程里最容易出问题的就是「挂载 → 解压 → FTP 同步」这三步的先后关系。

**1. 必须挂载完再解压。** 如果数据盘还没挂到 `/media/ai/disk`（按项目规范），`/media/ai/disk` 只是根分区上的一个普通空目录。这时候解压，几 GB 的制品会写进系统盘；等数据盘挂上以后，挂载点把这个目录盖住，`ls` 一看是空的——制品「消失」，而且系统盘被吃掉一大块。脚本里这一段是硬校验，未挂载直接退出。

**2. 必须解压完再 FTP 同步。** `lftp mirror` 的语义是「以远端为准，补本地缺的」，但它的本地落点必须存在。没解压就没有 `deploy_files` 目录，同步会失败或建出一个空目录。

**3. mirror 参数为什么是这几个。**

```bash
lftp -u "$FTP_USER,$FTP_PASS" -e \
  "mirror --verbose --continue --only-missing --ignore-time --parallel=4 \
   $FTP_REMOTE_DIR $FTP_LOCAL_DIR; bye" "ftp://$FTP_HOST"
```

| 参数 | 作用 | 不加会怎样 |
|---|---|---|
| `--only-missing` | 只补本地缺的 | 每次都全量重下，几 GB 白跑 |
| `--continue` | 断点续传 | 链路一断，大文件从头开始 |
| `--ignore-time` | 不比时间戳 | 远端时间戳比本地旧就跳过，反而少文件 |
| `--parallel=4` | 4 并发 | 单线程拉大文件，现场等到下班 |
| 不带 `--delete` | 本地多出来的不删 | 加了 `--delete` 会删掉现场手工放进去的文件 |

**4. 单盘工控机怎么办。** 有的机器只有一个盘，没有独立数据盘，这一步按现场规范整步跳过：`DEPLOY_SKIP=1`。跳过之后 `90-check.sh` 也不会报制品缺失。

## 内核为什么要锁

工控机上的显卡、采集卡、串口卡驱动依赖当前内核版本（dkms 编译或厂商 `.deb`）。`apt` 自动升级一旦把 `linux-image` 拉高一个小版本，重启后模块编译失败或签名不匹配，表现是花屏、黑屏、VNC 进不去——而现场通常没接显示器，只能等人从公司过去。

步骤 70 做两件事：

1. `apt-mark hold` 当前运行内核的 `image / headers / modules / modules-extra` 以及 `linux-generic` 等元包（元包不锁，升级时会连带拉新内核）
2. 彻底关掉 apt 自动更新，四步走：

```bash
apt remove -y unattended-upgrades                              # 卸包
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer # 停 timer
systemctl mask apt-daily.service apt-daily-upgrade.service      # mask service
# 重写 20auto-upgrades，周期更新与无人值守升级均置 0
```

**为什么四步都要**：只 `disable` 不 `mask`，某些包的 postinst 会把 service 直接拉起来；只卸包不清 timer，`apt-daily.timer` 每天仍会跑一次 `apt update`；只 mask 不重写配置，`20auto-upgrades` 里的历史选项仍可能被其它组件读到。三层任意留一层，风险都还在。

代价要说清楚：**关了自动更新，就不会再自动打安全补丁**。这类交付机在港口内网，补丁由人工窗口统一处理，所以可以接受；但如果某个项目有等保要求「必须自动更新」，把 `KERNEL_REMOVE_UNATTENDED=0`，只停用不卸载，并按项目规范登记例外。

将来真要升内核，流程是：`apt-mark unhold <包名>` → 升级 → 重新验证驱动（`nvidia-smi` / `dmesg | grep -i <驱动名>`）→ 再确认可以重启。

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
| `DEPLOY_ZIP` / `DEPLOY_DEST` / `DEPLOY_SUBDIR` | 制品包路径、解压落点、包内顶层目录名 |
| `FTP_HOST` / `FTP_REMOTE_DIR` / `FTP_LOCAL_DIR` | FTP 增量同步，留空 `FTP_HOST` 则跳过 |
| `VNC_PASSWORD` | 必填，至少 8 位 |
| `FRP_SERVER_ADDR` / `FRP_TOKEN` / `FRP_REMOTE_PORT` | frp 穿透参数 |

## 请勿提交真实参数

`conf/*.env` 已在 `.gitignore` 中排除，请把真实配置放在 `conf/local.env` 之类的文件里。

需要保密的通常是这几类，别写进 README、别提进 commit message：

- 内网 IP、跳板机 IP、公网出口 IP
- FTP 账号口令、zip 解压口令、sudo 口令
- VNC license key、项目端口分配表

这个仓库的价值在**流程和判断逻辑**，不在某台机器的具体参数。参数是现场的，逻辑是可以带走的。

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
- 不支持 LVM 扩容、RAID 配置，这些在装机/镜像阶段完成
- 解压为整包覆盖（`unzip -o`），不做增量比对；增量靠后面的 FTP 同步
- VNC 步骤为通用 tigervnc 实现，若现场用厂商自带 VNC（含 license），请按现场文档执行，本步骤跳过

## 许可

MIT
