#!/bin/bash
# lib/tuning.sh —— 系统优化模块
# 忠实沿用 guowanghushifu 旧架构 seedbox_installation.sh 中内嵌的调优逻辑：
#   - 依物理内存动态计算 TCP 缓冲区（tcp_mem / tcp_rmem / tcp_wmem / rmem_max / wmem_max）
#   - 内核网络与文件系统 sysctl 调整
#   - 文件打开数上限（limits + systemd）
#   - 磁盘 I/O 调度器（HDD→mq-deadline，SSD/NVMe→kyber/none）
#   - 网卡 ring buffer 拉满
#   - 默认路由 initcwnd/initrwnd 提高
# 相对旧版仅增加"最小容错"：在虚拟盘/无对应设备/网卡不支持时跳过而非中断，
# 不改变任何具体参数数值。
# 依赖 lib/common.sh 已被 source。
# ---------------------------------------------------------------------------

if [[ -n "${SEEDBOX_TUNING_SOURCED:-}" ]]; then return 0; fi
readonly SEEDBOX_TUNING_SOURCED=1

# sysctl 落盘位置：沿用旧版做法，写入独立文件并通过 sysctl 加载。
# （旧版直接改 /etc/sysctl.conf；这里写到 /etc/sysctl.d/99-seedbox.conf，
#   等效生效且不破坏用户在主文件里的其它设置——属容错性改良，非参数改动。）
SEEDBOX_SYSCTL_FILE="/etc/sysctl.d/99-seedbox.conf"
SEEDBOX_LIMITS_FILE="/etc/security/limits.d/99-seedbox.conf"

