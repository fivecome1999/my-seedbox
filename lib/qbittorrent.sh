#!/bin/bash
# lib/qbittorrent.sh —— qBittorrent 安装模块
# 忠实移植 guowanghushifu 旧架构的安装逻辑，但：
#   - 二进制改为从本仓库 bin/qbittorrent/<版本>/<架构>/ 取（静态编译，直接可跑）
#   - 密码工具 libqbpasswd 从本仓库 bin/tools/<架构>/ 取
#   - 版本与配置格式由 versions/qbittorrent.list 驱动
# 依赖 lib/common.sh 已被 source。
# ---------------------------------------------------------------------------

if [[ -n "${SEEDBOX_QB_SOURCED:-}" ]]; then return 0; fi
readonly SEEDBOX_QB_SOURCED=1

# 从清单载入可用 qB 版本，结果放入全局数组。
qb_load_versions() {
    QB_VERS=(); QB_LIBS=(); QB_FMTS=(); QB_DESCS=()
    local line ver lib fmt desc
    while IFS= read -r line; do
        IFS='|' read -r ver lib fmt desc <<<"$line"
        [[ -z "$ver" ]] && continue
        QB_VERS+=("$ver"); QB_LIBS+=("$lib"); QB_FMTS+=("$fmt"); QB_DESCS+=("$desc")
    done < <(read_list "versions/qbittorrent.list")
}

# 按版本号查其配置格式代号；找不到返回空。
qb_format_for() {
    local want="$1" i
    qb_load_versions
    for i in "${!QB_VERS[@]}"; do
        [[ "${QB_VERS[$i]}" == "$want" ]] && { echo "${QB_FMTS[$i]}"; return 0; }
    done
    echo ""
}

