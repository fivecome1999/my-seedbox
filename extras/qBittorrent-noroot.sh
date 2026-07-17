#!/bin/bash

## ============================================================
## qBittorrent 5.x Installer (no-root, seedbox edition)
## ============================================================
##
## Usage:
##   bash <(wget -qO- http://net1999.net/misc/qBittorrent.sh) <Username> <Password> <Cache(MiB)> <WebUI Port> <Incoming Port>
##
## Example:
##   bash <(wget -qO- http://net1999.net/misc/qBittorrent.sh) admin mypassword 512 8080 6881
##
## Parameters:
##   Username       - qBittorrent WebUI login username
##   Password       - qBittorrent WebUI login password
##   Cache (MiB)    - Disk cache size in MiB (e.g. 512, 1024, 8192)
##   WebUI Port     - Port for the web interface (1024-65535)
##   Incoming Port  - Port for incoming torrent connections (1024-65535)
##
## Startup methods (chosen interactively during install):
##   Local User Service  - Runs via systemd user service (auto-starts on login)
##   Screen              - Runs in a detached screen session
##   Daemon              - Runs as a background daemon
##
## Restart / stop after install:
##
##   [Screen]
##     Stop:    pkill -f qbittorrent-nox
##     Start:   screen -dmS qBittorrent-nox ~/bin/qbittorrent-nox
##     Restart: pkill -f qbittorrent-nox && sleep 2 && screen -dmS qBittorrent-nox ~/bin/qbittorrent-nox
##
##   [Daemon]
##     Stop:    pkill -f qbittorrent-nox
##     Start:   ~/bin/qbittorrent-nox -d
##     Restart: pkill -f qbittorrent-nox && sleep 2 && ~/bin/qbittorrent-nox -d
##
##   [Local User Service]
##     Stop:    systemctl --user stop qbittorrent-nox
##     Start:   systemctl --user start qbittorrent-nox
##     Restart: systemctl --user restart qbittorrent-nox
##
##   Check if running:
##     pgrep -fa qbittorrent-nox
##
## ============================================================

## Text colors and styles
info() {
	tput sgr0; tput setaf 2; tput bold
	echo "$1"
	tput sgr0
}
boring_text() {
	tput sgr0; tput setaf 7; tput dim
	echo "$1"
	tput sgr0
}
need_input() {
	tput sgr0; tput setaf 6 ; tput bold
	echo "$1" 1>&2
	tput sgr0
}
warn() {
	tput sgr0; tput setaf 3
	echo "$1" 1>&2
	tput sgr0
}
fail() {
	tput sgr0; tput setaf 1; tput bold
	echo "$1" 1>&2
	tput sgr0
}
fail_exit() {
	tput sgr0; tput setaf 1; tput bold
	echo "$1" 1>&2
	tput sgr0
	exit 1
}

## qBittorrent-nox download URL (from fivecome1999/my-seedbox, qBittorrent 5.0.4)
QB_DOWNLOAD_URL="https://raw.githubusercontent.com/fivecome1999/my-seedbox/main/bin/qbittorrent/5.0.4/amd64/qbittorrent-nox"