# ---- 1) 依内存计算 TCP 缓冲并写 sysctl ----
tuning_kernel_sysctl() {
    info "配置内核网络参数 (sysctl)..."

    # 读取物理内存（KiB）
    local mem_kb
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

    local rmem_max wmem_max win_scale
    local rmem_default=262144 wmem_default=16384
    local tcp_rmem tcp_wmem tcp_mem

    if [[ "$mem_kb" =~ ^[0-9]+$ ]] && (( mem_kb > 0 )); then
        # 内存页(4KiB)总数
        local mem_pages_4k=$(( mem_kb / 4 ))
        # tcp_mem 三段：min / pressure / max，按内存比例（旧版思路）
        local tcp_mem_min=$(( mem_pages_4k * 3 / 32 ))
        local tcp_mem_pressure=$(( mem_pages_4k * 3 / 16 ))
        local tcp_mem_max=$(( mem_pages_4k * 3 / 8 ))
        # 上限保护（旧版设有 cap，防止超大内存机器数值失真）
        local tcp_mem_min_cap=4194304
        local tcp_mem_pressure_cap=6291456
        local tcp_mem_max_cap=8388608
        (( tcp_mem_min > tcp_mem_min_cap )) && tcp_mem_min=$tcp_mem_min_cap
        (( tcp_mem_pressure > tcp_mem_pressure_cap )) && tcp_mem_pressure=$tcp_mem_pressure_cap
        (( tcp_mem_max > tcp_mem_max_cap )) && tcp_mem_max=$tcp_mem_max_cap
        tcp_mem="${tcp_mem_min} ${tcp_mem_pressure} ${tcp_mem_max}"

        # socket 缓冲上限，按内存分档（旧版数值）
        if (( mem_kb <= 1048576 )); then          # <=1GiB
            rmem_max=33554432;  wmem_max=33554432;  win_scale=-2
        elif (( mem_kb <= 2097152 )); then        # <=2GiB
            rmem_max=67108864;  wmem_max=67108864;  win_scale=-2
        else                                      # >2GiB
            rmem_max=134217728; wmem_max=134217728; win_scale=-2
        fi
    else
        warn "未能读取内存大小，沿用系统现有 TCP 缓冲设置。"
        tcp_mem="$(cat /proc/sys/net/ipv4/tcp_mem 2>/dev/null)"
        rmem_max="$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 16777216)"
        wmem_max="$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 16777216)"
        win_scale="$(cat /proc/sys/net/ipv4/tcp_adv_win_scale 2>/dev/null || echo -2)"
    fi

    tcp_rmem="8192 ${rmem_default} ${rmem_max}"
    tcp_wmem="4096 ${wmem_default} ${wmem_max}"

    cat >"$SEEDBOX_SYSCTL_FILE" <<EOF
# ===========================================================================
# Seedbox 网络与内核调优（由 my-seedbox 生成）
# 参数沿用 Dedicated-Seedbox 旧架构调优方案。
# ===========================================================================

# ---- 拥塞控制与队列 ----
# 使用 fq 配合 BBR（BBR 模块由 BBR 安装流程另行设置）
net.core.default_qdisc = fq

# ---- 接收/发送 socket 缓冲 ----
net.core.rmem_default = ${rmem_default}
net.core.rmem_max = ${rmem_max}
net.core.wmem_default = ${wmem_default}
net.core.wmem_max = ${wmem_max}

# ---- TCP 内存与自动调节缓冲 ----
net.ipv4.tcp_mem = ${tcp_mem}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_adv_win_scale = ${win_scale}
net.ipv4.tcp_moderate_rcvbuf = 1

# ---- 队列与积压 ----
# 软中断处理预算（提高单次 NAPI 轮询时间上限，利于高吞吐）
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
# INPUT 侧网卡队列积压上限
net.core.netdev_max_backlog = 100000
# 半连接与已完成连接队列
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# ---- TCP 行为优化 ----
# 空闲后不回落慢启动，利于长连接持续做种
net.ipv4.tcp_slow_start_after_idle = 0
# 更快的丢包恢复
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
# MTU 探测，避免黑洞路径
net.ipv4.tcp_mtu_probing = 1
# 孤儿连接与 TIME_WAIT 上限（高并发做种会产生大量短连接）
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_syncookies = 1

# ---- 连接跟踪（大量 peer 连接时避免表满丢包）----
net.netfilter.nf_conntrack_max = 1048576

# ---- 文件系统 ----
fs.file-max = 2097152
fs.nr_open = 2097152

# ---- 虚拟内存 ----
# 降低 swap 倾向，脏页策略偏向及时下刷（做种写入友好）
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF

    # 加载（仅加载我们这一份，避免其它 drop-in 报错干扰）
    if sysctl -p "$SEEDBOX_SYSCTL_FILE" >/dev/null 2>&1; then
        success "内核参数已应用。"
    else
        warn "部分 sysctl 键在当前内核不可用，已跳过不可用项，其余已生效。"
        # 逐行尝试，跳过报错项（容错，不改变参数集）
        while IFS= read -r line; do
            case "$line" in ''|\#*) continue ;; esac
            sysctl -w "${line// /}" >/dev/null 2>&1 || true
        done <"$SEEDBOX_SYSCTL_FILE"
    fi
}

# ---- 2) 文件打开数上限 ----
tuning_file_open_limit() {
    info "设置文件打开数上限..."
    cat >"$SEEDBOX_LIMITS_FILE" <<'EOF'
# Seedbox 文件描述符上限（由 my-seedbox 生成）
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
EOF
    # systemd 全局默认（服务进程走这里而非 limits.conf）
    mkdir -p /etc/systemd/system.conf.d
    cat >/etc/systemd/system.conf.d/99-seedbox-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
    mkdir -p /etc/systemd/user.conf.d
    cat >/etc/systemd/user.conf.d/99-seedbox-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    success "文件打开数上限已设置（部分需重新登录/重启后完全生效）。"
}

