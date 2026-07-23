# my-seedbox

一体化 Seedbox 安装脚本。单入口 `install.sh`，`wget` 一条命令即可安装，支持**交互菜单**和**命令行无人值守**两种方式。

聚焦三件事：**qBittorrent 安装**、**系统优化**、**BBR 拥塞控制版本管理**。

> 本项目基于 `Dedicated-Seedbox` 的旧架构移植精简而来，去除了 autobrr / vertex / autoremove-torrents / Deluge 等组件。

### 三个模块各管什么（职责边界）

三块功能相互独立、互不重叠，这点容易被误解，特此说明：

| 模块 | 负责 | **不负责** |
|------|------|-----------|
| **BBR**（`lib/bbr.sh` + `BBR/`） | 只有 TCP 拥塞控制算法（编译内核模块 + 设 `tcp_congestion_control`/`default_qdisc` 两个 sysctl） | 不碰 CPU、磁盘 I/O、文件句柄、网卡队列 |
| **系统优化**（`lib/tuning.sh`） | 磁盘 I/O 调度器、文件打开数上限、网卡 ring buffer、网络相关 sysctl（TCP 缓冲区等）、初始拥塞窗口 | 不碰拥塞控制算法本身；也**不改 CPU governor**（如需锁 performance 请单独处理） |
| **qBittorrent**（`lib/qbittorrent.sh`） | 客户端二进制、systemd 服务、WebUI 配置、客户端自身的缓冲参数 | 不碰内核参数 |

换句话说：**CPU / 磁盘 I/O 相关的优化在「系统优化」模块里，不在 BBR 里**。BBR 脚本只改拥塞控制这一个点。两者都属于广义「网络/系统优化」，但边界清晰、各司其职。

> 唯一的交叠点是 `default_qdisc`：系统优化和 BBR 模块都会把它设为 `fq`（两处取值永远一致）。BBR 那份写在 `99-zz-seedbox-bbr.conf`，`zz` 前缀保证按文件名排序时后加载、以它为准，不会冲突。

---

## 快速开始

**交互菜单（推荐新手）：**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/install.sh)
```

**无人值守（一行装完）：**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/install.sh) \
     -u admin -p 'YourPassword' -c 2048 -q 5.0.4 -t -x bbrx
```

### 命令行参数

| 参数 | 说明 |
|------|------|
| `-u` | WebUI 用户名 |
| `-p` | WebUI 密码（也可不给 `-p`，改用环境变量 `QB_PASSWORD` 传入，见下方安全提示） |
| `-c` | qBittorrent 磁盘缓存（MiB，建议为内存的 1/4） |
| `-q` | qBittorrent 版本（`5.0.4` / `4.3.8`） |
| `-o` | WebUI 端口（默认 `8080`） |
| `-i` | BT 连接 incoming 端口（默认 `45000`） |
| `-x` | 安装 BBR 变种（`bbrx` / `bbrz` / `bbrx_old`），重启后编译 |
| `-t` | 应用系统优化 |
| `-h` | 显示帮助 |

只给部分参数时，缺失的关键项会转入交互询问；完全不给参数则进入主菜单。

**安全提示**：`-p` 的密码会出现在命令行参数里（可能进 shell 历史、被同机其它用户 `ps` 看到）。更安全的写法是用环境变量：

```bash
QB_PASSWORD='YourPassword' bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/install.sh) \
     -u admin -c 2048 -q 5.0.4 -t -x bbrx
```

**安装 qBittorrent 时的自动处理**：
- 安装前检测 WebUI / 连接端口是否被其它进程占用，占用时给出警告（不阻断安装）。
- 若检测到 `ufw` 防火墙处于启用状态，自动放行 WebUI 端口（tcp）与连接端口（tcp+udp）；未安装或未启用 ufw 则不做任何防火墙操作。
- 重装/换版本覆盖 `qBittorrent.conf` 前，自动备份原配置为 `qBittorrent.conf.bak.<时间戳>`。

---

## 系统要求

- **操作系统**：Debian 12 / Debian 13（BBR 内核模块编译仅在这两个版本验证）。qBittorrent 与系统优化在其它 Debian/Ubuntu 上通常也可用。
- **架构**：amd64 (x86_64) 或 arm64 (aarch64)。
- **权限**：root。

---

## 目录结构

