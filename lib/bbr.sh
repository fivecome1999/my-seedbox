#!/bin/bash
# lib/bbr.sh —— BBR 变种管理模块
# 职责：
#   - 从 versions/bbr.list 读取可用变种，按当前系统过滤
#   - 安装选定变种（下载对应 BBR/<Name>/<Name>.sh，注册开机自启，重启后编译）
#   - 切换/恢复：整合自你上传的 bbr_switch.sh
# 依赖 lib/common.sh 已被 source。
# ---------------------------------------------------------------------------

if [[ -n "${SEEDBOX_BBR_SOURCED:-}" ]]; then return 0; fi
readonly SEEDBOX_BBR_SOURCED=1

# 由 id 推出安装脚本相对路径与脚本名。
# 约定：id=bbrx     → 目录 BBR/BBRx     脚本 BBRx.sh
#       id=bbrz     → 目录 BBR/BBRz     脚本 BBRz.sh
#       id=bbrx_old → 目录 BBR/BBRx_old 脚本 BBRx_old.sh
# 规则：取 id，把开头的 bbr 之后首字母大写，其余保留（含下划线后缀）。
_bbr_script_name() {
    local id="$1"
    case "$id" in
        bbrx)     echo "BBRx" ;;
        bbrz)     echo "BBRz" ;;
        bbrx_old) echo "BBRx_old" ;;
        *)
            # 通用回退：bbr<x...> → BBR<X...>
            local rest="${id#bbr}"
            local first="${rest:0:1}"
            local tail="${rest:1}"
            printf 'BBR%s%s' "$(echo "$first" | tr '[:lower:]' '[:upper:]')" "$tail"
            ;;
    esac
}

# 打印当前 BBR 状态
bbr_status() {
    local cc qdisc kernel
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
    kernel="$(uname -r)"
    printf '  当前拥塞控制算法 : %s\n' "$cc"
    printf '  当前默认 qdisc    : %s\n' "$qdisc"
    printf '  当前内核版本      : %s\n' "$kernel"
    if command -v dkms >/dev/null 2>&1; then
        local dk
        dk="$(dkms status 2>/dev/null | grep -Ei 'bbr' || true)"
        [[ -n "$dk" ]] && printf '  已编译的 BBR 模块 :\n%s\n' "$(echo "$dk" | sed 's/^/      /')"
    fi
}

# 列出当前系统可用的变种。结果通过全局数组返回：
#   BBR_IDS   变种 id（如 bbrx_old）
#   BBR_NAMES 显示名
#   BBR_CANAMES 内核算法名（sysctl 用，如 bbrxold）
#   BBR_DESCS 说明
bbr_load_variants() {
    BBR_IDS=(); BBR_NAMES=(); BBR_CANAMES=(); BBR_DESCS=()
    local cur line id name sys ca desc
    cur="$(detect_os)"
    while IFS= read -r line; do
        IFS='|' read -r id name sys ca desc <<<"$line"
        [[ -z "$id" ]] && continue
        # 兼容旧格式（无算法名字段）：若 ca 为空则回退用 id
        [[ -z "$ca" ]] && ca="$id"
        # 系统过滤
        local ok=0
        local s
        local oldIFS="$IFS"; IFS=','
        for s in $sys; do [[ "$s" == "$cur" ]] && ok=1; done
        IFS="$oldIFS"
        [[ $ok -eq 1 ]] || continue
        BBR_IDS+=("$id"); BBR_NAMES+=("$name"); BBR_CANAMES+=("$ca"); BBR_DESCS+=("$desc")
    done < <(read_list "versions/bbr.list")
}

# 由 id 查内核算法名；查不到回退为 id 本身。
bbr_caname_for() {
    local want="$1" i
    bbr_load_variants
    for i in "${!BBR_IDS[@]}"; do
        [[ "${BBR_IDS[$i]}" == "$want" ]] && { echo "${BBR_CANAMES[$i]}"; return 0; }
    done
    echo "$want"
}