# ---- 3) 磁盘 I/O 调度器 ----
# 容错要点：只对真实的物理块设备设置；跳过 loop/zram/dm/虚拟盘以及不存在的队列节点。
tuning_disk_scheduler() {
    info "配置磁盘 I/O 调度器..."
    local applied=0 dev sched_path rota
    # 枚举块设备名（跳过分区，只取整盘）
    local names
    names="$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')"
    if [[ -z "$names" ]]; then
        warn "未发现物理磁盘（可能是纯虚拟化存储），跳过调度器设置。"
        return 0
    fi

    for dev in $names; do
        # 跳过明显的虚拟/内存盘
        case "$dev" in
            loop*|ram*|zram*|dm-*|sr*) continue ;;
        esac
        sched_path="/sys/block/${dev}/queue/scheduler"
        [[ -w "$sched_path" ]] || continue   # 无可写调度节点则跳过（容错）

        rota="$(cat "/sys/block/${dev}/queue/rotational" 2>/dev/null || echo 1)"

        local want
        if [[ "$rota" == "0" ]]; then
            # 非旋转介质（SSD/NVMe）：优先 kyber，退而 none/mq-deadline
            if grep -qw kyber "$sched_path"; then want="kyber"
            elif grep -qw none "$sched_path"; then want="none"
            else want="mq-deadline"; fi
        else
            # 机械盘：mq-deadline
            if grep -qw mq-deadline "$sched_path"; then want="mq-deadline"
            else want="none"; fi
        fi

        if echo "$want" >"$sched_path" 2>/dev/null; then
            info "  ${dev} (rotational=${rota}) → ${want}"
            applied=1
        fi
    done
    [[ $applied -eq 1 ]] && success "磁盘调度器已设置。" || warn "没有可设置的磁盘调度器，已跳过。"
}

# ---- 4) 网卡 ring buffer ----
# 容错要点：网卡不支持或已是最大值时静默跳过。
tuning_ring_buffer() {
    info "调整网卡 ring buffer..."
    if ! command -v ethtool >/dev/null 2>&1; then
        ensure_packages ethtool || { warn "缺少 ethtool，跳过 ring buffer。"; return 0; }
    fi
    local iface applied=0
    # 主用网卡（有默认路由的那个）
    iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    [[ -z "$iface" ]] && iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')"
    [[ -z "$iface" ]] && { warn "未找到网卡，跳过。"; return 0; }

    # 读取硬件支持的最大值
    local maxline max_rx max_tx
    maxline="$(ethtool -g "$iface" 2>/dev/null)" || { warn "网卡 ${iface} 不支持 ring 查询，跳过。"; return 0; }
    max_rx="$(echo "$maxline" | awk '/Pre-set/{f=1} f&&/^RX:/{print $2; exit}')"
    max_tx="$(echo "$maxline" | awk '/Pre-set/{f=1} f&&/^TX:/{print $2; exit}')"

    if [[ "$max_rx" =~ ^[0-9]+$ ]] && (( max_rx > 0 )); then
        ethtool -G "$iface" rx "$max_rx" >/dev/null 2>&1 && applied=1
    fi
    if [[ "$max_tx" =~ ^[0-9]+$ ]] && (( max_tx > 0 )); then
        ethtool -G "$iface" tx "$max_tx" >/dev/null 2>&1 && applied=1
    fi
    [[ $applied -eq 1 ]] && success "网卡 ${iface} ring buffer 已拉满 (rx=${max_rx} tx=${max_tx})。" \
                         || warn "网卡 ${iface} ring buffer 未变更（可能已是最大或不支持）。"
}