# 主安装函数。
#   qb_install_do <username> <password> <qb_ver> <cache_MiB> <webui_port> <incoming_port>
qb_install_do() {
    local username="$1" password="$2" qb_ver="$3" qb_cache="$4" qb_port="$5" qb_incoming_port="$6"
    local arch fmt

    arch="$(detect_arch)"
    [[ -z "$arch" ]] && { error "不支持的 CPU 架构：$(uname -m)"; return 1; }

    fmt="$(qb_format_for "$qb_ver")"
    [[ -z "$fmt" ]] && { error "版本 $qb_ver 不在清单 versions/qbittorrent.list 中。"; return 1; }

    # ---- 停掉可能在跑的实例 ----
    if pgrep -i -f qbittorrent-nox >/dev/null 2>&1; then
        warn "检测到 qBittorrent 正在运行，尝试停止..."
        systemctl stop "qbittorrent-nox@${username}" >/dev/null 2>&1 || true
        pkill -i -f qbittorrent-nox >/dev/null 2>&1 || true
        sleep 2
    fi

    # ---- 创建用户 ----
    if ! id "$username" >/dev/null 2>&1; then
        info "创建用户 $username"
        local enc
        enc="$(perl -e 'print crypt($ARGV[0], "sb")' "$password" 2>/dev/null || openssl passwd -1 "$password")"
        useradd -m -p "$enc" -s /bin/bash "$username" || { error "创建用户失败"; return 1; }
    else
        info "用户 $username 已存在，复用之。"
    fi

    # ---- 放置二进制 ----
    local bin_rel="bin/qbittorrent/${qb_ver}/${arch}/qbittorrent-nox"
    info "部署 qbittorrent-nox (${qb_ver}, ${arch})..."
    if [[ -e /usr/bin/qbittorrent-nox ]]; then
        warn "已存在 /usr/bin/qbittorrent-nox，替换之。"
        rm -f /usr/bin/qbittorrent-nox
    fi
    if ! fetch_file "$bin_rel" /usr/bin/qbittorrent-nox; then
        error "获取 qbittorrent-nox 失败：$bin_rel"
        error "请确认已把静态二进制放入仓库对应路径。"
        return 1
    fi
    chmod +x /usr/bin/qbittorrent-nox

    # 快速自检：静态二进制应能打印版本
    if ! /usr/bin/qbittorrent-nox --version >/dev/null 2>&1; then
        warn "qbittorrent-nox --version 未能正常返回（若为静态编译通常仍可运行，继续）。"
    fi

    # ---- 目录 ----
    mkdir -p "/home/${username}/qbittorrent/Downloads"
    chown -R "${username}:${username}" "/home/${username}/qbittorrent/"
    mkdir -p "/home/${username}/.config/qBittorrent"
    chown "${username}:${username}" "/home/${username}/.config/qBittorrent"

    # ---- systemd 服务（system 级，按用户运行）----
    if [[ -e /etc/systemd/system/qbittorrent-nox@.service ]]; then
        warn "qbittorrent-nox@.service 已存在，覆盖之。"
    fi
    cat >/etc/systemd/system/qbittorrent-nox@.service <<EOF
[Unit]
Description=qBittorrent-nox service for %i
After=network.target

[Service]
Type=exec
User=%i
LimitNOFILE=infinity
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure
TimeoutStopSec=10
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "qbittorrent-nox@${username}" >/dev/null 2>&1

    # ---- 首次启动以生成基础配置，然后停掉再写我们的配置 ----
    systemctl start "qbittorrent-nox@${username}" >/dev/null 2>&1 || true
    sleep 3
    systemctl stop "qbittorrent-nox@${username}" >/dev/null 2>&1 || true
    sleep 1

    # ---- 依磁盘类型/虚拟化推导缓冲参数（沿用旧版数值）----
    local aio low_buffer buffer buffer_factor
    if is_virtual; then
        warn "检测到虚拟化环境，采用保守缓冲参数。"
        aio=8; low_buffer=3072; buffer=12288; buffer_factor=200
    else
        local disk_name disktype
        disk_name="$(lsblk -dno NAME 2>/dev/null | head -n1)"
        disktype=1
        if [[ -n "$disk_name" && -r "/sys/block/${disk_name}/queue/rotational" ]]; then
            disktype="$(cat "/sys/block/${disk_name}/queue/rotational" 2>/dev/null || echo 1)"
        fi
        if [[ "$disktype" == "0" ]]; then
            aio=8; low_buffer=5120; buffer=20480; buffer_factor=200   # SSD/NVMe
        else
            aio=4; low_buffer=3072; buffer=10240; buffer_factor=150   # HDD
        fi
    fi

    # ---- 生成 WebUI 密码哈希（PBKDF2，via libqbpasswd）----
    local pbkdf2 tool_rel tool_path
    tool_rel="bin/tools/${arch}/libqbpasswd"
    tool_path="$(mktemp)"
    if ! fetch_file "$tool_rel" "$tool_path"; then
        error "获取密码工具 libqbpasswd 失败：$tool_rel"
        error "请把编译好的 libqbpasswd 放入仓库对应路径。"
        return 1
    fi
    chmod +x "$tool_path"
    pbkdf2="$("$tool_path" "$password" 2>/dev/null)"
    rm -f "$tool_path"
    if [[ -z "$pbkdf2" ]]; then
        error "libqbpasswd 未能生成密码哈希。"
        return 1
    fi

    # ---- 写配置文件（按格式代号选择模板）----
    local conf="/home/${username}/.config/qBittorrent/qBittorrent.conf"
    if [[ "$fmt" == "legacy43" ]]; then
        # 4.2.x / 4.3.x 格式
        cat >"$conf" <<EOF
[BitTorrent]
Session\\AsyncIOThreadsCount=${aio}
Session\\SendBufferLowWatermark=${low_buffer}
Session\\SendBufferWatermark=${buffer}
Session\\SendBufferWatermarkFactor=${buffer_factor}

[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
Connection\\PortRangeMin=${qb_incoming_port}
Downloads\\DiskWriteCacheSize=${qb_cache}
Downloads\\SavePath=/home/${username}/qbittorrent/Downloads/
Queueing\\QueueingEnabled=false
WebUI\\Password_PBKDF2="@ByteArray(${pbkdf2})"
WebUI\\Port=${qb_port}
WebUI\\Username=${username}
EOF
    else
        # modern44：4.4.x 及以后（含 5.x）
        cat >"$conf" <<EOF
[Application]
MemoryWorkingSetLimit=${qb_cache}

[BitTorrent]
Session\\AsyncIOThreadsCount=${aio}
Session\\DefaultSavePath=/home/${username}/qbittorrent/Downloads/
Session\\DiskCacheSize=${qb_cache}
Session\\Port=${qb_incoming_port}
Session\\QueueingSystemEnabled=false
Session\\SendBufferLowWatermark=${low_buffer}
Session\\SendBufferWatermark=${buffer}
Session\\SendBufferWatermarkFactor=${buffer_factor}

[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
WebUI\\Password_PBKDF2="@ByteArray(${pbkdf2})"
WebUI\\Port=${qb_port}
WebUI\\Username=${username}
EOF
    fi
    chown -R "${username}:${username}" "/home/${username}/.config/"

    # ---- 启动 ----
    systemctl start "qbittorrent-nox@${username}" >/dev/null 2>&1
    sleep 3

    local publicip
    publicip="$(curl -fsSL https://ipinfo.io/ip 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"

    if systemctl is-active --quiet "qbittorrent-nox@${username}"; then
        success "qBittorrent 已启动。"
        echo "  WebUI 地址 : http://${publicip:-<服务器IP>}:${qb_port}"
        echo "  用户名     : ${username}"
        echo "  密码       : ${password}"
        echo "  下载目录   : /home/${username}/qbittorrent/Downloads/"
        echo "  连接端口   : ${qb_incoming_port}"
        return 0
    else
        error "qBittorrent 启动失败。查看日志： journalctl -u qbittorrent-nox@${username} -n 50"
        return 1
    fi
}

# ---- 交互式收集参数并安装（供菜单调用）----
qb_menu() {
    title "安装 qBittorrent"
    qb_load_versions
    if [[ ${#QB_VERS[@]} -eq 0 ]]; then
        error "清单中没有可用的 qBittorrent 版本。"
        pause; return 1
    fi
    echo "可安装版本："
    local i
    for i in "${!QB_VERS[@]}"; do
        printf "  %d) %-10s (libtorrent %-8s) %s\n" \
            "$((i+1))" "${QB_VERS[$i]}" "${QB_LIBS[$i]}" "${QB_DESCS[$i]}"
    done
    echo
    ask "选择版本编号" "1"
    local ci="$REPLY_VALUE"
    if ! [[ "$ci" =~ ^[0-9]+$ ]] || (( ci<1 || ci>${#QB_VERS[@]} )); then
        warn "无效编号。"; pause; return 1
    fi
    local qb_ver="${QB_VERS[$((ci-1))]}"

    ask "WebUI 用户名" "admin"
    local username="$REPLY_VALUE"
    [[ -z "$username" ]] && { warn "用户名不能为空。"; pause; return 1; }

    local password
    while true; do
        read -rsp "${_C_CYAN}WebUI 密码${_C_RESET}: " password; echo
        [[ -n "$password" ]] && break
        warn "密码不能为空。"
    done

    ask "磁盘缓存大小 (MiB，建议为内存的 1/4)" "2048"
    local qb_cache="$REPLY_VALUE"
    [[ "$qb_cache" =~ ^[0-9]+$ ]] || { warn "缓存必须是数字。"; pause; return 1; }

    ask "WebUI 端口" "8080"
    local qb_port="$REPLY_VALUE"
    ask "BT 连接(incoming)端口" "45000"
    local qb_incoming_port="$REPLY_VALUE"

    echo
    info "即将安装：qBittorrent ${qb_ver} / 用户 ${username} / 缓存 ${qb_cache}MiB / WebUI 端口 ${qb_port}"
    if confirm "确认开始安装？"; then
        qb_install_do "$username" "$password" "$qb_ver" "$qb_cache" "$qb_port" "$qb_incoming_port"
    fi
    pause
}