```
my-seedbox/
├── install.sh                    # 唯一入口
├── bbr_switch.sh                 # 独立的BBR自由切换脚本（bbr/bbrx/bbrz/bbrx_old）
├── cpu.sh                        # 独立脚本：锁定CPU为performance模式
├── lib/
│   ├── common.sh                 # 公共函数（输出/下载/系统检测/清单解析）
│   ├── qbittorrent.sh            # qBittorrent 安装
│   ├── tuning.sh                 # 系统优化
│   └── bbr.sh                    # BBR 变种管理（安装/切换/恢复）
├── versions/
│   ├── qbittorrent.list          # qB 版本清单（新增版本改这里）
│   └── bbr.list                  # BBR 变种清单（新增变种改这里）
├── BBR/
│   ├── BBRx/                      # BBRx：安装脚本 + C 源码（D12/D13）
│   ├── BBRz/                      # BBRz：安装脚本 + C 源码（D12/D13）
│   └── BBRx_old/                 # BBRx_old：安装脚本 + C 源码 + 适配 diff
├── extras/
│   └── qBittorrent-noroot.sh     # 无root权限环境（如Feralhosting）下的qB安装脚本
└── bin/                          # 你自行放置的二进制（见下）
    ├── qbittorrent/<版本>/<架构>/qbittorrent-nox
    └── tools/<架构>/libqbpasswd
```

---

## 部署前需要你放置的二进制

脚本本身不含大的二进制文件，需要你把以下文件放进仓库对应位置后再 `git push`：

### 1. qBittorrent 静态可执行文件

必须是**静态编译**版（自带依赖，直接可跑），文件名固定为 `qbittorrent-nox`：

```
bin/qbittorrent/5.0.4/amd64/qbittorrent-nox
bin/qbittorrent/5.0.4/arm64/qbittorrent-nox
bin/qbittorrent/4.3.8/amd64/qbittorrent-nox
bin/qbittorrent/4.3.8/arm64/qbittorrent-nox
```

> 静态二进制可从 [userdocs/qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static) 获取或自行编译。

### 2. 密码生成工具 libqbpasswd

用于生成 WebUI 的 PBKDF2 密码哈希，文件名固定为 `libqbpasswd`：

```
bin/tools/amd64/libqbpasswd
bin/tools/arm64/libqbpasswd
```

