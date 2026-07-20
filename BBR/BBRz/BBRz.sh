#!/bin/bash
# ---------------------------------------------------------------------------
# 开机环境加固（在 systemd 早期启动时运行，环境与交互式 shell 差异很大）：
#   1) systemd 服务默认不设置 $HOME，而下文大量使用 $HOME，必须保底。
#   2) 开机时网络/DNS 往往尚未就绪（尤其当 networking.service 因 IPv6 DAD
#      超时等原因被标记为 failed 时，network-online.target 也不可靠），
#      直接 wget 会因 "Temporary failure in name resolution" 失败。
#      这里主动轮询等待 DNS 真正可用，而不是依赖 systemd 的 target。
# ---------------------------------------------------------------------------
export HOME="${HOME:-/root}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 等待网络与 DNS 就绪（最多 180 秒）
wait_for_network() {
    local i=0
    while [ $i -lt 60 ]; do
        if getent hosts raw.githubusercontent.com >/dev/null 2>&1; then
            echo "网络与 DNS 已就绪（等待 $((i*3)) 秒）。"
            return 0
        fi
        i=$((i+1))
        sleep 3
    done
    echo "Error: 等待 180 秒后 DNS 仍不可用，无法下载源码。" >&2
    return 1
}

# 带重试的下载（最多 5 次），并校验产物非空
download_retry() {
    local url="$1" out="$2" n=0
    while [ $n -lt 5 ]; do
        n=$((n+1))
        if wget -q -O "$out" "$url" && [ -s "$out" ]; then
            echo "源码下载成功（第 ${n} 次尝试）：$out"
            return 0
        fi
        echo "下载失败（第 ${n} 次），10 秒后重试：$url" >&2
        rm -f "$out"
        sleep 10
    done
    echo "Error: 重试 5 次后仍无法下载 $url" >&2
    return 1
}

echo "----BBRz Install----"
sleep 10s

# 先等网络真正可用，再做任何需要联网的事
if ! wait_for_network; then
    echo "Error: 网络不可用，本次编译中止。服务保持 enabled，下次重启会自动重试。" >&2
    exit 1
fi

## Installing BBR
cd "$HOME" || exit 1

## This part of the script is modified from https://github.com/KozakaiAya/TCP_BBR
#Install dkms if not installed
if [ ! -x /usr/sbin/dkms ]; then
	apt-get -y install dkms
    if [ ! -x /usr/sbin/dkms ]; then
		echo "Error: dkms is not installed" >&2
		exit 1
	fi
fi

if dkms status | grep -q "bbrz/"; then
	for module_ver in $(dkms status | grep "bbrz/" | awk -F, '{print $1}' | awk -F/ '{print $2}' | sort -u); do
		echo "Removing existing bbrz module version: $module_ver"
		dkms remove -m bbrz -v "$module_ver" --all
	done
fi

# Ensure header meta package is installed so headers follow kernel upgrades (always try)
arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
uname_r=$(uname -r)
if echo "$uname_r" | grep -q '\-cloud-'; then
    flavor="cloud"
else
    flavor="generic"
fi
case "$arch" in
    amd64)
        if [ "$flavor" = "cloud" ]; then
            header_meta_pkg="linux-headers-cloud-amd64"
        else
            header_meta_pkg="linux-headers-amd64"
        fi
        ;;
    arm64|aarch64)
        if [ "$flavor" = "cloud" ]; then
            header_meta_pkg="linux-headers-cloud-arm64"
        else
            header_meta_pkg="linux-headers-arm64"
        fi
        ;;
    *)
        header_meta_pkg=""
        ;;
esac
if [ -n "$header_meta_pkg" ]; then
    echo "Installing kernel headers meta package: $header_meta_pkg"
    apt-get -y install "$header_meta_pkg"
fi

#Ensure there is header file
if [ ! -f "/usr/src/linux-headers-$(uname -r)/.config" ]; then
    if [[ -z "$(apt-cache search "linux-headers-$(uname -r)")" ]]; then
        echo "Error: linux-headers-$(uname -r) not found" >&2
        exit 1
    fi
    echo "Installing specific kernel headers: linux-headers-$(uname -r)"
    apt-get -y install "linux-headers-$(uname -r)"
    if [ ! -f "/usr/src/linux-headers-$(uname -r)/.config" ]; then
        echo "Error: linux-headers-$(uname -r) is not installed" >&2
        exit 1
    fi
fi

#bbrz
if [ ! -r /etc/os-release ]; then
    echo "Error: Unsupported OS, /etc/os-release not found" >&2
    exit 1