# 安装指定变种（按 id）。会：
#   1) 下载 BBR/<Name>/<Name>.sh 到 /root/
#   2) 建立 bbrinstall.service，开机后自动执行该脚本（脚本内部会编译并在完成后重启）
# 说明：沿用原项目"重启后用 systemd 一次性服务编译 BBR"的机制，因为编译需匹配
#       目标内核，且原脚本结尾会 shutdown 重启，交互式直接跑会打断安装流程。
bbr_install() {
    local id="$1"
    local name script_rel script_local
    name="$(_bbr_script_name "$id")"
    script_rel="BBR/${name}/${name}.sh"
    script_local="/root/${name}.sh"

    if ! os_supported "debian12,debian13"; then
        error "BBR 编译目前仅支持 Debian 12 / Debian 13。当前系统不受支持。"
        return 1
    fi

    info "准备安装 BBR 变种：${name}"
    ensure_packages dkms || return 1

    # 关键前置：确保"重启后运行的内核"有可安装的匹配头文件。
    # 云镜像自带的内核往往已被软件源淘汰（对应 headers 已下架），导致重启后
    # 编译失败并静默等待下次重试（表现为"要重启两次才装上"）。
    # 这里先把最新内核+头文件装好，重启后即以新内核编译，一次重启即可完成。
    info "预装最新内核与头文件（确保重启后可编译，可能需要下载几十MB）..."
    apt_refresh
    local karch kflavor img_pkg hdr_pkg
    karch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    if uname -r | grep -q '\-cloud-'; then kflavor="cloud-"; else kflavor=""; fi
    img_pkg="linux-image-${kflavor}${karch}"
    hdr_pkg="linux-headers-${kflavor}${karch}"
    if DEBIAN_FRONTEND=noninteractive apt-get -y install "$img_pkg" "$hdr_pkg" >/dev/null 2>&1; then
        info "内核与头文件已就绪（${img_pkg} / ${hdr_pkg}）。"
    else
        warn "内核/头文件预装未完全成功（可能被后台更新占用 apt 锁），编译阶段会再次尝试。"
    fi

    if ! fetch_file "$script_rel" "$script_local"; then
        error "下载安装脚本失败：$script_rel"
        return 1
    fi
    chmod +x "$script_local"

    # 建立开机自启服务（一次性，编译完由脚本自身清理）。
    # 必须等待网络真正可用（network-online），network.target 不保证连通性，
    # 否则开机过早执行会因下载源码失败而中断。
    cat >/etc/systemd/system/bbrinstall.service <<EOF
[Unit]
Description=BBR (${name}) delayed install
Wants=network-online.target
After=network-online.target network.target

[Service]
Type=oneshot
ExecStart=${script_local}
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable bbrinstall.service >/dev/null 2>&1

    local caname
    caname="$(bbr_caname_for "$id")"
    success "已配置 ${name} 安装服务。"
    warn "重启后系统会自动编译 BBR（约 2-3 分钟），完成后会【自动再重启一次】收尾。"
    warn "两次重启都结束后，用  sysctl net.ipv4.tcp_congestion_control  确认已切换为 ${caname}。"
    warn "若等待 10 分钟仍未生效，用  journalctl -u bbrinstall.service -b -1  查看编译日志排查。"
    return 0
}

# 恢复系统自带 BBR（整合自你 bbr_switch.sh 的选项4）
bbr_restore_default() {
    info "恢复系统自带 BBR..."
    # 移除定制模块的开机加载项（幂等）
    sed -i '/tcp_bbrx_old/d;/tcp_bbrx/d;/tcp_bbrz/d' /etc/modules 2>/dev/null || true

    # 持久化写 /etc/sysctl.d/（Debian 13 开机不读 /etc/sysctl.conf），
    # 并清掉 sysctl.conf 里的旧条目防止混淆。
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    cat >/etc/sysctl.d/99-zz-seedbox-bbr.conf <<'EOF'
# 由 my-seedbox 生成：系统自带 BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -p /etc/sysctl.d/99-zz-seedbox-bbr.conf >/dev/null 2>&1 || true
    success "已切换回系统自带 BBR。"
}

# 卸载定制 BBR 的 dkms 模块（可选清理）
bbr_remove_module() {
    local id="$1"
    if ! command -v dkms >/dev/null 2>&1; then
        warn "未安装 dkms，无需清理。"
        return 0
    fi
    local found=0 mv
    for mv in $(dkms status 2>/dev/null | grep "${id}/" | awk -F, '{print $1}' | awk -F/ '{print $2}' | sort -u); do
        found=1
        info "移除 dkms 模块 ${id}/${mv}"
        dkms remove -m "$id" -v "$mv" --all || true
    done
    [[ $found -eq 0 ]] && info "未找到 ${id} 的已编译模块。"
    sed -i "/tcp_${id}/d" /etc/modules 2>/dev/null || true
}

# ---- 交互式 BBR 菜单（供主菜单调用）----
bbr_menu() {
    while true; do
        title "BBR 版本管理"
        bbr_status
        echo
        bbr_load_variants
        if [[ ${#BBR_IDS[@]} -eq 0 ]]; then
            warn "当前系统没有可用的 BBR 变种（仅支持 Debian 12/13）。"
        else
            echo "可安装的 BBR 变种："
            local i
            for i in "${!BBR_IDS[@]}"; do
                printf "  %d) %-22s %s\n" "$((i+1))" "${BBR_NAMES[$i]}" "${BBR_DESCS[$i]}"
            done
        fi
        local n_variants=${#BBR_IDS[@]}
        echo
        printf "  r) 恢复系统自带 BBR\n"
        printf "  c) 清理某个定制 BBR 的已编译模块\n"
        printf "  0) 返回上级菜单\n"
        echo
        ask "请输入选项" ""
        local choice="$REPLY_VALUE"

        case "$choice" in
            0) return 0 ;;
            r|R) bbr_restore_default; pause ;;
            c|C)
                if [[ $n_variants -eq 0 ]]; then warn "无可清理项。"; pause; continue; fi
                ask "输入要清理的变种编号" ""
                local ci="$REPLY_VALUE"
                if [[ "$ci" =~ ^[0-9]+$ ]] && (( ci>=1 && ci<=n_variants )); then
                    bbr_remove_module "${BBR_IDS[$((ci-1))]}"
                else
                    warn "无效编号。"
                fi
                pause ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=n_variants )); then
                    local sel_id="${BBR_IDS[$((choice-1))]}"
                    if confirm "确认安装 ${BBR_NAMES[$((choice-1))]}？(重启后编译)"; then
                        bbr_install "$sel_id"
                        if confirm "现在重启以完成 BBR 编译？"; then
                            info "系统即将重启..."
                            sleep 2
                            shutdown -r now
                        else
                            warn "稍后请手动重启以完成 BBR 安装。"
                        fi
                    fi
                    pause
                else
                    warn "无效选项。"
                    pause
                fi ;;
        esac
    done
}