> 来自 [KozakaiAya/libqbpasswd](https://github.com/KozakaiAya/libqbpasswd)，两个架构各编译一份。

---

## 如何升级 / 扩展

### 新增一个 qBittorrent 版本

1. 在 `versions/qbittorrent.list` 加一行：
   ```
   5.1.0|2.0.11|modern44|qBittorrent 5.1.0
   ```
   字段：`版本 | libtorrent版本 | 配置格式代号 | 说明`。
   配置格式代号取 `legacy43`（4.2/4.3 系列）或 `modern44`（4.4 及以后含 5.x）。
2. 把编译好的静态 `qbittorrent-nox` 放进 `bin/qbittorrent/5.1.0/{amd64,arm64}/`。
3. `git push`。菜单和命令行会自动出现该版本，主脚本无需改动。

### 新增一个 BBR 变种

1. 在 `versions/bbr.list` 加一行：
   ```
   bbry|BBRy (实验版)|debian12,debian13|说明
   ```
2. 建目录 `BBR/BBRy/`，放入：
   - 安装脚本 `BBRy.sh`（可参考现有 `BBRx.sh` 修改算法名与源码 URL）
   - C 源码 `tcp_bbry.c`（Debian 12）与 `tcp_bbry_debian13.c`（Debian 13）
3. `git push`。变种会自动出现在 BBR 菜单。

---

## BBR 变种说明

| 变种 | 特点 |
|------|------|
| `bbrx` | 通用优化版，平衡吞吐与延迟 |
| `bbrz` | 激进吞吐版，更强的抢占带宽策略 |
| `bbrx_old` | 保留早期 BBRx 调参风格的怀旧版本 |

三者的 C 源码均按 Debian 12 / Debian 13 各提供一份（`_debian13.c` 后缀为 D13 内核 API 适配版）。安装脚本会依当前系统自动选择正确的源码编译。

### 关于 BBR 安装流程

BBR 内核模块需针对**当前运行的内核**编译，因此安装分两步：

1. 运行安装 → 脚本配置一个开机自启的一次性 systemd 服务，然后提示重启。
2. 重启后 → 服务自动用 DKMS 编译 BBR 模块并切换生效，完成后自清理。

重启后等待 2-3 分钟，用以下命令确认：

```bash
sysctl net.ipv4.tcp_congestion_control
```

### bbrx_old 的 Debian 13 适配

`BBR/BBRx_old/tcp_bbrx_old_debian13.c` 是由原始 `tcp_bbrx_old.c` 适配而来，**只改内核 API、不动任何算法调参**。全部改动记录在 `BBR/BBRx_old/ADAPTATION.debian13.diff`，可逐行审查。

> **关于 bbrx_old 的算法名**：早期 bbrx_old 源码内部注册的拥塞控制算法名与 bbrx 相同（都是 `bbrx`），会导致两者无法共存、且 sysctl 切换名对不上。为支持四变种自由切换，已把 bbrx_old 模块注册的算法名改为 `bbrxold`（仅改 `.name` 标识符，不影响任何算法行为；模块文件名仍为 `tcp_bbrx_old`）。因此切换到该变种时 sysctl 值为 `bbrxold`。

---

## 独立切换脚本 bbr_switch.sh

除了 `install.sh` 里的 BBR 菜单，项目还提供一个独立的快速切换脚本 `bbr_switch.sh`，用于在 **bbr / bbrx / bbrz / bbrx_old** 之间自由切换。

变种列表与 `install.sh` 共用同一份 `versions/bbr.list` 清单：按上文教程新增变种后，本脚本会**自动识别**，无需改脚本。

```bash
# 交互菜单
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/bbr_switch.sh)
```

```bash
# 直接切换到指定变种，例如bbrx
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/bbr_switch.sh) bbrx
```

```bash
# 直接切换到指定变种，例如bbrx_old
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/bbr_switch.sh) bbrx_old
```

```bash
# 只看当前状态
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/bbr_switch.sh) status
```

**智能切换逻辑**：

| 目标变种状态 | 行为 |
|--------------|------|
| 模块已注册（当前会话已加载） | 即时切换，纯 sysctl，**无需重启** |
| 已 DKMS 编译但未加载 | 自动 `modprobe` 加载后切换，**无需重启** |
| 从未编译 | 触发对应变种的编译流程（DKMS，**完成后自动重启一次**） |
| 系统自带 `bbr` | 始终即时切换，无需重启 |

也就是说：**首次**安装某个自定义变种需要编译 + 重启一次（由 `install.sh` 或本脚本触发）；此后在已编译的各变种之间切换是**秒级**的，因为它们注册了各自不同的算法名（`bbrx` / `bbrz` / `bbrxold`），可在内核中共存。

`status` 会列出每个变种的就绪情况（已就绪可秒切 / 已编译待加载 / 未编译需编译），并用 `▶` 标出当前生效的算法。

---

## 独立脚本 cpu.sh（锁定 CPU 为 performance 模式）

系统优化模块（`lib/tuning.sh`）**不碰 CPU governor**（见文首职责边界说明），如需锁定 CPU 频率为 `performance` 模式，用这个独立脚本单独处理：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/cpu.sh)
```

行为：检测 `cpufreq` 接口是否存在（部分虚拟机/容器未暴露该接口，脚本会报错退出，这是正常现象，不代表脚本坏了）→ 自动安装 `cpupower`（apt/dnf/yum 均可）→ 若当前不是 `performance` 就切换过去 → 写一个 `cpuperf.service` 开机自启服务，保证重启后依然锁定为 `performance`。已经是 `performance` 时只会补装持久化服务，不会重复操作。

加 `--verbose` 参数可查看每个核心当前的 governor：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/cpu.sh) --verbose
```

需要 root 权限直接运行（不依赖 sudo 是否安装，和本项目其它脚本一致）。

---

## 无 root 环境安装 qBittorrent（extras/qBittorrent-noroot.sh）

`install.sh` 的 qBittorrent 模块假定你有 root 权限（装 systemd 服务、写 `/usr/bin` 等）。如果是在 Feralhosting 这类**没有 root 权限的商业 Seedbox** 上装机，用这个独立脚本，全程只在你自己的用户目录下操作：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/extras/qBittorrent-noroot.sh) <用户名> <密码> <缓存MiB> <WebUI端口> <连接端口>
```

例如：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/extras/qBittorrent-noroot.sh) admin mypassword 512 8080 6881
```

二进制来自本项目的 qBittorrent 5.2.2（自动识别 amd64 / arm64 架构；目前仅提供 amd64 二进制，arm64 会下载失败并明确报错）。安装时会让你交互选择启动方式（`systemd --user` 服务 / `screen` 会话 / 后台 daemon），三种方式都配了对应的启动/停止/重启命令，脚本运行完会打印出来。

