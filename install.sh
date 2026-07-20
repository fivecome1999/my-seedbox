#!/bin/bash
# ===========================================================================
# my-seedbox —— 一体化 Seedbox 安装脚本（单入口）
#
# 用法一（交互菜单）：
#   bash <(wget -qO- https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/install.sh)
#
# 用法二（无人值守，命令行参数）：
#   bash <(wget -qO- .../install.sh) -u <用户名> -p <密码> -c <缓存MiB> \
#        -q <qB版本> [-o <WebUI端口>] [-i <连接端口>] [-x <bbr变种>] [-t]
#
# 参数：
#   -u  WebUI 用户名
#   -p  WebUI 密码
#   -c  qBittorrent 磁盘缓存大小（MiB，建议为内存的 1/4）
#   -q  qBittorrent 版本（见 versions/qbittorrent.list，例如 5.0.4 / 4.3.8）
#   -o  WebUI 端口（默认 8080）
#   -i  BT 连接 incoming 端口（默认 45000）
#   -x  启用并安装指定 BBR 变种（bbrx / bbrz / bbrx_old），需重启后编译
#   -t  应用系统优化
#   -h  显示帮助
#
# 只给部分参数时，缺失项会转入交互询问；完全不给参数则进入主菜单。
# ===========================================================================

set -o pipefail

# ---- 定位/加载库 --------------------------------------------------------
# 判断是"本地完整仓库运行"还是"wget 管道单文件运行"。
# 若与本脚本同级存在 lib/common.sh，则视为本地仓库，直接 source 本地文件；
# 否则从远程仓库拉取各库文件到临时目录再 source。
SELF_SRC="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -n "$SELF_SRC" && -f "$SELF_SRC" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$SELF_SRC")" && pwd)"
fi

# 远程库基址（与 common.sh 内保持一致，供 bootstrap 阶段使用）
BOOT_GH_USER="${SEEDBOX_GH_USER:-fivecome1999}"
BOOT_GH_REPO="${SEEDBOX_GH_REPO:-my-seedbox}"
BOOT_GH_BRANCH="${SEEDBOX_GH_BRANCH:-main}"
BOOT_RAW_BASE="https://raw.githubusercontent.com/${BOOT_GH_USER}/${BOOT_GH_REPO}/${BOOT_GH_BRANCH}"

_boot_fetch() {
    # $1 相对路径  $2 输出文件
    local url="${BOOT_RAW_BASE}/$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$2"
    else
        wget -qO "$2" "$url"
    fi
}

LIB_FILES=(lib/common.sh lib/bbr.sh lib/qbittorrent.sh lib/tuning.sh)

if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    # 本地仓库模式
    export SEEDBOX_LOCAL_ROOT="$SCRIPT_DIR"
    for f in "${LIB_FILES[@]}"; do
        # shellcheck disable=SC1090
        source "${SCRIPT_DIR}/${f}"
    done
else
    # 远程管道模式：拉库到临时目录
    BOOT_TMP="$(mktemp -d)"
    trap 'rm -rf "$BOOT_TMP"' EXIT
    mkdir -p "${BOOT_TMP}/lib"
    for f in "${LIB_FILES[@]}"; do
        if ! _boot_fetch "$f" "${BOOT_TMP}/${f}"; then
            echo "错误：无法下载 ${f}，请检查网络或仓库地址。" >&2
            exit 1
        fi
    done
    export SEEDBOX_LOCAL_ROOT=""   # 强制各模块走远程取资源
    for f in "${LIB_FILES[@]}"; do
        # shellcheck disable=SC1090
        source "${BOOT_TMP}/${f}"
    done
fi

