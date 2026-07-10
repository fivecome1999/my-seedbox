#!/bin/bash
# lib/common.sh —— 公共函数库
# 被 install.sh 及各模块 source。集中放置：颜色输出、日志、下载、
# 系统/架构检测、清单解析等通用能力。
# ---------------------------------------------------------------------------

# 防止重复 source
if [[ -n "${SEEDBOX_COMMON_SOURCED:-}" ]]; then
    return 0
fi
readonly SEEDBOX_COMMON_SOURCED=1

# ===== 仓库配置 =============================================================
# 所有远程资源都从这里取。改用户名/仓库名/分支只需改这三个变量。
: "${SEEDBOX_GH_USER:=fivecome1999}"
: "${SEEDBOX_GH_REPO:=my-seedbox}"
: "${SEEDBOX_GH_BRANCH:=main}"

# raw 文件基址（注意：raw 域名对目录名里的空格等需转义，这里全用无空格目录名规避）
SEEDBOX_RAW_BASE="https://raw.githubusercontent.com/${SEEDBOX_GH_USER}/${SEEDBOX_GH_REPO}/${SEEDBOX_GH_BRANCH}"

# 本地运行根目录：install.sh 会把自己所在目录（或下载到的临时目录）传进来。
# 若脚本是通过 wget 管道直接跑的，则本地没有配套文件，需要联网取——
# 这个变量为空时，各模块自动走远程 URL；非空时优先用本地文件。
: "${SEEDBOX_LOCAL_ROOT:=}"

# ===== 颜色与输出 ===========================================================
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    _C_RESET=$'\033[0m'
    _C_RED=$'\033[0;31m'
    _C_GREEN=$'\033[0;32m'
    _C_YELLOW=$'\033[0;33m'
    _C_BLUE=$'\033[0;34m'
    _C_CYAN=$'\033[0;36m'
    _C_BOLD=$'\033[1m'
else
    _C_RESET=''; _C_RED=''; _C_GREEN=''; _C_YELLOW=''
    _C_BLUE=''; _C_CYAN=''; _C_BOLD=''
fi

info()    { printf '%s\n' "${_C_CYAN}[*]${_C_RESET} $*"; }
success() { printf '%s\n' "${_C_GREEN}[+]${_C_RESET} $*"; }
warn()    { printf '%s\n' "${_C_YELLOW}[!]${_C_RESET} $*" >&2; }
error()   { printf '%s\n' "${_C_RED}[x]${_C_RESET} $*" >&2; }
title()   { printf '\n%s\n' "${_C_BOLD}${_C_BLUE}==== $* ====${_C_RESET}"; }

# 致命错误：打印并退出
die() { error "$*"; exit 1; }

# 需要 root
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "本脚本需要 root 权限运行，请用 root 或 sudo。"
    fi
}

# ===== 系统与架构检测 =======================================================

# 返回归一化架构：amd64 / arm64；不支持则空
detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             echo "" ;;
    esac
}

# 载入 /etc/os-release，导出 OS_ID / OS_VER_MAJOR
# 返回归一化系统代号：debian12 / debian13 / ubuntu2204 ... ；不支持则空
detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        echo ""
        return
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VER_MAJOR="${VERSION_ID%%.*}"
    echo "${OS_ID}${OS_VER_MAJOR}"
}

# 判断当前是否为受支持的系统（BBR 编译目前只保证 Debian 12/13）
# 参数：$1 = 需要的系统列表（逗号分隔），为空则只要能识别即可
os_supported() {
    local want="$1" cur
    cur="$(detect_os)"
    [[ -z "$cur" ]] && return 1
    [[ -z "$want" ]] && return 0
    local IFS=','
    local o
    for o in $want; do
        [[ "$o" == "$cur" ]] && return 0
    done
    return 1
}

# 是否处于虚拟化环境（用于优化模块决定跳过某些硬件相关调优）
is_virtual() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local v
        v="$(systemd-detect-virt 2>/dev/null || true)"
        [[ -n "$v" && "$v" != "none" ]]
    else
        return 1
    fi
}

# ===== 下载 =================================================================
# 统一下载函数。优先本地文件（SEEDBOX_LOCAL_ROOT 下的相对路径），
# 找不到再从仓库 raw 下载。
#   fetch_file <仓库内相对路径> <输出路径>
# 成功返回 0，失败返回 1。
fetch_file() {
    local rel="$1" out="$2"

    # 1) 本地优先
    if [[ -n "$SEEDBOX_LOCAL_ROOT" && -f "${SEEDBOX_LOCAL_ROOT}/${rel}" ]]; then
        cp "${SEEDBOX_LOCAL_ROOT}/${rel}" "$out" && return 0
        return 1
    fi

    # 2) 远程
    local url="${SEEDBOX_RAW_BASE}/${rel}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out" && return 0
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url" && return 0
    else
        error "系统缺少 curl 和 wget，无法下载。"
        return 1
    fi
    return 1
}

# 读取仓库内文本文件到 stdout（用于读清单）
fetch_text() {
    local rel="$1"
    if [[ -n "$SEEDBOX_LOCAL_ROOT" && -f "${SEEDBOX_LOCAL_ROOT}/${rel}" ]]; then
        cat "${SEEDBOX_LOCAL_ROOT}/${rel}"
        return 0
    fi
    local url="${SEEDBOX_RAW_BASE}/${rel}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url"
    else
        return 1
    fi
}

# ===== 清单解析 =============================================================
# 通用清单读取：跳过空行和 # 注释行，逐行回显有效条目。
#   read_list <仓库内清单相对路径>
read_list() {
    local rel="$1" line
    fetch_text "$rel" | while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        printf '%s\n' "$line"
    done
}

# ===== 依赖安装 =============================================================
# 更新 apt 索引（每次运行至多一次）
_APT_UPDATED=""
apt_refresh() {
    [[ -n "$_APT_UPDATED" ]] && return 0
    info "更新软件包索引..."
    DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null 2>&1 || \
        warn "apt-get update 有警告，继续。"
    _APT_UPDATED=1
}

# 确保若干包已安装
#   ensure_packages pkg1 pkg2 ...
ensure_packages() {
    local missing=()
    local p
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    apt_refresh
    info "安装依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -y install "${missing[@]}" >/dev/null 2>&1 || {
        error "依赖安装失败：${missing[*]}"
        return 1
    }
    return 0
}

# ===== 交互辅助 =============================================================
# 通用输入提示（带默认值）
#   ask "提示" 默认值 -> 结果写入全局 REPLY_VALUE
ask() {
    local prompt="$1" default="${2:-}" ans
    if [[ -n "$default" ]]; then
        read -rp "${_C_CYAN}${prompt}${_C_RESET} [${default}]: " ans
        REPLY_VALUE="${ans:-$default}"
    else
        read -rp "${_C_CYAN}${prompt}${_C_RESET}: " ans
        REPLY_VALUE="$ans"
    fi
}

# 是/否确认，默认否
confirm() {
    local prompt="$1" ans
    read -rp "${_C_YELLOW}${prompt}${_C_RESET} [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# 暂停等待回车
pause() {
    read -rp "按回车键继续..." _ || true
}
