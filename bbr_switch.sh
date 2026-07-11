#!/bin/bash
# ===========================================================================
# bbr_switch.sh —— BBR 拥塞控制自由切换（独立脚本）
#
#   支持在 bbr(系统自带) / bbrx / bbrz / bbrx_old 之间自由切换。
#
# 核心特性「智能切换」：
#   - 目标变种的内核模块【已编译】→ 即时切换（modprobe + sysctl），无需重启
#   - 目标变种【未编译】          → 触发编译安装流程（DKMS，完成后需重启一次）
#   - 系统自带 bbr                → 始终即时切换，无需重启
#
# 用法：
#   交互菜单： bash bbr_switch.sh
#   直接切换： bash bbr_switch.sh <bbr|bbrx|bbrz|bbrx_old>
#   查看状态： bash bbr_switch.sh status
#
# 说明：自定义变种(bbrx/bbrz/bbrx_old)的模块由本项目 install.sh 首次编译，
#       之后本脚本可在它们之间秒切。若目标从未编译过，本脚本会调用对应的
#       BBR/<Name>/<Name>.sh 安装脚本，该脚本编译完成后会自动重启。
# ===========================================================================

set -o pipefail

# ---- 仓库配置（与主项目一致）----
GH_USER="${SEEDBOX_GH_USER:-fivecome1999}"
GH_REPO="${SEEDBOX_GH_REPO:-my-seedbox}"
GH_BRANCH="${SEEDBOX_GH_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}"

# ---- 变种表 ----
# 每项： id  显示名  内核算法名(sysctl值)  安装脚本相对路径
# 内核算法名与 id 多数相同；bbrx_old 特殊 → bbrxold（模块名仍是 tcp_bbrx_old）。
VARIANT_IDS=(bbr bbrx bbrz bbrx_old)
declare -A V_LABEL=(
  [bbr]="BBR（系统自带）"
  [bbrx]="BBRx（通用优化版）"
  [bbrz]="BBRz（激进吞吐版）"
  [bbrx_old]="BBRx Old（旧版手感）"
)
# 内核拥塞控制算法名（sysctl net.ipv4.tcp_congestion_control 用）
declare -A V_CANAME=(
  [bbr]="bbr"
  [bbrx]="bbrx"
  [bbrz]="bbrz"
  [bbrx_old]="bbrxold"
)
# 内核模块名（modprobe / dkms 用）
declare -A V_MODULE=(
  [bbr]="tcp_bbr"
  [bbrx]="tcp_bbrx"
  [bbrz]="tcp_bbrz"
  [bbrx_old]="tcp_bbrx_old"
)
# DKMS 包名（自定义变种才有）
declare -A V_DKMS=(
  [bbrx]="bbrx"
  [bbrz]="bbrz"
  [bbrx_old]="bbrx_old"
)
# 安装脚本相对路径（自定义变种才有）
declare -A V_SCRIPT=(
  [bbrx]="BBR/BBRx/BBRx.sh"
  [bbrz]="BBR/BBRz/BBRz.sh"
  [bbrx_old]="BBR/BBRx_old/BBRx_old.sh"
)

# ---- 颜色 ----
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''
fi
info(){ printf '%s\n' "${C_CYAN}[*]${C_RESET} $*"; }
ok(){ printf '%s\n' "${C_GREEN}[+]${C_RESET} $*"; }
warn(){ printf '%s\n' "${C_YELLOW}[!]${C_RESET} $*" >&2; }
err(){ printf '%s\n' "${C_RED}[x]${C_RESET} $*" >&2; }

# ---- 前置检查 ----
[[ "$(id -u)" -eq 0 ]] || { err "请以 root 运行本脚本。"; exit 1; }

# ---- 工具函数 ----