# ---- 帮助 --------------------------------------------------------------
usage() {
    cat <<EOF
${_C_BOLD}my-seedbox 安装脚本${_C_RESET}

用法：
  交互菜单： bash install.sh
  无人值守： bash install.sh -u <用户名> -p <密码> -c <缓存MiB> -q <qB版本> [选项]

选项：
  -u  WebUI 用户名
  -p  WebUI 密码（也可留空改用环境变量 QB_PASSWORD 传入，见下）
  -c  qBittorrent 磁盘缓存（MiB，建议为内存 1/4）
  -q  qBittorrent 版本（$(qb_ver_hint)）
  -o  WebUI 端口（默认 8080）
  -i  BT 连接端口（默认 45000）
  -x  安装 BBR 变种：$(bbr_id_hint)（重启后编译）
  -t  应用系统优化
  -h  显示本帮助

示例：
  bash install.sh -u admin -p 'S3cr3t' -c 2048 -q 5.0.4 -t -x bbrx

安全提示：
  -p 的密码会出现在命令行参数里（可能进 shell 历史、被同机用户 ps 看到）。
  更安全的写法是不给 -p，改用环境变量：
    QB_PASSWORD='S3cr3t' bash install.sh -u admin -c 2048 -q 5.0.4 -t
EOF
}

qb_ver_hint() {
    qb_load_versions 2>/dev/null
    local out="" i
    for i in "${!QB_VERS[@]}"; do out+="${QB_VERS[$i]} "; done
    echo "${out:-见 versions/qbittorrent.list}"
}
bbr_id_hint() {
    bbr_load_variants 2>/dev/null
    local out="" i
    for i in "${!BBR_IDS[@]}"; do out+="${BBR_IDS[$i]} "; done
    echo "${out:-bbrx bbrz bbrx_old}"
}

# ---- 系统更新与基础依赖 -------------------------------------------------
system_prepare() {
    require_root
    local osid
    osid="$(detect_os)"
    if [[ -z "$osid" ]]; then
        warn "无法识别系统版本，继续但不保证兼容。"
    else
        info "检测到系统：${osid}"
    fi
    if ! os_supported "debian12,debian13"; then
        warn "注意：BBR 编译目前仅在 Debian 12 / 13 上验证。qBittorrent 与系统优化在其它 Debian/Ubuntu 上通常也可用。"
    fi
    ensure_packages curl wget ca-certificates gnupg lsb-release || \
        warn "部分基础依赖安装失败，继续。"
}

# ---- 主菜单 ------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        printf '%s\n' "${_C_BOLD}${_C_BLUE}"
        cat <<'BANNER'
   ┌────────────────────────────────────────────┐
   │            my-seedbox  安装菜单             │
   │   qBittorrent · 系统优化 · BBR 版本管理     │
   └────────────────────────────────────────────┘
BANNER
        printf '%s\n' "${_C_RESET}"
        echo "  1) 安装 qBittorrent"
        echo "  2) 应用系统优化"
        echo "  3) BBR 版本管理（安装 / 切换 / 恢复）"
        echo "  4) 一键完整安装（qB + 优化 + 选 BBR）"
        echo "  0) 退出"
        echo
        ask "请选择" ""
        case "$REPLY_VALUE" in
            1) qb_menu ;;
            2) tuning_menu ;;
            3) bbr_menu ;;
            4) full_install_interactive ;;
            0) echo "再见。"; exit 0 ;;
            *) warn "无效选择。"; sleep 1 ;;
        esac
    done
}

# 一键完整安装（交互）
full_install_interactive() {
    title "一键完整安装"
    qb_menu
    echo
    if confirm "接着应用系统优化吗？"; then
        tuning_apply_all
        pause
    fi
    echo
    if confirm "需要安装 BBR 变种吗？"; then
        bbr_menu
    fi
}