---

## 系统优化内容

沿用 Dedicated-Seedbox 旧架构的调优方案：

- **内核网络参数**：TCP 缓冲区按物理内存动态计算（`tcp_mem` / `tcp_rmem` / `tcp_wmem` / `rmem_max` / `wmem_max`）、队列积压、连接跟踪表、慢启动行为等。
- **文件打开数上限**：`limits.d` + systemd 全局默认，提到 1048576。
- **磁盘 I/O 调度器**：自动识别 SSD/NVMe（kyber/none）与 HDD（mq-deadline），跳过虚拟盘。
- **网卡 ring buffer**：按驱动上报的上限拉满。
- **默认路由初始窗口**：提高 `initcwnd` / `initrwnd`。

在虚拟化环境下，与硬件强相关的项会自动跳过而不报错。

---

## 常见问题

**Q：qBittorrent 装完起不来？**
先看日志：`journalctl -u qbittorrent-nox@<用户名> -n 50`。若报缺少动态库（`.so` 找不到），说明放进去的不是静态编译版，请更换为静态二进制。

**Q：重启后 BBR 没生效？**
先明确正常流程：确认安装 → 重启 → 系统自动编译（2-3 分钟）→ **自动再重启一次**收尾 → 生效。所以总共会经历两次重启（第二次是自动的），全程约 5 分钟。

若等待后仍未生效，用 `journalctl -u bbrinstall.service -b -1` 查看上次开机的编译日志。常见原因：
- 云镜像自带的内核太老，软件源里已无对应 headers（脚本已通过安装前预装最新内核规避，若日志显示此错误可手动 `apt update && apt full-upgrade` 后重装）
- 开机时网络未就绪导致下载失败（服务已配置等待 network-online，一般不会再发生）

失败时服务会保留并在下次重启时自动重试，因此有时"多重启一次就好了"。

**Q：模块加载了（lsmod 能看到）但算法还是 cubic？**
这是 Debian 13 特有的坑：trixie 的 systemd 移除了 `/etc/sysctl.d/99-sysctl.conf` 兼容符号链接，**开机不再读取 `/etc/sysctl.conf`**。写在那里的 `tcp_congestion_control` 会被静默忽略。本项目已改为写入 `/etc/sysctl.d/99-zz-seedbox-bbr.conf`（开机会读）。若你从旧版本升级，重新执行一次 BBR 安装或切换即可修复；或手动创建该文件后 `sysctl --system`。

**Q：想换回系统自带 BBR？**
进 BBR 菜单选「恢复系统自带 BBR」，或运行 `bash bbr_switch.sh bbr`。菜单版的「恢复」还会顺带清理掉可能残留的待编译服务（`bbrinstall.service`，见上一问），保证下次重启不会意外触发编译。

**Q：系统优化最后一步"提高初始拥塞窗口"提示未能设置/已跳过？**
分两种情况：
- 提示"检测到多路径(ECMP)默认路由，已跳过"——这是**正常情况，不是故障**。多网卡负载均衡的独立服务器常见此配置，而 `initcwnd`/`initrwnd` 这两个参数本身不支持挂在多路径路由上，这是 iproute2 的语法限制，无法绕过，跳过是唯一正确的处理方式，不影响其它任何优化项。
- 提示"设置失败，内核报错：xxx"——说明遇到了其它情况，日志里会打印内核给出的具体原因，可据此判断（例如路由被其它进程并发修改、`ip` 命令版本过旧等），不影响其它优化项已生效的部分。

---

## 致谢

- 本项目绝大部分的思路、架构与二进制编译方式，均源自 [jerry048/Dedicated-Seedbox](https://github.com/jerry048/Dedicated-Seedbox)（及其组件仓库 [jerry048/Seedbox-Components](https://github.com/jerry048/Seedbox-Components)），在此特别感谢。
- 同样感谢 [guowanghushifu/Dedicated-Seedbox-Mod](https://github.com/guowanghushifu/Dedicated-Seedbox-Mod)（及 [guowanghushifu/Seedbox-Components](https://github.com/guowanghushifu/Seedbox-Components)），本项目移植自其保留的旧版架构，具体实现细节大量参考于此。
- BBR 编译机制参考 [KozakaiAya/TCP_BBR](https://github.com/KozakaiAya/TCP_BBR)
- 密码工具 [KozakaiAya/libqbpasswd](https://github.com/KozakaiAya/libqbpasswd)
- qBittorrent 静态编译 [userdocs/qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static)