## Grabbing information
username=$1
password=$2
qb_cache=$3
qb_port=$4
qb_incoming_port=$5
publicip=$(curl -s https://ipinfo.io/ip)

# Check input arguments
if [ -z "$username" ] || [ -z "$password" ] || [ -z "$qb_cache" ] || [ -z "$qb_port" ] || [ -z "$qb_incoming_port" ]; then
	fail_exit "Usage: bash qBittorrent.sh <Username> <Password> <Cache Size(MiB)> <WebUI Port> <Incoming Port>"
fi
if [[ ! "$qb_cache" =~ ^[0-9]+$ ]]; then
	fail_exit "Invalid cache size"
fi
if [[ ! "$qb_port" =~ ^[0-9]+$ ]] || [[ "$qb_port" -lt 1024 ]] || [[ "$qb_port" -gt 65535 ]]; then
	fail_exit "Invalid WebUI port number"
fi
if [[ ! "$qb_incoming_port" =~ ^[0-9]+$ ]] || [[ "$qb_incoming_port" -lt 1024 ]] || [[ "$qb_incoming_port" -gt 65535 ]]; then
	fail_exit "Invalid incoming port number"
fi

# Check if the ports are occupied
if [ -x "$(command -v lsof)" ]; then
	if lsof -Pi :$qb_port -sTCP:LISTEN -t >/dev/null; then
		fail_exit "Port $qb_port is already in use"
	fi
	if lsof -Pi :$qb_incoming_port -sTCP:LISTEN -t >/dev/null; then
		fail_exit "Port $qb_incoming_port is already in use"
	fi
elif [ -x "$(command -v netstat)" ]; then
	if netstat -tuln | grep -w $qb_port; then
		fail_exit "Port $qb_port is already in use"
	fi
	if netstat -tuln | grep -w $qb_incoming_port; then
		fail_exit "Port $qb_incoming_port is already in use"
	fi
fi

install_qBittorrent_(){
	## Check if qBittorrent is running
	if pgrep -f qbittorrent-nox > /dev/null; then
		warn "qBittorrent is running. Stopping it now..."
		pkill -f qbittorrent-nox
		sleep 2
	fi
	if pgrep -f qbittorrent-nox > /dev/null; then
		fail_exit "Failed to stop qBittorrent. Please stop it manually"
	fi

	## Check if qbittorrent-nox is already installed
	if test -e $HOME/bin/qbittorrent-nox; then
		warn "qBittorrent is already installed. Replacing it now..."
		rm $HOME/bin/qbittorrent-nox
		rm -f $HOME/.config/qBittorrent/qBittorrent.conf
	fi

	## Download qBittorrent-nox executable
	info "Downloading qBittorrent-nox..."
	wget -O $HOME/qbittorrent-nox "$QB_DOWNLOAD_URL" && chmod +x $HOME/qbittorrent-nox
	if [ $? -ne 0 ]; then
		fail_exit "Failed to download qBittorrent-nox"
	fi

	# Install qbittorrent-nox
	mkdir -p $HOME/bin/
	mv $HOME/qbittorrent-nox $HOME/bin/qbittorrent-nox
	mkdir -p $HOME/qbittorrent/Downloads
	mkdir -p $HOME/.config/qBittorrent

	## Configure performance tuning parameters
	systemd-detect-virt > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		# Bare metal
		disk_name=$(lsblk | grep -m1 'disk' | awk '{print $1}')
		if [ -f "/sys/block/$disk_name/queue/rotational" ]; then
			disktype=$(cat /sys/block/$disk_name/queue/rotational)
		else
			disktype=1
		fi
		if [ "${disktype}" == "0" ]; then
			# SSD
			aio=12
			low_buffer=5120
			buffer=20480
			buffer_factor=250
		else
			# HDD
			aio=4
			low_buffer=3072
			buffer=10240
			buffer_factor=150
		fi
	else
		# Virtual machine
		warn "Virtualization detected, using conservative tuning"
		aio=8
		low_buffer=3072
		buffer=15360
		buffer_factor=200
	fi

	## Generate PBKDF2 password
	wget -q -O $HOME/qb_password_gen "http://net1999.net/misc/qb_password_gen" && chmod +x $HOME/qb_password_gen
	if [ $? -ne 0 ]; then
		warn "Failed to download qb_password_gen, trying upstream..."
		# Detect arch for fallback
		if [[ $(uname -m) == "x86_64" ]]; then
			arch="x86_64"
		elif [[ $(uname -m) == "aarch64" ]]; then
			arch="ARM64"
		else
			fail_exit "Unsupported CPU architecture"
		fi
		wget -q -O $HOME/qb_password_gen "https://raw.githubusercontent.com/jerry048/Seedbox-Components/main/Torrent%20Clients/qBittorrent/$arch/qb_password_gen" && chmod +x $HOME/qb_password_gen
		if [ $? -ne 0 ]; then
			#Clean up
			rm -rf $HOME/qbittorrent/Downloads
			rm -rf $HOME/.config/qBittorrent
			rm -f $HOME/bin/qbittorrent-nox
			fail_exit "Failed to download qb_password_gen"
		fi
	fi
	PBKDF2password=$($HOME/qb_password_gen $password)
	rm -f $HOME/qb_password_gen

	## Write config (qBittorrent 4.4+ format)
	cat << EOF >$HOME/.config/qBittorrent/qBittorrent.conf
[Application]
MemoryWorkingSetLimit=$qb_cache

[BitTorrent]
Session\AsyncIOThreadsCount=$aio
Session\DefaultSavePath=$HOME/qbittorrent/Downloads/
Session\DiskCacheSize=$qb_cache
Session\Port=$qb_incoming_port
Session\QueueingSystemEnabled=false
Session\SendBufferLowWatermark=$low_buffer
Session\SendBufferWatermark=$buffer
Session\SendBufferWatermarkFactor=$buffer_factor

[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
WebUI\Password_PBKDF2="@ByteArray($PBKDF2password)"
WebUI\Port=$qb_port
WebUI\Username=$username
EOF
}

# Allow user to choose installation method: Local User Service, Screen, or Daemon
qbittorrent_autostart_(){
	need_input "Choose your startup method:"
	select e in "Local User Service" "Screen" "Daemon"
	do
		case $e in
		"Local User Service"|"Screen"|"Daemon")
			break
			;;
		*) warn "Please choose a valid option" ;;
		esac
	done

	# Local User Service
	if [[ "${e}" == "Local User Service" ]]; then
		if [ ! -x "$(command -v systemctl)" ]; then
			fail "Systemd is not available, falling back to Screen"
			e="Screen"
		else
			mkdir -p $HOME/.config/systemd/user/
			cat << EOF >$HOME/.config/systemd/user/qbittorrent-nox.service
[Unit]
Description=qbittorrent-nox
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
Type=exec
ExecStart=%h/bin/qbittorrent-nox
Restart=on-failure
SyslogIdentifier=qbittorrent-nox

[Install]
WantedBy=default.target
EOF
			systemctl --user daemon-reload
			systemctl --user enable qbittorrent-nox.service
			systemctl --user start qbittorrent-nox
		fi
	fi

	# Screen
	if [[ "${e}" == "Screen" ]]; then
		if [ ! -x "$(command -v screen)" ]; then
			fail "Screen is not available, falling back to Daemon"
			e="Daemon"
		else
			screen -dmS qBittorrent-nox $HOME/bin/qbittorrent-nox
			cat << EOF >$HOME/.qBittorrent-restart.sh
#!/bin/bash
[[ \$(pgrep -f 'qbittorrent-nox') ]] || screen -dmS qBittorrent-nox $HOME/bin/qbittorrent-nox
EOF
			chmod +x $HOME/.qBittorrent-restart.sh
			crontab -l | { cat; echo "*/1 * * * * $HOME/.qBittorrent-restart.sh"; } | crontab -
		fi
	fi

	# Daemon
	if [[ "${e}" == "Daemon" ]]; then
		$HOME/bin/qbittorrent-nox -d
		cat << EOF >$HOME/.qBittorrent-restart.sh
#!/bin/bash
[[ \$(pgrep -f 'qbittorrent-nox') ]] || $HOME/bin/qbittorrent-nox -d
EOF
		chmod +x $HOME/.qBittorrent-restart.sh
		crontab -l | { cat; echo "*/1 * * * * $HOME/.qBittorrent-restart.sh"; } | crontab -
	fi
}

## Main
tput sgr0; clear
cd $HOME
info "Installing qBittorrent"

install_qBittorrent_
qbittorrent_autostart_

tput sgr0; clear
sleep 2
if pgrep -f qbittorrent-nox > /dev/null; then
	info "qBittorrent is running"
	boring_text "WebUI: http://$publicip:$qb_port"
	boring_text "Username: $username"
	boring_text "Password: $password"
else
	fail "Failed to start qBittorrent"
	# Clean up
	rm -rf $HOME/qbittorrent/Downloads
	rm -rf $HOME/.config/qBittorrent
	rm -f $HOME/bin/qbittorrent-nox
fi