# ---- 无人值守流程 -------------------------------------------------------
run_unattended() {
    local username="$1" password="$2" cache="$3" qb_ver="$4"
    local webui_port="$5" incoming_port="$6" bbr_variant="$7" do_tuning="$8"

    system_prepare

    # qBittorrent（有版本即安装；缺关键项则补问）
    if [[ -n "$qb_ver" ]]; then
        [[ -z "$username" ]] && { ask "WebUI 用户名" "admin"; username="$REPLY_VALUE"; }
        [[ -z "$cache" ]] && { ask "缓存(MiB)" "2048"; cache="$REPLY_VALUE"; }
        [[ -z "$webui_port" ]] && webui_port=8080
        [[ -z "$incoming_port" ]] && incoming_port=45000

        # 命令行模式下也要校验（交互菜单 qb_menu 里已经校验过，但 -c/-o/-i
        # 这几个参数走命令行直传时此前完全没校验，非法值会被原样写进
        # qBittorrent.conf，导致装完却启动不了、还不容易看出原因）。
        # 校验放在询问密码之前：参数给错时直接报错退出，不让用户白输一次密码。
        if ! [[ "$cache" =~ ^[0-9]+$ ]] || (( cache < 1 )); then
            die "-c 缓存大小必须是正整数（当前：${cache}）"
        fi
        if ! [[ "$webui_port" =~ ^[0-9]+$ ]] || (( webui_port < 1 || webui_port > 65535 )); then
            die "-o WebUI 端口必须是 1-65535 之间的数字（当前：${webui_port}）"
        fi
        if ! [[ "$incoming_port" =~ ^[0-9]+$ ]] || (( incoming_port < 1 || incoming_port > 65535 )); then
            die "-i 连接端口必须是 1-65535 之间的数字（当前：${incoming_port}）"
        fi

        # -p 留空时，先看 QB_PASSWORD 环境变量（给纯无人值守/无 TTY 场景用，
        # 比如 cloud-init：避免密码明文出现在命令行参数里，进 shell 历史、被同机
        # 其它用户 ps 看到）；两者都没有才回退到交互式掩码输入。
        [[ -z "$password" ]] && password="${QB_PASSWORD:-}"
        if [[ -z "$password" ]]; then
            if [[ ! -t 0 ]]; then
                die "未提供密码且无终端可交互：请用 -p 或环境变量 QB_PASSWORD 传入密码。"
            fi
            while true; do
                read -rsp "WebUI 密码: " password; echo
                [[ -n "$password" ]] && break
            done
        fi

        title "安装 qBittorrent"
        qb_install_do "$username" "$password" "$qb_ver" "$cache" "$webui_port" "$incoming_port" || \
            warn "qBittorrent 安装未成功，继续后续步骤。"
    fi

    # 系统优化
    if [[ "$do_tuning" == "1" ]]; then
        tuning_apply_all
    fi

    # BBR
    if [[ -n "$bbr_variant" ]]; then
        title "安装 BBR：${bbr_variant}"
        if bbr_install "$bbr_variant"; then
            warn "BBR 需重启后编译。安装流程结束，请稍后重启服务器。"
        fi
    fi

    echo
    success "全部选定任务已执行完毕。"
}

# ---- 参数解析 ----------------------------------------------------------
ARG_USER="" ARG_PASS="" ARG_CACHE="" ARG_QB=""
ARG_WEBUI_PORT="" ARG_INCOMING_PORT="" ARG_BBR="" ARG_TUNING=""

# 无参数 → 菜单
if [[ $# -eq 0 ]]; then
    require_root
    system_prepare
    main_menu
    exit 0
fi

while getopts "u:p:c:q:o:i:x:th" opt; do
    case "$opt" in
        u) ARG_USER="$OPTARG" ;;
        p) ARG_PASS="$OPTARG" ;;
        c) ARG_CACHE="$OPTARG" ;;
        q) ARG_QB="$OPTARG" ;;
        o) ARG_WEBUI_PORT="$OPTARG" ;;
        i) ARG_INCOMING_PORT="$OPTARG" ;;
        x) ARG_BBR="$OPTARG" ;;
        t) ARG_TUNING="1" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

run_unattended "$ARG_USER" "$ARG_PASS" "$ARG_CACHE" "$ARG_QB" \
               "$ARG_WEBUI_PORT" "$ARG_INCOMING_PORT" "$ARG_BBR" "$ARG_TUNING"
