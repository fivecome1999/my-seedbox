#!/usr/bin/env bash
# cpu.sh (pretty)
set -euo pipefail

SERVICE_PATH="/etc/systemd/system/cpuperf.service"

# ===== 彩色 & 符号 =====
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_DIM="\033[2m"
  C_BLUE="\033[38;5;39m"; C_CYAN="\033[38;5;44m"
  C_GREEN="\033[38;5;40m"; C_YELLOW="\033[38;5;220m"
  C_RED="\033[38;5;196m"; C_MAG="\033[38;5;201m"
else
  C_RESET=""; C_DIM=""; C_BLUE=""; C_CYAN=""
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_MAG=""
fi
OK="${C_GREEN}✔${C_RESET}"
WARN="${C_YELLOW}⚠${C_RESET}"
BAD="${C_RED}✘${C_RESET}"
INFO="${C_CYAN}ℹ${C_RESET}"

say()  { printf "%b\n" "$*"; }
head1(){ say "${C_MAG}━━━ $* ━━━${C_RESET}"; }
ok()   { say " ${OK} $*"; }
warn() { say " ${WARN} $*"; }
bad()  { say " ${BAD} $*"; }
info() { say " ${INFO} $*"; }

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
cpufreq_available(){ [[ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; }

current_governor(){
  local g="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  [[ -f "$g" ]] && cat "$g" || echo "unknown"
}

install_cpupower(){
  if have_cmd cpupower; then ok "cpupower 已安装"; return; fi
  info "安装 cpupower..."
  if have_cmd apt; then
    (apt-get update -y || apt update -y || true) >/dev/null
    apt-get install -y -qq linux-cpupower \
      || apt-get install -y -qq linux-tools-common "linux-tools-$(uname -r)"
  elif have_cmd dnf; then
    dnf -qy install kernel-tools
  elif have_cmd yum; then
    yum -y -q install kernel-tools
  else
    bad "未检测到 apt/dnf/yum，无法自动安装 cpupower"; exit 2
  fi
  if ! have_cmd cpupower && [[ -x /usr/sbin/cpupower ]]; then
    ln -sf /usr/sbin/cpupower /usr/bin/cpupower
  fi
  have_cmd cpupower && ok "cpupower 安装完成" || { bad "cpupower 安装失败"; exit 2; }
}

write_service(){
  tee "$SERVICE_PATH" >/dev/null <<'EOF'
[Unit]
Description=Force CPU governor to performance
ConditionPathExists=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set --governor performance
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  [[ ! -x /usr/bin/cpupower && -x /usr/sbin/cpupower ]] \
    && sed -i 's#/usr/bin/cpupower#/usr/sbin/cpupower#g' "$SERVICE_PATH"
  systemctl daemon-reload
  systemctl enable --now cpuperf.service >/dev/null 2>&1 || true
  ok "已启用 systemd 永久化服务：cpuperf.service"
}

set_governor_now(){
  local bin="/usr/bin/cpupower"; [[ -x $bin ]] || bin="/usr/sbin/cpupower"
  "$bin" frequency-set --governor performance >/dev/null
}

core_summary(){
  # 统计各 governor 数量
  declare -A map=()
  local f total=0
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$f" ]] || continue
    local g; g="$(<"$f")"
    map["$g"]=$(( ${map["$g"]:-0} + 1 ))
    ((total++))
  done
  printf "%s" "Cores: ${total}  |  "
  local first=1
  for k in "${!map[@]}"; do
    ((first)) || printf "  •  "
    if [[ "$k" == "performance" ]]; then
      printf "%b" "${C_GREEN}${k}${C_RESET}: ${map[$k]}"
    elif [[ "$k" == "powersave" || "$k" == "conservative" ]]; then
      printf "%b" "${C_YELLOW}${k}${C_RESET}: ${map[$k]}"
    else
      printf "%b" "${C_CYAN}${k}${C_RESET}: ${map[$k]}"
    fi
    first=0
  done
  echo
}

print_policy(){
  local finfo; finfo="$(cpupower frequency-info 2>/dev/null || true)"
  local driver governors policy
  driver="$(grep -m1 'driver:' <<<"$finfo" | sed 's/^[[:space:]]*driver:[[:space:]]*//')"
  governors="$(grep -m1 'available cpufreq governors' <<<"$finfo" | sed 's/^[[:space:]]*available cpufreq governors:[[:space:]]*//')"
  policy="$(grep -m1 'current policy' <<<"$finfo" | sed 's/^[[:space:]]*current policy:[[:space:]]*//')"

  printf "%b\n" " ${C_BLUE}Driver${C_RESET}    : ${driver:-unknown}"
  printf "%b\n" " ${C_BLUE}Available${C_RESET} : ${governors:-unknown}"
  printf "%b\n" " ${C_BLUE}Policy${C_RESET}    : ${policy:-unknown}"
  core_summary
}

print_per_core(){
  local f
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$f" ]] || continue
    printf "  %-55s %s\n" "$f" "$(cat "$f")"
  done
}

service_status(){
  local enabled="unknown" active="unknown"
  systemctl is-enabled cpuperf.service >/dev/null 2>&1 && enabled="enabled" || enabled="disabled"
  systemctl is-active  cpuperf.service >/dev/null 2>&1 && active="active"  || active="inactive"
  printf "%b\n" " ${C_BLUE}Service${C_RESET}   : cpuperf.service  [enabled: ${enabled}]  [active: ${active}]"
}

main(){
  local verbose=0
  [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && verbose=1

  if [[ "$(id -u)" -ne 0 ]]; then
    bad "本脚本需要 root 权限运行"; exit 1
  fi

  head1 "CPU Performance Governor Ensurer"

  if ! cpufreq_available; then
    bad "未检测到 cpufreq 接口：/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    warn "可能是容器/宿主未暴露，或此虚拟机类型不支持频率调节。"
    exit 1
  fi

  install_cpupower

  local cur; cur="$(current_governor)"
  if [[ "$cur" == "performance" ]]; then
    ok "已处于 performance 模式（无需修改）"
    if ! systemctl is-enabled cpuperf.service >/dev/null 2>&1; then
      info "未检测到永久化服务，正在创建并启用..."
      write_service
    else
      ok "永久化服务已存在"
    fi
  else
    warn "当前 governor：${cur} → 切换为 performance"
    set_governor_now
    write_service
    ok "切换完成并设置为开机自启"
  fi

  head1 "Summary"
  print_policy
  service_status
  if (( verbose )); then
    head1 "Per-Core Governors"
    print_per_core
  else
    say " （逐核详情请加参数 ${C_DIM}--verbose${C_RESET}）"
  fi
  say "${C_DIM}Done.${C_RESET}"
}

main "$@"