fi

. /etc/os-release
case "$ID:${VERSION_ID%%.*}" in
    debian:12)
        bbrz_source_url="https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/BBR/BBRz/tcp_bbrz.c"
        ;;
    debian:13)
        bbrz_source_url="https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/BBR/BBRz/tcp_bbrz_debian13.c"
        ;;
    *)
        echo "Error: Unsupported OS, only Debian 12 and Debian 13 are supported" >&2
        exit 1
        ;;
esac
# 带重试的下载；失败即中止，绝不拿空文件去编译（否则 dkms 会报难以理解的 make 错误）
if ! download_retry "$bbrz_source_url" "$HOME/tcp_bbrz.c"; then
    echo "Error: 源码下载失败，本次编译中止。服务保持 enabled，下次重启会自动重试。" >&2
    exit 1
fi
# DKMS 模块版本（与内核无关）。建议固定或使用日期字符串
module_ver=1.0.0
algo=bbrz

# Compile and install
bbr_file=tcp_$algo
bbr_src=$bbr_file.c
bbr_obj=$bbr_file.o

mkdir -p $HOME/.bbr/src
cd "$HOME/.bbr/src" || exit 1

mv $HOME/$bbr_src $HOME/.bbr/src/$bbr_src

# Create Makefile（仅声明需要构建的目标，具体内核构建目录交由 dkms.conf 传入）
cat > ./Makefile << EOF
obj-m:=$bbr_obj
EOF

# Create dkms.conf（使用 dkms 注入的 kernel_source_dir/ dkms_tree 等变量，确保针对目标内核构建）
cd ..
cat > ./dkms.conf << EOF
PACKAGE_NAME=$algo
PACKAGE_VERSION=$module_ver
MAKE="make -C \${kernel_source_dir} M=\${dkms_tree}/$algo/$module_ver/build/src modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/$algo/$module_ver/build/src clean"
BUILT_MODULE_NAME=$bbr_file
BUILT_MODULE_LOCATION=src/
DEST_MODULE_LOCATION=/updates/net/ipv4
AUTOINSTALL=yes
EOF

# Start dkms install
cp -R . /usr/src/$algo-$module_ver

dkms add -m $algo -v $module_ver
if [ ! $? -eq 0 ]; then
    sed -i '/tcp_bbrz/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

dkms build -m $algo -v $module_ver
if [ ! $? -eq 0 ]; then
    echo "Error: dkms 编译失败。make.log 内容如下：" >&2
    cat "/var/lib/dkms/$algo/$module_ver/build/make.log" 2>/dev/null | tail -40 >&2
    cp "/var/lib/dkms/$algo/$module_ver/build/make.log" "/root/bbr-build-fail-$algo.log" 2>/dev/null
    echo "（完整日志已另存到 /root/bbr-build-fail-$algo.log）" >&2
    sed -i '/tcp_bbrz/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

dkms install -m $algo -v $module_ver
if [ ! $? -eq 0 ]; then
    sed -i '/tcp_bbrz/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

# Test loading module
modprobe $bbr_file
if [ ! $? -eq 0 ]; then
    exit 1
fi

# Auto-load kernel module at system startup
sed -i '/tcp_bbrz/d' /etc/modules
echo $bbr_file | tee -a /etc/modules

# 持久化 sysctl：必须写 /etc/sysctl.d/（Debian 13 起 systemd 移除了兼容符号链接，
# 开机不再读取 /etc/sysctl.conf，写在那里会导致重启后拥塞控制回落 cubic）。
# 同时清掉 /etc/sysctl.conf 里的旧条目，避免两处配置漂移混淆。
# 【同步提醒】此持久化写法共5处副本：lib/bbr.sh、bbr_switch.sh、BBR/*/*.sh(3个)，改文件名/内容格式时务必5处一起改。
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
cat > /etc/sysctl.d/99-zz-seedbox-bbr.conf << EOF
# 由 my-seedbox BBR 安装脚本生成（zz 前缀确保排序在其它 99-* 之后、优先生效）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $algo
EOF
sysctl -p /etc/sysctl.d/99-zz-seedbox-bbr.conf > /dev/null

cd "$HOME" || true
rm -r "$HOME/.bbr"

## Clear
systemctl disable bbrinstall.service > /dev/null 2>&1
rm /etc/systemd/system/bbrinstall.service > /dev/null 2>&1
rm /root/BBRz.sh > /dev/null 2>&1
echo "BBR ($algo) 安装完成，已即时生效。系统将在 1 分钟后自动重启一次完成收尾。"
shutdown -r +1