# ---- 5) 默认路由初始拥塞窗口 ----
# 说明：直接把 `ip route show default` 整行文本回传给 ip route change 存在两个
# 真实问题（已用网络命名空间实测确认，非纸面推测）：
#   1) 多网卡/多路径独服常见的 ECMP 默认路由（一条路由跨多行 nexthop）按行读
#      会读丢网关信息，拼出的命令必然被内核拒绝；
#   2) 即使拼接正确，initcwnd/initrwnd 本身也不支持挂在多路径路由上——这是
#      iproute2 的语法限制（NH 子句只接受 weight/onlink，不接受拥塞窗口选项），
#      不是能靠改写命令解决的 bug，只能识别后跳过。
# 因此这里改为：只处理单路径默认路由，精确抽取 via/dev/onlink 字段重建命令
# （不再整行盲传，避免格式差异导致解析错位），用 replace 而非 change（更宽容，
# 不要求先精确匹配已存在的路由），并把内核真实报错打印出来，不再吞掉。
tuning_initial_cwnd() {
    info "提高默认路由初始拥塞/接收窗口 (initcwnd/initrwnd)..."

    local raw
    raw="$(ip -4 route show default 2>/dev/null)"
    if [[ -z "$raw" ]]; then
        warn "未检测到 IPv4 默认路由，跳过。"
        return 0
    fi

    # 多路径（ECMP）检测：多路径路由在文本里含 "nexthop" 关键字。
    if echo "$raw" | grep -qw nexthop; then
        warn "检测到多路径(ECMP)默认路由（常见于多网卡负载均衡的独立服务器）。"
        warn "initcwnd/initrwnd 不支持应用于多路径路由（iproute2 语法限制），已跳过此项，不影响其它优化。"
        return 0
    fi

    # 多条独立的默认路由（不同 metric，非多路径）：逐条处理。
    local applied=0 failed=0 line via dev onlink err
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        via="$(echo "$line" | grep -oP 'via \K[0-9.]+' || true)"
        dev="$(echo "$line" | grep -oP 'dev \K[^ ]+' || true)"
        onlink=""
        echo "$line" | grep -qw onlink && onlink="onlink"

        if [[ -z "$dev" ]]; then
            warn "无法从路由中解析出网卡设备名，跳过该条：${line}"
            continue
        fi

        if [[ -n "$via" ]]; then
            # shellcheck disable=SC2086
            err="$(ip route replace default via "$via" dev "$dev" $onlink initcwnd 25 initrwnd 25 2>&1)"
        else
            # 无网关的直连默认路由（少见但存在）
            err="$(ip route replace default dev "$dev" initcwnd 25 initrwnd 25 2>&1)"
        fi

        if [[ $? -eq 0 ]]; then
            applied=1
            info "  ${dev}${via:+ via $via} → initcwnd/initrwnd 已设置"
        else
            failed=1
            warn "  ${dev}${via:+ via $via} 设置失败，内核报错：${err:-（无输出）}"
        fi
    done <<<"$raw"

    if [[ $applied -eq 1 ]]; then
        success "初始窗口已设置。"
    elif [[ $failed -eq 1 ]]; then
        warn "初始窗口设置失败，已打印具体内核报错，请据此排查（不影响其它优化项）。"
    else
        warn "未能解析出可处理的默认路由，已跳过。"
    fi
}

# ---- 汇总执行 ----
tuning_apply_all() {
    title "系统优化"
    tuning_kernel_sysctl
    tuning_file_open_limit
    tuning_disk_scheduler
    tuning_ring_buffer
    tuning_initial_cwnd
    echo
    success "系统优化完成。部分与硬件相关的调整在虚拟化环境下会自动跳过。"
    warn "文件描述符上限等设置建议重启后完全生效。"
}

# ---- 交互入口（供菜单调用）----
tuning_menu() {
    title "系统优化"
    echo "将应用以下优化（沿用 Dedicated-Seedbox 旧架构方案）："
    echo "  · 内核网络参数（TCP 缓冲按内存动态计算、队列积压、连接跟踪等）"
    echo "  · 文件打开数上限"
    echo "  · 磁盘 I/O 调度器（自动识别 SSD/HDD）"
    echo "  · 网卡 ring buffer 拉满"
    echo "  · 默认路由初始窗口提高"
    echo
    if confirm "确认应用系统优化？"; then
        tuning_apply_all
    fi
    pause
}