# 当前生效的拥塞控制算法
current_ca(){ sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown"; }

# 内核当前可用的拥塞控制算法列表（已注册的）
available_ca(){ sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo ""; }

# 判断某算法名当前是否已在内核注册（可直接切换）
ca_registered(){
  local ca="$1"
  local list; list=" $(available_ca) "
  [[ "$list" == *" $ca "* ]]
}

# 判断某自定义变种是否已由 DKMS 编译安装（installed 状态）
dkms_installed(){
  local pkg="$1"
  command -v dkms >/dev/null 2>&1 || return 1
  dkms status 2>/dev/null | grep -q "^${pkg}[/,].*installed"
}

# 尝试把某模块 modprobe 进内核（成功返回0）
try_modprobe(){
  local mod="$1"
  modprobe "$mod" 2>/dev/null
}

# 判断目标变种的模块「是否已经可用」= 已注册 或 (已编译且能modprobe)
variant_ready(){
  local id="$1"
  local ca="${V_CANAME[$id]}" mod="${V_MODULE[$id]}" pkg="${V_DKMS[$id]:-}"

  # 系统自带 bbr：内核基本都带，尝试 modprobe 后看是否注册
  if [[ "$id" == "bbr" ]]; then
    ca_registered bbr && return 0
    try_modprobe tcp_bbr && ca_registered bbr && return 0
    return 1
  fi

  # 自定义变种：已注册直接就绪
  ca_registered "$ca" && return 0
  # 已 DKMS 安装 → 尝试加载
  if [[ -n "$pkg" ]] && dkms_installed "$pkg"; then
    try_modprobe "$mod" && ca_registered "$ca" && return 0
  fi
  # 模块文件存在也尝试一下（例如手动装过）
  try_modprobe "$mod" && ca_registered "$ca" && return 0
  return 1
}

# 把 sysctl 持久化并立即生效
persist_and_apply(){
  local ca="$1" mod="$2"
  # /etc/modules：确保目标模块开机自载（系统自带 bbr 不必写）
  if [[ "$mod" != "tcp_bbr" ]]; then
    sed -i "\#^${mod}\$#d" /etc/modules 2>/dev/null || true
    grep -qx "$mod" /etc/modules 2>/dev/null || echo "$mod" >> /etc/modules
  fi
  # 持久化必须写 /etc/sysctl.d/（Debian 13 起开机不再读取 /etc/sysctl.conf）。
  # 同时清掉 sysctl.conf 里的旧条目，避免两处配置漂移。
  sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
  cat > /etc/sysctl.d/99-zz-seedbox-bbr.conf <<EOF
# 由 my-seedbox bbr_switch.sh 生成（zz 前缀确保排序在其它 99-* 之后、优先生效）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $ca
EOF
  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
  sysctl -w "net.ipv4.tcp_congestion_control=$ca" >/dev/null 2>&1
}

# 下载并运行某变种的编译安装脚本（该脚本会在结尾重启）
compile_variant(){
  local id="$1"
  local rel="${V_SCRIPT[$id]}" name
  name="$(basename "$rel")"
  info "变种 ${V_LABEL[$id]} 尚未编译，准备下载安装脚本进行编译..."
  # 确保 dkms 在
  if ! command -v dkms >/dev/null 2>&1; then
    info "安装 dkms..."
    apt-get -y install dkms >/dev/null 2>&1 || { err "dkms 安装失败。"; return 1; }
  fi
  local tmp="/root/${name}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${RAW_BASE}/${rel}" -o "$tmp" || { err "下载 ${rel} 失败。"; return 1; }
  else
    wget -qO "$tmp" "${RAW_BASE}/${rel}" || { err "下载 ${rel} 失败。"; return 1; }
  fi
  chmod +x "$tmp"
  warn "即将开始编译 ${V_LABEL[$id]}。该过程会在完成后自动重启系统。"
  warn "重启后请再次运行本脚本确认已切换到 ${V_CANAME[$id]}。"
  read -rp "按回车开始（Ctrl+C 取消）..." _ || { warn "已取消。"; return 1; }
  bash "$tmp"
}

# 执行切换主逻辑
do_switch(){
  local id="$1"
  # 合法性
  if [[ -z "${V_LABEL[$id]:-}" ]]; then
    err "未知变种：$id（可选：${VARIANT_IDS[*]}）"
    return 1
  fi
  local ca="${V_CANAME[$id]}" mod="${V_MODULE[$id]}"

  info "目标：${V_LABEL[$id]}  （算法名 ${ca}，模块 ${mod}）"

  if variant_ready "$id"; then
    persist_and_apply "$ca" "$mod"
    local now; now="$(current_ca)"
    if [[ "$now" == "$ca" ]]; then
      ok "已即时切换到 ${V_LABEL[$id]}（当前算法：${now}），无需重启。"
    else
      warn "已写入配置，但当前算法显示为 ${now}。可能需要重启后生效。"
    fi
  else
    # 系统自带 bbr 理论上不该走到这
    if [[ "$id" == "bbr" ]]; then
      err "内核未提供 tcp_bbr 模块，无法切换到系统自带 BBR。"
      return 1
    fi
    compile_variant "$id"
  fi
}

# ---- 状态展示 ----
print_status(){
  printf '%s\n' "${C_BOLD}${C_BLUE}==== BBR 状态 ====${C_RESET}"
  printf '  当前算法      : %s\n' "$(current_ca)"
  printf '  当前 qdisc    : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  printf '  内核版本      : %s\n' "$(uname -r)"
  printf '  内核已注册算法: %s\n' "$(available_ca)"
  echo
  printf '  各变种就绪情况：\n'
  local id state
  for id in "${VARIANT_IDS[@]}"; do
    if ca_registered "${V_CANAME[$id]}"; then
      state="${C_GREEN}已就绪（可秒切）${C_RESET}"
    elif [[ -n "${V_DKMS[$id]:-}" ]] && dkms_installed "${V_DKMS[$id]}"; then
      state="${C_CYAN}已编译（加载后可用）${C_RESET}"
    elif [[ "$id" == "bbr" ]]; then
      state="${C_CYAN}系统自带${C_RESET}"
    else
      state="${C_YELLOW}未编译（切换将触发编译+重启）${C_RESET}"
    fi
    # 标记当前
    local mark="  "
    [[ "$(current_ca)" == "${V_CANAME[$id]}" ]] && mark="${C_GREEN}▶ ${C_RESET}"
    printf '   %b%-10s %-28s %b\n' "$mark" "$id" "${V_LABEL[$id]}" "$state"
  done
}

# ---- 交互菜单 ----
menu(){
  while true; do
    clear 2>/dev/null || true
    print_status
    echo
    printf '%s\n' "${C_BOLD}请选择要切换的目标：${C_RESET}"
    local i
    for i in "${!VARIANT_IDS[@]}"; do
      printf '  %d) 切换到 %s\n' "$((i+1))" "${V_LABEL[${VARIANT_IDS[$i]}]}"
    done
    printf '  s) 刷新状态\n'
    printf '  0) 退出\n'
    echo
    read -rp "输入选项: " choice
    case "$choice" in
      0) echo "已退出。"; exit 0 ;;
      s|S) continue ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#VARIANT_IDS[@]} )); then
          local id="${VARIANT_IDS[$((choice-1))]}"
          echo
          do_switch "$id"
          echo
          read -rp "按回车返回菜单..." _ || true
        else
          warn "无效选项。"; sleep 1
        fi ;;
    esac
  done
}

# ---- 入口 ----
case "${1:-}" in
  ""      ) menu ;;
  status  ) print_status ;;
  bbr|bbrx|bbrz|bbrx_old) do_switch "$1" ;;
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30 ;;
  *)
    err "未知参数：$1"
    echo "用法： bash bbr_switch.sh [bbr|bbrx|bbrz|bbrx_old|status]"
    exit 1 ;;
esac
